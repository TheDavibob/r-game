// =============================================================================
// main.js -- the game: task list, editor, scoring and showing results.
// =============================================================================

import { REngine } from './engine.js';
import { loadTaskIndex, loadTaskFiles } from './tasks.js';
import { renderMarkdown, escapeHtml } from './markdown.js';
import { celebrate } from './celebrate.js';

const $ = (id) => document.getElementById(id);
const STORE_KEY = 'rcodequest-progress-v1';
const SOLUTION_AFTER_ATTEMPTS = 3; // failed attempts before "Show solution" appears

const engine = new REngine();
window.rgameEngine = engine; // handy for poking at R from the browser's dev tools
window.rgameCelebrate = celebrate; // e.g. rgameCelebrate({ count: 7, banner: 'Hi!' })
let tracks = [];       // [{ id, title, tasks: [...] }], shown as tabs
let currentTrack = null;
let tasks = [];        // metadata for every task in every track (from task.json)
let current = null;    // the selected task, with its prompt/setup/solution text
let currentReady = false;
let selectToken = 0;   // guards against races when switching tasks quickly
let targetCanvas = null;

// ---- progress (saved in the browser's localStorage) ---------------------------

const progress = (() => {
  let p;
  try { p = JSON.parse(localStorage.getItem(STORE_KEY)); } catch { /* corrupt: start again */ }
  p ||= {};
  p.tasks ||= {};
  p.lastTask ||= {}; // track id -> task id last opened in that tab
  return p;
})();

function taskState(id) {
  progress.tasks[id] ??= { solved: false, points: 0, attempts: 0, hints: 0, sawSolution: false, code: null };
  return progress.tasks[id];
}
const saveProgress = () => localStorage.setItem(STORE_KEY, JSON.stringify(progress));

// Full points, minus 25% per hint used (minimum 25%); nothing if the solution was viewed.
function pointsFor(task, st) {
  if (st.sawSolution) return 0;
  return Math.max(Math.round(task.points * 0.25), Math.round(task.points * (1 - 0.25 * st.hints)));
}

function updateScore() {
  const total = Object.values(progress.tasks).reduce((s, t) => s + (t.points || 0), 0);
  const solved = tasks.filter((t) => taskState(t.id).solved).length;
  $('score').textContent = `${total} pts · ${solved}/${tasks.length} solved`;
}

// ---- in-page confirmation (browser confirm() pop-ups can be blocked) -------------

function askConfirm(message, okLabel = 'OK') {
  const dlg = $('confirm-dialog');
  $('confirm-text').textContent = message;
  $('confirm-ok').textContent = okLabel;
  return new Promise((resolve) => {
    const finish = (answer) => {
      $('confirm-ok').onclick = $('confirm-cancel').onclick = dlg.oncancel = null;
      if (dlg.open) dlg.close();
      resolve(answer);
    };
    $('confirm-ok').onclick = () => finish(true);
    $('confirm-cancel').onclick = () => finish(false);
    dlg.oncancel = () => finish(false); // Esc key
    dlg.showModal();
    $('confirm-cancel').focus();
  });
}

// ---- status pill -------------------------------------------------------------

function setStatus(kind, text) {
  const el = $('engine-status');
  el.className = `pill pill-${kind}`;
  el.textContent = text;
}

// ---- tabs (tracks) and task list ---------------------------------------------

function renderTabs() {
  const bar = $('tabs');
  bar.hidden = tracks.length < 2;
  bar.innerHTML = '';
  for (const track of tracks) {
    const solved = track.tasks.filter((t) => taskState(t.id).solved).length;
    const btn = document.createElement('button');
    btn.setAttribute('role', 'tab');
    btn.setAttribute('aria-selected', String(track.id === currentTrack));
    btn.className = track.id === currentTrack ? 'tab active' : 'tab';
    btn.innerHTML = `${escapeHtml(track.title)} <span class="tab-count">${solved}/${track.tasks.length}</span>`;
    btn.addEventListener('click', () => openTrack(track.id));
    bar.appendChild(btn);
  }
}

