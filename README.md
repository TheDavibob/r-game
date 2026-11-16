# R Code Quest

A browser game of small R coding challenges. The player reads a prompt, writes R
code, and the game runs it with **webR** (real R compiled to WebAssembly, running
inside the browser) and grades it against a reference solution.

Nothing to install for players beyond Python (used only for a tiny local web
server), and it works fully offline once set up.

## Quick start

```bash
python setup_offline.py
```

```bash
python serve.py
```

`setup_offline.py` downloads webR (~47 MB) into `vendor/webr/` and the R packages
your tasks need (currently ggplot2, dplyr, tidyr, palmerpenguins and their
dependencies, ~37 MB) into `vendor/repo/`. Run it
again whenever a task starts using a new package. `serve.py` starts
`http://localhost:8080` and opens your browser. On Windows you can double-click
`start-game.bat` instead.

If `vendor/` is missing, the game still works online by loading webR from its
CDN.

## How it fits together

```
index.html, css/            page and styles
js/main.js                  game UI: task list, editor, scoring, results
js/engine.js                starts webR, installs packages, calls the grader
js/tasks.js                 reads the tasks/ folder (and the task.json defaults)
js/markdown.js              tiny Markdown renderer for prompts
r/grader.R                  ALL grading logic, in plain R, loaded into webR
tasks/                      the challenges (one folder each)
setup_offline.py            downloads webR + packages into vendor/
serve.py                    local web server with the headers webR needs
```

What happens when a task is opened and answered:

1. `engine.js` installs the task's `packages` into webR (from `vendor/repo/`).
2. `rgame_load_task()` sets `set.seed(seed)`, runs `setup.R`, then runs
   `solution.R`. The result (its last value, a named variable, or its printed
   output) is stored as the "truth". For plot tasks the target plot is drawn and
   shown to the player.
3. On **Run & check**, `rgame_submit()` builds a fresh environment the same way
   (same seed, same setup), runs the player's code one expression at a time
   like the console would (printing visible values, collecting warnings,
   stopping at the first error, with a time limit), then compares the result
   with the truth and returns a verdict and feedback as JSON.
4. The page shows the verdict, feedback messages, console output and, for
   plots, the player's plot next to the target.

Because the grader is plain R, you can test it in your normal R session:

```r
source("r/grader.R")
cat(rgame_load_task("t", setup = "x <- 1:10", solution = "mean(x)"))
cat(rgame_submit("t", "sum(x) / length(x)"))
```

## Writing tasks

Add a folder under `tasks/` and list it in `tasks/index.json`. The index groups
tasks into **tracks**, each shown as a tab in the sidebar (currently "Data" and
"Plots"); the order within a track is the play order. Add a new object to
`tracks` to get a new tab.

```json
{
  "tracks": [
    { "id": "data",  "title": "Data",  "tasks": ["01-mean", "data-filter-dream", "..."] },
    { "id": "plots", "title": "Plots", "tasks": ["02-scatter", "..."] }
  ]
}
```

```
tasks/03-my-task/
  task.json     settings (required)
  prompt.md     what the player sees (required, Markdown)
  solution.R    reference answer (required)
  setup.R       code run before the player's code; its objects are visible
                to the player and shown under "Already defined for you" (optional)
  check.R       custom grading (optional, see below)
```

### task.json

Only `title` is really needed; everything else has a default.

| field | default | meaning |
|---|---|---|
| `title` | | name in the task list |
| `type` | `"value"` | `"value"`, `"plot"` or `"output"` (see below) |
| `difficulty` | `1` | 1-3, shown as stars |
| `points` | `10` | points for solving it |
| `packages` | `[]` | R packages to install and attach, e.g. `["ggplot2"]` |
| `hints` | `[]` | revealed one at a time; each costs 25% of the points |
| `starter` | `""` | initial contents of the code box |
| `seed` | `42` | `set.seed()` value used before setup/solution/player code |
| `tolerance` | `1.5e-8` | numeric tolerance (`all.equal`) for value tasks |
| `ignore_attributes` | `false` | ignore names/attributes when comparing values |
| `variable` | `""` | grade this variable (e.g. `"avg"`) instead of the last value |
| `labels` | `["title","x","y"]` | plot labels that must match; `[]` to ignore labels |
| `timeout` | `10` | seconds before the player's code is stopped |
| `show_setup` | `true` | show `setup.R` to the player |
| `show_target` | `false` | show the expected value/table as the "Target" (first 10 rows of a table) |
| `row_order` | `false` | tables: rows must be in the same order as the solution's |
| `col_order` | `false` | tables: columns must be in the same order as the solution's |

