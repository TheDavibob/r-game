// Loads challenge definitions from the tasks/ folder.
//
// tasks/index.json lists task folders in play order. Each folder contains:
//   task.json    metadata (see TASK_DEFAULTS below and README.md)
//   prompt.md    what the player is asked to do
//   setup.R      (optional) code run before the player's code; its objects are
//                visible to the player
//   solution.R   the reference answer used to compute "truth"
//   check.R      (optional) defines check(result, expected, env, output) for
//                custom grading

export const TASK_DEFAULTS = {
  title: 'Untitled challenge',
  type: 'value',          // "value" | "plot" | "output"
  difficulty: 1,          // 1-3, shown as stars
  points: 10,
  packages: [],           // e.g. ["ggplot2"]; installed into webR and attached
  hints: [],
  starter: '',            // initial contents of the code box
  seed: 42,               // set.seed() before setup/solution/player code
  tolerance: 1.5e-8,      // numeric tolerance for "value" tasks
  ignore_attributes: false,
  variable: '',           // grade this variable instead of the last value
  labels: ['title', 'x', 'y'], // plot labels that must match for "plot" tasks
  timeout: 10,            // seconds before the player's code is stopped
  show_setup: true,       // show setup.R to the player
};

const base = new URL('../tasks/', import.meta.url);

async function fetchText(path, optional = false) {
  const res = await fetch(new URL(path, base), { cache: 'no-cache' });
  if (!res.ok) {
    if (optional) return '';
    throw new Error(`Could not load tasks/${path} (${res.status})`);
  }
  return res.text();
}

export async function loadTaskIndex() {
  const index = JSON.parse(await fetchText('index.json'));
  return Promise.all(
    index.tasks.map(async (id) => {
      const meta = JSON.parse(await fetchText(`${id}/task.json`));
      return { ...TASK_DEFAULTS, ...meta, id };
    }),
  );
}

export async function loadTaskFiles(meta) {
  const [prompt, setupCode, solutionCode, checkCode] = await Promise.all([
    fetchText(`${meta.id}/prompt.md`),
    fetchText(`${meta.id}/setup.R`, true),
    fetchText(`${meta.id}/solution.R`),
    fetchText(`${meta.id}/check.R`, true),
  ]);
  return { ...meta, prompt, setupCode, solutionCode, checkCode };
}