// Switch tabs: reopen the task last viewed in that tab, else its first unsolved one.
function openTrack(trackId) {
  const track = tracks.find((t) => t.id === trackId);
  if (!track || !track.tasks.length) return;
  const last = track.tasks.find((t) => t.id === progress.lastTask[trackId]);
  const next = last || track.tasks.find((t) => !taskState(t.id).solved) || track.tasks[0];
  selectTask(next.id);
}

function renderTaskList() {
  const list = $('task-list');
  list.innerHTML = '';
  const track = tracks.find((t) => t.id === currentTrack);
  for (const t of track ? track.tasks : tasks) {
    const st = taskState(t.id);
    const li = document.createElement('li');
    if (current?.id === t.id) li.className = 'active';
    li.innerHTML =
      `<button><span class="tick">${st.solved ? '✓' : ''}</span>` +
      `<span>${escapeHtml(t.title)}</span>` +
      `<span class="stars">${'★'.repeat(t.difficulty)}</span></button>`;
    li.querySelector('button').addEventListener('click', () => selectTask(t.id));
    list.appendChild(li);
  }
}

// ---- selecting and preparing a task ----------------------------------------------

async function selectTask(id) {
  const meta = tasks.find((t) => t.id === id);
  if (!meta) return;
  const token = ++selectToken;
  currentReady = false;
  $('run-btn').disabled = true;

  const task = await loadTaskFiles(meta);
  if (token !== selectToken) return;
  current = task;
  currentTrack = task.track;
  progress.lastTask[task.track] = id;
  progress.lastTrack = task.track;
  saveProgress();
  history.replaceState(null, '', `#${id}`);
  renderTabs();
  renderTaskList();

  const st = taskState(id);
  $('empty-view').hidden = true;
  $('task-view').hidden = false;
  $('task-title').textContent = task.title;
  $('task-meta').textContent =
    `${'★'.repeat(task.difficulty)} · ${task.points} pts` + (st.solved ? ` · solved (+${st.points})` : '');
  $('task-prompt').innerHTML = renderMarkdown(task.prompt);
  $('setup-box').hidden = !(task.show_setup && task.setupCode.trim());
  $('setup-code').textContent = task.setupCode.trim();
  $('editor').value = st.code ?? task.starter;
  $('target-box').hidden = true;
  $('target-content').innerHTML = '';
  targetCanvas = null;
  $('result').hidden = true;
  renderHints();
  updateSolutionButton();

  if (engine.ready) prepareTask(task, token);
}

async function prepareTask(task, token = selectToken) {
  try {
    setStatus('busy', 'Preparing challenge…');
    await engine.ensurePackages(task.packages, (msg) => setStatus('busy', msg));
    const info = await engine.loadTask(task);
    if (token !== selectToken) return;
    if (!info.ok) {
      showAuthorError(info.error);
      setStatus('error', 'Challenge failed to load');
      return;
    }
    if (info.has_expected_plot) {
      targetCanvas = await engine.renderPlot('expected', task.id);
      if (token !== selectToken) return;
      if (targetCanvas) {
        $('target-content').replaceChildren(targetCanvas);
        $('target-box').hidden = false;
      }
    } else if (info.target_text) {
      $('target-content').innerHTML = `<pre class="console">${escapeHtml(info.target_text)}</pre>`;
      $('target-box').hidden = false;
    }
    currentReady = true;
    $('run-btn').disabled = false;
    setStatus('ready', engine.offline ? 'R ready (offline)' : 'R ready (online)');
  } catch (e) {
    if (token !== selectToken) return;
    showAuthorError(e.message || String(e));
    setStatus('error', 'Problem preparing challenge');
  }
}

function showAuthorError(msg) {
  showResult({
    status: 'error',
    messages: ['This challenge could not be prepared:', msg],
    output: '', warnings: [], value_preview: '',
  });
}

// ---- running the player's code ---------------------------------------------------

