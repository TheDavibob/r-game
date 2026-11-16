// =============================================================================
// engine.js -- runs R inside the browser using webR (R compiled to WebAssembly).
//
// Offline first: if `vendor/webr/` exists (created by setup_offline.py) webR and
// its packages are loaded from this folder. Otherwise it falls back to the
// public webR CDN, which needs an internet connection.
//
// All grading logic lives in r/grader.R; this file only moves strings between
// the page and R, and turns R graphics into <canvas> elements.
// =============================================================================

export const WEBR_VERSION = '0.6.1';
const CDN_BASE = `https://webr.r-wasm.org/v${WEBR_VERSION}/`;
const CDN_REPO = 'https://repo.r-wasm.org/';
const LOCAL_BASE = new URL('../vendor/webr/', import.meta.url).href;
const LOCAL_REPO = new URL('../vendor/repo/', import.meta.url).href;
const GRADER_URL = new URL('../r/grader.R', import.meta.url).href;

// Arguments for webR's canvas() graphics device. Kept fairly small with a
// large pointsize so text stays readable when plots are shown side by side.
const PLOT_SIZE = { width: 560, height: 400, pointsize: 14, bg: 'white' };

export class REngine {
  constructor() {
    this.webR = null;
    this.offline = false;
    this.ready = false;
    this._lock = Promise.resolve();
    this._installed = new Set();
  }

  // Run R calls one at a time so a slow submission can't interleave with a
  // task load.
  _serial(fn) {
    const run = this._lock.then(fn, fn);
    this._lock = run.catch(() => {});
    return run;
  }

  async init(onStatus = () => {}) {
    onStatus('Loading webR…');
    const hasLocal = await fetch(LOCAL_BASE + 'webr.mjs', { method: 'HEAD' })
      .then((r) => r.ok)
      .catch(() => false);

    let mod;
    if (hasLocal) {
      mod = await import(LOCAL_BASE + 'webr.mjs');
      this.offline = true;
    } else {
      mod = await import(CDN_BASE + 'webr.mjs');
      this.offline = false;
    }

    this.webR = new mod.WebR({
      baseUrl: this.offline ? LOCAL_BASE : CDN_BASE,
      repoUrl: this.offline ? LOCAL_REPO : CDN_REPO,
      interactive: false,
    });

    onStatus('Starting R…');
    await this.webR.init();

    const grader = await fetch(GRADER_URL, { cache: 'no-cache' }).then((r) => r.text());
    await this.webR.evalRVoid(grader);
    this._installed.clear();
    this.ready = true;
  }

  async restart(onStatus) {
    this.ready = false;
    try { this.webR?.close(); } catch { /* already gone */ }
    this._lock = Promise.resolve();
    await this.init(onStatus);
  }

  // Ask R to stop the current computation. Works when the page is
  // cross-origin isolated (serve.py sets the headers); otherwise use restart().
  interrupt() {
    try { this.webR?.interrupt(); } catch { /* not supported on this channel */ }
  }

  ensurePackages(pkgs, onStatus = () => {}) {
    return this._serial(async () => {
      const wanted = pkgs.filter((p) => !this._installed.has(p));
      for (const p of wanted) {
        if (!/^[A-Za-z][A-Za-z0-9.]*$/.test(p)) throw new Error(`Bad package name: ${p}`);
      }
      const missing = [];
      for (const p of wanted) {
        const has = await this.webR.evalRBoolean(`requireNamespace("${p}", quietly = TRUE)`);
        if (has) this._installed.add(p);
        else missing.push(p);
      }
      if (!missing.length) return;

      onStatus(`Installing ${missing.join(', ')}…`);
      await this.webR.installPackages(missing, { quiet: true });
      for (const p of missing) {
        const ok = await this.webR.evalRBoolean(`requireNamespace("${p}", quietly = TRUE)`);
        if (!ok) {
          throw new Error(
            `R package '${p}' could not be installed. ` +
            (this.offline
              ? 'Run "python setup_offline.py" so it is downloaded into vendor/repo.'
              : 'Check your internet connection.'));
        }
        this._installed.add(p);
      }
    });
  }

  // Runs the task's setup + reference solution inside R, storing the
  // "truth" that submissions are compared against.
  loadTask(task) {
    return this._serial(async () => {
      const json = await this.webR.evalRString(
        'rgame_load_task(id, type, setup, solution, check, packages, seed, ' +
        'tolerance, ignore_attributes, variable, labels, timeout, ' +
        'row_order, col_order, show_target)',
        {
          env: {
            id: task.id,
            type: task.type,
            setup: task.setupCode,
            solution: task.solutionCode,
            check: task.checkCode,
            packages: task.packages.join(','),
            seed: task.seed,
            tolerance: task.tolerance,
            ignore_attributes: task.ignore_attributes,
            variable: task.variable,
            labels: task.labels.join(','),
            timeout: task.timeout,
            row_order: task.row_order,
            col_order: task.col_order,
            show_target: task.show_target,
          },
        },
      );
      return JSON.parse(json);
    });
  }

  // Runs the player's code and grades it. Any base-R graphics the player draws
  // along the way are captured and returned as canvases in `images`.
  submit(taskId, code) {
    return this._serial(async () => {
      const shelter = await new this.webR.Shelter();
      try {
        const cap = await shelter.captureR('rgame_submit(id, code)', {
          env: { id: taskId, code },
          captureGraphics: PLOT_SIZE,
          captureStreams: true,
          captureConditions: false,
        });
        const result = JSON.parse(await cap.result.toString());
        result.images = (cap.images || []).map(bitmapToCanvas);
        return result;
      } finally {
        shelter.purge();
      }
    });
  }

  // which = "user" (the player's last ggplot) or "expected" (the target).
  renderPlot(which, taskId) {
    return this._serial(async () => {
      const shelter = await new this.webR.Shelter();
      try {
        const cap = await shelter.captureR('rgame_render(which, id)', {
          env: { which, id: taskId },
          captureGraphics: PLOT_SIZE,
        });
        const img = cap.images?.[cap.images.length - 1];
        return img ? bitmapToCanvas(img) : null;
      } finally {
        shelter.purge();
      }
    });
  }
}

function bitmapToCanvas(bitmap) {
  const canvas = document.createElement('canvas');
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  canvas.getContext('2d').drawImage(bitmap, 0, 0);
  return canvas;
}