### Task types

- **value**: the last value of the player's code (or `variable`) is compared to
  the solution's with `all.equal()`. Works for numbers, vectors, lists, etc.
  If the solution's value is a **data frame or tibble**, a table comparison is
  used instead: tibbles, grouped tibbles and data frames are treated alike,
  factors match character columns, integers match doubles, and row/column
  order are ignored unless `row_order`/`col_order` is set. Column names must
  match exactly (so state them in the prompt). Feedback names the missing or
  unexpected columns, a wrong row count, which columns hold different values
  (with a hint when there are extra `NA`s, e.g. a forgotten `na.rm = TRUE`),
  values combined into rows differently, or rows in the wrong order.
- **plot**: the player's last value must be a ggplot. Both plots are built with
  `ggplot_build()` and compared on: layer geoms (in order), the drawn data for
  each aesthetic (x, y, colour, fill, size, shape, box-plot quartiles, ...; row
  order ignored; extra aesthetics such as an unwanted confidence band count as
  a difference), number of facet panels, and the labels listed in `labels`.
  So `aes(wt, mpg)` vs `aes(x = wt, y = mpg)`, `colour =` in the geom instead
  of `ggplot()`, `facet_grid()` vs `facet_wrap()`, `geom_col()` vs
  `geom_bar(stat = "identity")`, hex codes vs colour names, and pre-summarising
  vs `stat_summary()` all pass, but a different variable, geom, binwidth or
  title does not. Rows with a missing x or y are ignored (ggplot doesn't draw
  them), and a scale's `name =` counts as that aesthetic's label.
  Not compared: themes, coordinate systems (`coord_flip()`), axis limits and
  facet layout, so avoid puzzles that hinge on those (or add a `check.R`).
  Avoid random positions such as `geom_jitter()`, which differ on every build.
- **output**: the printed console output is compared with the solution's
  (trailing whitespace ignored). The target output is shown to the player.

### Custom checks (check.R)

When the built-in comparison isn't right for a task, define `check()` in
`check.R`. It can take any of these arguments: `result` (player's last value
or `variable`), `expected` (the solution's), `env` (the environment the player's
code ran in), `output` (their printed output). Return `TRUE` for a pass, or a
character string explaining what's wrong.

```r
# check.R: accept any number within 0.1 of the reference answer
check <- function(result, expected, env) {
  if (!is.numeric(result)) return("Your answer should be a number.")
  if (abs(result - expected) > 0.1) return("Close, but not quite.")
  TRUE
}
```

Helpers you can use inside `check()`: `rgame_compare_value()`,
`rgame_compare_ggplot()`, `rgame_pass()`, `rgame_fail()`.

## Notes and limits

- Progress, scores and the code typed for each task are kept in the browser's
  localStorage. "Reset progress" in the sidebar clears it.
- Base-graphics plots (`plot()`, `hist()`) are drawn and shown, but only ggplot
  plots can be graded as plots. For a base-graphics task, use a custom check
  that inspects the player's code or data instead.
- The player's code runs inside the browser on their own machine, so there is
  no server-side security concern, but a determined player can read
  `solution.R` from the tasks folder. Fine for learning; not suitable for exams.
- The code box is a plain textarea (Tab indents, Ctrl+Enter runs). A proper
  editor such as CodeMirror can be dropped in later if wanted; it would also
  need to be copied into `vendor/` to keep offline play.
- webR's packages come from repo.r-wasm.org. Most CRAN packages are available,
  but a few with system dependencies are not; `setup_offline.py` reports any
  it can't find.