async function runCode() {
  if (!current || !currentReady) return;
  const task = current;
  const token = selectToken;
  const st = taskState(task.id);
  const code = $('editor').value;
  st.code = code;
  saveProgress();

  $('run-btn').disabled = true;
  $('result').hidden = false;
  $('verdict').className = 'verdict running';
  $('verdict').textContent = 'Running…';
  for (const id of ['messages']) $(id).innerHTML = '';
  for (const id of ['warnings', 'plots', 'console-wrap', 'preview-wrap']) $(id).hidden = true;

  // R stops the code itself after task.timeout seconds; this is a backstop.
  const watchdog = setTimeout(() => {
    engine.interrupt();
    $('restart-btn').hidden = false;
  }, (task.timeout + 5) * 1000);

  let res;
  try {
    res = await engine.submit(task.id, code);
  } catch (e) {
    res = { status: 'error', messages: [String(e.message || e)], output: '', warnings: [], images: [] };
  } finally {
    clearTimeout(watchdog);
  }
  if (token !== selectToken) return;

  let userCanvas = null;
  if (res.has_user_plot) userCanvas = await engine.renderPlot('user', task.id);
  else if (res.images?.length) userCanvas = res.images[res.images.length - 1];

  if (res.status === 'correct') {
    const firstSolve = !st.solved;
    if (firstSolve) {
      st.solved = true;
      st.points = pointsFor(task, st);
      res.earned = st.points;
    }
    const track = tracks.find((t) => t.id === task.track);
    const trackDone = firstSolve && track && track.tasks.every((t) => taskState(t.id).solved);
    if (trackDone) celebrate({ count: 7, banner: `All ${track.title} challenges solved!` });
    else celebrate({ count: firstSolve ? 4 : 1 });
  } else if (!st.solved) {
    st.attempts += 1;
  }
  saveProgress();
  updateScore();
  renderTabs();
  renderTaskList();
  updateSolutionButton();

  showResult(res, userCanvas);
  $('run-btn').disabled = false;
}

function showResult(res, userCanvas = null) {
  $('result').hidden = false;
  const verdict = $('verdict');
  verdict.className = `verdict ${res.status}`;
  verdict.textContent = {
    correct: res.earned != null ? `✓ Correct! +${res.earned} pts` : '✓ Correct!',
    incorrect: '✗ Not quite',
    error: '⚠ Error',
  }[res.status] || res.status;

  const msgs = (res.messages || []).filter((m) => !(res.status === 'correct' && /^Correct!?$/.test(m)));
  $('messages').innerHTML = msgs.map((m) => `<li>${escapeHtml(m)}</li>`).join('');

  const warnings = res.warnings || [];
  $('warnings').hidden = !warnings.length;
  $('warnings').textContent = warnings.length ? `Warning${warnings.length > 1 ? 's' : ''}:\n` + warnings.join('\n') : '';

  $('plots').hidden = !userCanvas;
  if (userCanvas) {
    $('user-plot').replaceChildren(userCanvas);
    $('target-plot-fig').hidden = !targetCanvas;
    if (targetCanvas) $('target-plot-copy').replaceChildren(copyCanvas(targetCanvas));
  }

  $('console-wrap').hidden = !res.output;
  $('console').textContent = res.output || '';

  const showPreview = res.status === 'incorrect' && res.value_preview;
  $('preview-wrap').hidden = !showPreview;
  $('preview').textContent = showPreview ? res.value_preview : '';
}

function copyCanvas(src) {
  const c = document.createElement('canvas');
  c.width = src.width;
  c.height = src.height;
  c.getContext('2d').drawImage(src, 0, 0);
  return c;
}

// ---- hints and solution ----------------------------------------------------------

function renderHints() {
  const st = taskState(current.id);
  const shown = current.hints.slice(0, st.hints);
  $('hints').innerHTML = shown.map((h) => `<li>${renderMarkdown(h).replace(/^<p>|<\/p>$/g, '')}</li>`).join('');
  const left = current.hints.length - shown.length;
  $('hint-btn').disabled = left === 0;
  $('hint-btn').textContent = current.hints.length === 0 ? 'No hints' : left ? `Hint (${left} left)` : 'No more hints';
}

function showHint() {
  const st = taskState(current.id);
  if (st.hints >= current.hints.length) return;
  st.hints += 1;
  saveProgress();
  renderHints();
}

function updateSolutionButton() {
  const st = taskState(current.id);
  $('solution-btn').hidden = !(st.solved || st.sawSolution || st.attempts >= SOLUTION_AFTER_ATTEMPTS);
}

async function showSolution() {
  const st = taskState(current.id);
  if (!st.solved && !st.sawSolution) {
    if (!await askConfirm('If you view the solution you will get 0 points for this challenge. Show it?', 'Show solution')) return;
    st.sawSolution = true;
    saveProgress();
  }
  $('result').hidden = false;
  $('verdict').className = 'verdict running';
  $('verdict').textContent = 'Reference solution';
  $('messages').innerHTML = `<div class="solution">${escapeHtml(current.solutionCode.trim())}</div>`;
  for (const id of ['warnings', 'plots', 'console-wrap', 'preview-wrap']) $(id).hidden = true;
}

// ---- editor niceties -------------------------------------------------------------

function setupEditor() {
  const ed = $('editor');
  ed.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      runCode();
    } else if (e.key === 'Tab' && !e.shiftKey) {
      e.preventDefault();
      const { selectionStart: s, selectionEnd: end } = ed;
      ed.setRangeText('  ', s, end, 'end');
    }
  });
  let t;
  ed.addEventListener('input', () => {
    clearTimeout(t);
    t = setTimeout(() => {
      if (!current) return;
      taskState(current.id).code = ed.value;
      saveProgress();
    }, 500);
  });
}

// ---- start up ----------------------------------------------------------------------

async function startEngine() {
  try {
    await engine.init((msg) => setStatus('busy', msg));
    setStatus('ready', engine.offline ? 'R ready (offline)' : 'R ready (online)');
    if (current) prepareTask(current);
  } catch (e) {
    console.error(e);
    setStatus('error', 'R failed to start');
    $('empty-view').hidden = false;
    $('empty-view').innerHTML =
      `<p><strong>R (webR) could not start:</strong> ${escapeHtml(String(e.message || e))}</p>` +
      '<p>Run <code>python setup_offline.py</code> once to download webR for offline use, ' +
      'or connect to the internet to use the online copy.</p>';
  }
}

async function boot() {
  if (location.protocol === 'file:') {
    $('empty-view').innerHTML =
      '<p>This game must be opened through its local web server. ' +
      'Run <code>python serve.py</code> (or double-click <code>start-game.bat</code>).</p>';
    setStatus('error', 'Not served');
    return;
  }

  $('run-btn').addEventListener('click', runCode);
  $('hint-btn').addEventListener('click', showHint);
  $('solution-btn').addEventListener('click', showSolution);
  $('reset-btn').addEventListener('click', async () => {
    if (!current) return;
    if ($('editor').value !== current.starter &&
        !await askConfirm('Replace your code with the starting code?', 'Reset code')) return;
    $('editor').value = current.starter;
    taskState(current.id).code = null;
    saveProgress();
  });
  $('restart-btn').addEventListener('click', async () => {
    $('restart-btn').hidden = true;
    $('run-btn').disabled = true;
    currentReady = false;
    setStatus('busy', 'Restarting R…');
    await engine.restart((msg) => setStatus('busy', msg));
    if (current) prepareTask(current);
  });
  $('reset-progress').addEventListener('click', async () => {
    if (!await askConfirm('Erase all progress, scores and saved code?', 'Erase progress')) return;
    localStorage.removeItem(STORE_KEY);
    location.reload();
  });
  setupEditor();

  const enginePromise = startEngine(); // start R while the first task renders

  try {
    tracks = await loadTaskIndex();
    tasks = tracks.flatMap((t) => t.tasks);
  } catch (e) {
    $('empty-view').innerHTML = `<p>Could not load challenges: ${escapeHtml(e.message)}</p>`;
    return;
  }
  updateScore();

  // Start on the task in the URL (#task-id), else wherever the player was last.
  const fromHash = decodeURIComponent(location.hash.slice(1));
  if (tasks.some((t) => t.id === fromHash)) {
    await selectTask(fromHash);
  } else if (tracks.length) {
    const lastTrack = tracks.find((t) => t.id === progress.lastTrack) || tracks[0];
    openTrack(lastTrack.id);
  }
  await enginePromise;
}

boot();
