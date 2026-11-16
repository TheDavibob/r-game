# =============================================================================
# grader.R -- the R half of the game.
#
# js/engine.js loads this file into webR (R compiled to WebAssembly, running
# inside the browser) when the game starts. It uses base R only (ggplot2 is
# used only for tasks that need it) and returns results as JSON strings.
#
# Because it is plain R you can also source() it in your own R session to
# test a task's grading, e.g.
#   source("r/grader.R")
#   cat(rgame_load_task("t", setup = "x <- 1:10", solution = "mean(x)"))
#   cat(rgame_submit("t", "sum(x) / length(x)"))
#
# Public API used by the JavaScript side:
#   rgame_load_task(id, type, setup, solution, check, packages, seed,
#                   tolerance, ignore_attributes, variable, labels, timeout)
#   rgame_submit(id, code)
#   rgame_render(which, id)          # draws the "user" or "expected" plot
#
# Helpers available to task authors inside check.R:
#   rgame_pass(msg), rgame_fail(msg),
#   rgame_compare_value(user, expected, ...), rgame_compare_table(user, expected, ...),
#   rgame_compare_ggplot(user, expected, ...)
# =============================================================================

.rgame <- new.env()
.rgame$tasks <- list()
.rgame$plots <- list()

# The console in the page is plain text, so stop cli/pillar adding colour codes.
# Also show tibble numbers with more digits than the default 3 significant figures.
options(cli.num_colors = 1L, crayon.enabled = FALSE, pillar.sigfig = 5)

# ---- small utilities ---------------------------------------------------------

rgame_split <- function(s) {
  if (is.null(s) || length(s) == 0) return(character())
  s <- trimws(unlist(strsplit(paste(s, collapse = ","), ",", fixed = TRUE)))
  s[nzchar(s)]
}

rgame_is_ggplot <- function(x) {
  inherits(x, "ggplot") || inherits(x, "ggplot2::ggplot")
}

rgame_describe <- function(x) {
  if (is.null(x)) return("NULL (nothing)")
  if (rgame_is_ggplot(x)) return("a ggplot object")
  if (is.data.frame(x)) {
    return(sprintf("a data frame with %d row(s) and %d column(s)", nrow(x), ncol(x)))
  }
  if (is.matrix(x)) {
    return(sprintf("a %s matrix with %d row(s) and %d column(s)", typeof(x), nrow(x), ncol(x)))
  }
  if (is.factor(x)) return(sprintf("a factor of length %d", length(x)))
  if (is.atomic(x)) return(sprintf("a %s vector of length %d", class(x)[1], length(x)))
  if (is.list(x)) return(sprintf("a list of length %d", length(x)))
  sprintf("an object of class '%s'", paste(class(x), collapse = "/"))
}

# Print a table the way a tibble would: first `n` rows plus a note of the rest.
rgame_table_text <- function(x, n = 10) {
  txt <- tryCatch({
    if (inherits(x, "tbl_df")) {
      utils::capture.output(print(x, n = n))
    } else {
      out <- utils::capture.output(print(utils::head(as.data.frame(x), n)))
      if (nrow(x) > n) out <- c(out, sprintf("# ... with %d more rows", nrow(x) - n))
      c(sprintf("# A data frame: %d x %d", nrow(x), ncol(x)), out)
    }
  }, error = function(e) utils::capture.output(utils::str(x)))
  paste(txt, collapse = "\n")
}

rgame_preview <- function(x, max_chars = 2000) {
  if (is.null(x) || rgame_is_ggplot(x)) return("")
  if (is.data.frame(x)) return(rgame_table_text(x))
  txt <- tryCatch(
    paste(utils::capture.output(utils::str(x, give.attr = FALSE, vec.len = 6)), collapse = "\n"),
    error = function(e) ""
  )
  if (nchar(txt) > max_chars) txt <- paste0(substr(txt, 1, max_chars), "\n...")
  txt
}

# Minimal JSON encoder: named list -> object, unnamed list -> array,
# length-1 atomic -> scalar, longer atomic -> array.
rgame_json <- function(x) {
  esc <- function(s) {
    s <- enc2utf8(as.character(s))
    s <- gsub("\\", "\\\\", s, fixed = TRUE)
    s <- gsub("\"", "\\\"", s, fixed = TRUE)
    s <- gsub("\n", "\\n", s, fixed = TRUE)
    s <- gsub("\r", "\\r", s, fixed = TRUE)
    s <- gsub("\t", "\\t", s, fixed = TRUE)
    s <- gsub("[\001-\037]", "", s, useBytes = TRUE)
    paste0("\"", s, "\"")
  }
  scalar <- function(v) {
    if (is.na(v)) return("null")
    if (is.logical(v)) return(if (v) "true" else "false")
    if (is.numeric(v)) return(if (is.finite(v)) format(v, digits = 15) else "null")
    esc(v)
  }
  if (is.null(x)) return("null")
  if (is.list(x)) {
    if (!is.null(names(x))) {
      parts <- vapply(names(x), function(n) paste0(esc(n), ":", rgame_json(x[[n]])), "")
      return(paste0("{", paste(parts, collapse = ","), "}"))
    }
    return(paste0("[", paste(vapply(x, rgame_json, ""), collapse = ","), "]"))
  }
  if (length(x) == 1) return(scalar(x))
  paste0("[", paste(vapply(as.list(x), scalar, ""), collapse = ","), "]")
}

rgame_pass <- function(msg = NULL) list(pass = TRUE, messages = as.character(msg))
rgame_fail <- function(msg = "Not quite right yet.") list(pass = FALSE, messages = as.character(msg))

rgame_error_text <- function(e) {
  msg <- conditionMessage(e)
  if (grepl("elapsed time limit", msg, fixed = TRUE)) {
    return("Your code took too long to run and was stopped (is there an infinite loop?).")
  }
  call <- conditionCall(e)
  call_txt <- if (is.null(call)) "" else paste(deparse(call, nlines = 1), collapse = "")
  if (!nzchar(call_txt) || startsWith(call_txt, "eval(") || startsWith(call_txt, "withVisible(")) {
    paste0("Error: ", msg)
  } else {
    paste0("Error in ", call_txt, ": ", msg)
  }
}

# ---- running code ------------------------------------------------------------

# Evaluate `code` in `env` the way the R console would: one expression at a
# time, printing visible values, collecting warnings, stopping at the first
# error. Visible ggplot objects are *not* printed here (the JS side asks for a
# render separately, so plots are never drawn on the wrong device).
rgame_eval <- function(code, env, timeout = 10, max_output = 20000) {
  res <- list(error = NULL, warnings = character(), value = NULL,
              has_value = FALSE, output = "")

  exprs <- tryCatch(
    parse(text = code, keep.source = FALSE),
    error = function(e) {
      res$error <<- paste0("Syntax error: ", sub("^<text>:", "line ", conditionMessage(e)))
      NULL
    }
  )
  if (!is.null(res$error)) return(res)

  setTimeLimit(elapsed = timeout, transient = TRUE)
  on.exit(setTimeLimit(cpu = Inf, elapsed = Inf), add = TRUE)

  out <- tryCatch(
    utils::capture.output({
      for (i in seq_along(exprs)) {
        ok <- withCallingHandlers(
          tryCatch({
            r <- withVisible(eval(exprs[[i]], env))
            res["value"] <- list(r$value)
            res$has_value <- TRUE
            if (r$visible && !rgame_is_ggplot(r$value)) print(r$value)
            TRUE
          }, error = function(e) {
            setTimeLimit(cpu = Inf, elapsed = Inf)
            res$error <<- rgame_error_text(e)
            FALSE
          }),
          warning = function(w) {
            res$warnings <<- c(res$warnings, conditionMessage(w))
            invokeRestart("muffleWarning")
          },
          message = function(m) {
            cat(conditionMessage(m))
            invokeRestart("muffleMessage")
          }
        )
        if (!ok) break
      }
    }),
    error = function(e) {
      res$error <<- rgame_error_text(e)
      character()
    }
  )

  out <- paste(out, collapse = "\n")
  if (nchar(out) > max_output) {
    out <- paste0(substr(out, 1, max_output), "\n... [output truncated]")
  }
  res$output <- out
  res
}

rgame_task_env <- function(task) {
  env <- new.env(parent = globalenv())
  set.seed(task$seed)
  if (nzchar(task$setup)) eval(parse(text = task$setup, keep.source = FALSE), env)
  env
}

# ---- loading a task (runs the reference solution to get "truth") -------------

rgame_load_task <- function(id, type = "value", setup = "", solution = "",
                            check = "", packages = "", seed = 42,
                            tolerance = 1.5e-8, ignore_attributes = FALSE,
                            variable = "", labels = "title,x,y", timeout = 10,
                            row_order = FALSE, col_order = FALSE,
                            show_target = FALSE) {
  fail <- function(msg) rgame_json(list(ok = FALSE, error = msg))

  for (p in rgame_split(packages)) {
    ok <- suppressWarnings(suppressPackageStartupMessages(
      requireNamespace(p, quietly = TRUE) &&
        tryCatch({ library(p, character.only = TRUE); TRUE }, error = function(e) FALSE)
    ))
    if (!ok) return(fail(sprintf("Package '%s' is not available in this R engine.", p)))
  }

  task <- list(
    id = id, type = type, setup = setup, solution = solution,
    seed = as.numeric(seed), tolerance = as.numeric(tolerance),
    ignore_attributes = isTRUE(as.logical(ignore_attributes)),
    variable = variable, labels = rgame_split(labels),
    timeout = as.numeric(timeout), check_fn = NULL,
    row_order = isTRUE(as.logical(row_order)),
    col_order = isTRUE(as.logical(col_order))
  )

  env <- tryCatch(rgame_task_env(task), error = function(e) e)
  if (inherits(env, "error")) {
    return(fail(paste("Task setup code failed:", conditionMessage(env))))
  }

  r <- rgame_eval(solution, env, timeout = max(60, task$timeout))
  if (!is.null(r$error)) return(fail(paste("Reference solution failed:", r$error)))

  if (nzchar(variable)) {
    if (!exists(variable, envir = env, inherits = FALSE)) {
      return(fail(sprintf("Reference solution did not create '%s'.", variable)))
    }
    task$expected <- get(variable, envir = env, inherits = FALSE)
  } else {
    task$expected <- r$value
  }
  task$expected_output <- r$output

  if (nzchar(check)) {
    ce <- new.env(parent = globalenv())
    err <- tryCatch({ eval(parse(text = check, keep.source = FALSE), ce); NULL },
                    error = function(e) conditionMessage(e))
    if (!is.null(err)) return(fail(paste("check.R failed to load:", err)))
    if (!exists("check", envir = ce, inherits = FALSE) || !is.function(ce$check)) {
      return(fail("check.R must define a function called check()."))
    }
    task$check_fn <- ce$check
  }

  .rgame$tasks[[id]] <- task

  # Text shown to the player as the "Target" (plots are rendered separately).
  target_text <- if (type == "output") {
    task$expected_output
  } else if (isTRUE(as.logical(show_target)) && !rgame_is_ggplot(task$expected)) {
    if (is.data.frame(task$expected)) rgame_table_text(task$expected)
    else paste(utils::capture.output(print(task$expected)), collapse = "\n")
  } else {
    ""
  }

  rgame_json(list(
    ok = TRUE,
    has_expected_plot = rgame_is_ggplot(task$expected),
    target_text = target_text
  ))
}

# ---- comparators -------------------------------------------------------------

rgame_compare_value <- function(user, expected, tolerance = 1.5e-8,
                                ignore_attributes = FALSE) {
  if (is.null(user) && !is.null(expected)) {
    return(rgame_fail("Your code didn't produce a value. Make sure the last line evaluates to your answer."))
  }
  ae <- tryCatch(
    all.equal(expected, user, tolerance = tolerance,
              check.attributes = !ignore_attributes),
    error = function(e) conditionMessage(e)
  )
  if (isTRUE(ae)) return(rgame_pass("Correct!"))

  msgs <- "Your answer doesn't match the expected result."
  de <- rgame_describe(expected)
  du <- rgame_describe(user)
  if (!identical(de, du)) {
    msgs <- c(msgs, sprintf("Expected %s, but your answer is %s.", de, du))
  }
  ae <- gsub("target", "expected", gsub("current", "your answer", ae))
  msgs <- c(msgs, utils::head(paste("Detail:", ae), 3))
  rgame_fail(msgs)
}

# Make tibbles, grouped tibbles and data frames comparable: plain data.frame,
# no row names or groups, factors as character.
rgame_plain_df <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE)
  x[] <- lapply(x, function(v) if (is.factor(v)) as.character(v) else v)
  attr(x, "groups") <- NULL
  rownames(x) <- NULL
  x
}

rgame_compare_table <- function(user, expected, row_order = FALSE,
                                col_order = FALSE, tolerance = 1.5e-8) {
  if (!is.data.frame(user)) {
    return(rgame_fail(c("Your answer should be a data frame (or tibble).",
                        sprintf("Your last value was %s.", rgame_describe(user)))))
  }
  u <- rgame_plain_df(user)
  e <- rgame_plain_df(expected)
  head_msg <- "Your table doesn't match the target."
  list_str <- function(v) paste(v, collapse = ", ")

  missing <- setdiff(names(e), names(u))
  extra <- setdiff(names(u), names(e))
  if (length(missing) || length(extra)) {
    msgs <- head_msg
    if (length(missing)) msgs <- c(msgs, sprintf("Missing column(s): %s.", list_str(missing)))
    if (length(extra)) msgs <- c(msgs, sprintf("Unexpected column(s): %s.", list_str(extra)))
    msgs <- c(msgs, sprintf("The target's columns are: %s.", list_str(names(e))))
    return(rgame_fail(msgs))
  }
  if (col_order && !identical(names(u), names(e))) {
    return(rgame_fail(c(head_msg, sprintf("The columns should be in this order: %s.", list_str(names(e))))))
  }
  u <- u[names(e)]

  if (nrow(u) != nrow(e)) {
    return(rgame_fail(c(head_msg, sprintf("The target has %d row(s); yours has %d.", nrow(e), nrow(u)))))
  }

  flat <- function(v) {
    if (is.list(v)) vapply(v, function(z) paste(format(z), collapse = ","), "") else v
  }
  same <- function(a, b) {
    a <- flat(a)
    b <- flat(b)
    if (is.numeric(a) != is.numeric(b)) return(FALSE) # e.g. numbers stored as text
    if (is.numeric(a) && is.numeric(b)) {
      isTRUE(all.equal(b, a, tolerance = tolerance, check.attributes = FALSE))
    } else {
      identical(as.character(a), as.character(b))
    }
  }
  sort_rows <- function(d) {
    if (!nrow(d)) return(d)
    keys <- lapply(d, function(v) { v <- flat(v); if (is.numeric(v)) signif(v, 8) else as.character(v) })
    d[do.call(order, c(unname(keys), list(na.last = TRUE))), , drop = FALSE]
  }

  # 1. Does each column hold the right values (in any order)?
  wrong <- character()
  too_many_na <- character()
  type_msgs <- character()
  for (nm in names(e)) {
    a <- flat(u[[nm]])
    b <- flat(e[[nm]])
    if (same(sort(a, na.last = TRUE), sort(b, na.last = TRUE))) next
    wrong <- c(wrong, nm)
    if (sum(is.na(a)) > sum(is.na(b))) {
      too_many_na <- c(too_many_na, nm)
    } else if (is.numeric(b) && !is.numeric(a)) {
      type_msgs <- c(type_msgs, sprintf("Column '%s' should be numeric, but yours is %s.", nm, class(u[[nm]])[1]))
    }
  }
  if (length(wrong)) {
    quoted <- function(v) {
      v <- sprintf("'%s'", v)
      if (length(v) == 1) v else paste(paste(v[-length(v)], collapse = ", "), "and", v[length(v)])
    }
    msgs <- c(head_msg, sprintf("The values in column%s %s differ from the target.",
                                if (length(wrong) > 1) "s" else "", quoted(wrong)))
    if (length(too_many_na)) {
      msgs <- c(msgs, sprintf(
        "%s more missing values (NA) than the target. Do you need na.rm = TRUE, to filter out NAs, or to fill in empty values?",
        if (length(too_many_na) > 1) paste(quoted(too_many_na), "have") else paste(quoted(too_many_na), "has")))
    }
    return(rgame_fail(c(msgs, type_msgs)))
  }

  # 2. Are the values combined into the same rows?
  us <- sort_rows(u)
  es <- sort_rows(e)
  if (!all(vapply(names(e), function(nm) same(us[[nm]], es[[nm]]), TRUE))) {
    return(rgame_fail(c(head_msg, "Each column has the right values, but they are combined into rows differently.")))
  }

  # 3. Are the rows in the right order (only if the task asks for it)?
  if (row_order && !all(vapply(names(e), function(nm) same(u[[nm]], e[[nm]]), TRUE))) {
    return(rgame_fail(c(head_msg, "You have the right rows, but not in the right order.")))
  }
  rgame_pass("Correct!")
}

rgame_compare_output <- function(user_output, expected_output) {
  norm <- function(s) {
    lines <- sub("\\s+$", "", strsplit(s, "\n", fixed = TRUE)[[1]])
    paste(lines[nzchar(lines) | cumsum(nzchar(lines)) > 0], collapse = "\n")
  }
  if (identical(trimws(norm(user_output)), trimws(norm(expected_output)))) {
    return(rgame_pass("Correct!"))
  }
  rgame_fail("Your printed output doesn't match the target output.")
}

rgame_geom_name <- function(layer) {
  cls <- class(layer$geom)[1]
  # geom_histogram() is stored as a bar geom with a binning stat.
  if (cls == "GeomBar" && class(layer$stat)[1] == "StatBin") return("geom_histogram")
  tolower(gsub("([a-z])([A-Z])", "\\1_\\2", cls))
}

rgame_labels <- function(p) {
  ns <- asNamespace("ggplot2")
  labs <- if (exists("get_labs", envir = ns)) {
    tryCatch(ggplot2::get_labs(p), error = function(e) p$labels)
  } else {
    p$labels
  }
  # A name given to a scale, e.g. scale_colour_manual(name = "Species"), is
  # what gets drawn, so it counts as that aesthetic's label.
  scales <- tryCatch(p$scales$scales, error = function(e) list())
  for (sc in scales) {
    nm <- tryCatch(sc$name, error = function(e) NULL)
    if (is.null(nm) || inherits(nm, "waiver")) next
    for (a in sc$aesthetics) labs[[a]] <- nm
  }
  lapply(labs, function(v) {
    if (is.null(v)) return(NA_character_)
    if (is.character(v)) return(paste(v, collapse = " "))
    paste(deparse(v), collapse = "")
  })
}

rgame_aes_names <- c(
  x = "x positions", y = "y positions", xmin = "xmin values", xmax = "xmax values",
  ymin = "ymin values", ymax = "ymax values",
  lower = "lower quartiles", middle = "medians", upper = "upper quartiles", xend = "xend values", yend = "yend values",
  xintercept = "xintercept values", yintercept = "yintercept values",
  colour = "colours", fill = "fill colours", size = "point sizes", shape = "shapes",
  alpha = "transparency (alpha)", linetype = "line types", linewidth = "line widths",
  label = "text labels", PANEL = "facet panels"
)

rgame_compare_layer <- function(u, e, i, geom, tolerance = 1e-6) {
  where <- sprintf("Layer %d (%s)", i, geom)
  # Rows with a missing x or y are never drawn, so ignore them. This way a
  # player who removed NAs first (na.omit, drop_na, ...) still matches.
  drop_na_pos <- function(d) {
    pos <- intersect(c("x", "y"), names(d))
    if (!length(pos)) return(d)
    keep <- stats::complete.cases(as.data.frame(lapply(d[pos], as.numeric)))
    d[keep, , drop = FALSE]
  }
  u <- drop_na_pos(u)
  e <- drop_na_pos(e)
  cols <- intersect(names(rgame_aes_names), names(e))
  missing <- setdiff(cols, names(u))
  extra <- setdiff(intersect(names(rgame_aes_names), names(u)), names(e))
  band <- c("ymin", "ymax")
  msgs <- character()
  if (geom == "geom_smooth" && all(band %in% missing)) {
    msgs <- c(msgs, sprintf("%s: the target shows a confidence band (se = TRUE) but yours doesn't.", where))
    missing <- setdiff(missing, band)
  }
  if (geom == "geom_smooth" && all(band %in% extra)) {
    msgs <- c(msgs, sprintf("%s: your plot shows a confidence band (se = TRUE) but the target doesn't.", where))
    extra <- setdiff(extra, band)
  }
  if (length(missing)) {
    msgs <- c(msgs, sprintf("%s: your plot is missing %s.", where,
                            paste(rgame_aes_names[missing], collapse = ", ")))
  }
  if (length(extra)) {
    msgs <- c(msgs, sprintf("%s: your plot has %s that the target doesn't.", where,
                            paste(rgame_aes_names[extra], collapse = ", ")))
  }
  cols <- intersect(cols, names(u))
  if (nrow(u) != nrow(e)) {
    return(c(msgs, sprintf("%s: expected %d drawn element(s) but yours has %d.",
                           where, nrow(e), nrow(u))))
  }
  if (!length(cols) || nrow(e) == 0) return(msgs)

  normalise <- function(d) {
    d <- lapply(cols, function(nm) {
      v <- d[[nm]]
      if (is.list(v)) v <- vapply(v, function(z) paste(format(z), collapse = ","), "")
      if (is.factor(v)) v <- as.character(v)
      if (nm %in% c("colour", "fill")) {
        v <- tryCatch({
          m <- grDevices::col2rgb(v, alpha = TRUE)
          grDevices::rgb(m[1, ], m[2, ], m[3, ], m[4, ], maxColorValue = 255)
        }, error = function(err) tolower(as.character(v)))
      }
      if (is.numeric(v)) as.numeric(v) else as.character(v)
    })
    names(d) <- cols
    d <- as.data.frame(d, stringsAsFactors = FALSE)
    d[do.call(order, unname(as.list(d))), , drop = FALSE]
  }
  same_values <- function(a, b) {
    if (is.numeric(a) && is.numeric(b)) {
      isTRUE(all.equal(b, a, tolerance = tolerance, check.attributes = FALSE))
    } else {
      identical(as.character(a), as.character(b))
    }
  }
  nu <- normalise(u)
  ne <- normalise(e)
  # Compare each aesthetic as a set of values first, so one wrong variable
  # gives one message; then check the values are paired up the same way.
  differ <- Filter(function(nm) {
    !same_values(sort(nu[[nm]], na.last = TRUE), sort(ne[[nm]], na.last = TRUE))
  }, cols)
  # Don't repeat the bar/box edges when the main position already differs.
  if ("x" %in% differ) differ <- setdiff(differ, c("xmin", "xmax", "xend"))
  if ("y" %in% differ) differ <- setdiff(differ, c("ymin", "ymax", "yend"))
  col_ok <- !length(differ)
  if (!col_ok) {
    what <- unname(rgame_aes_names[differ])
    what <- if (length(what) == 1) what else
      paste(paste(what[-length(what)], collapse = ", "), "and", what[length(what)])
    msgs <- c(msgs, sprintf("%s: the %s differ from the target.", where, what))
  }
  if (col_ok && !all(vapply(cols, function(nm) same_values(nu[[nm]], ne[[nm]]), TRUE))) {
    msgs <- c(msgs, sprintf("%s: the right values are there, but they are paired up differently (check which variable goes on which aesthetic).", where))
  }
  msgs
}

rgame_compare_ggplot <- function(user, expected, labels = c("title", "x", "y"),
                                 tolerance = 1e-6) {
  if (!rgame_is_ggplot(user)) {
    return(rgame_fail(c(
      "The last line of your code should produce a ggplot object, e.g. ggplot(df, aes(x, y)) + geom_point().",
      sprintf("Your last value was %s.", rgame_describe(user))
    )))
  }
  ub <- tryCatch(ggplot2::ggplot_build(user), error = function(e) e)
  if (inherits(ub, "error")) {
    return(rgame_fail(paste("Your plot could not be drawn:", conditionMessage(ub))))
  }
  eb <- ggplot2::ggplot_build(expected)

  msgs <- character()
  gu <- vapply(user$layers, rgame_geom_name, "")
  ge <- vapply(expected$layers, rgame_geom_name, "")
  # Geoms that draw identically are treated as the same.
  same_geom <- c(geom_col = "geom_bar")
  canon <- function(g) ifelse(g %in% names(same_geom), same_geom[g], g)
  if (!identical(unname(canon(gu)), unname(canon(ge)))) {
    fmt <- function(g) if (length(g)) paste(g, collapse = " + ") else "no layers"
    msgs <- c(msgs, sprintf("Expected the layer(s) %s, but your plot has %s.", fmt(ge), fmt(gu)))
  } else {
    for (i in seq_along(ge)) {
      msgs <- c(msgs, rgame_compare_layer(ub$data[[i]], eb$data[[i]], i, ge[i], tolerance))
    }
  }

  npu <- nrow(ub$layout$layout)
  npe <- nrow(eb$layout$layout)
  if (!identical(npu, npe)) {
    msgs <- msgs[!grepl("facet panels differ", msgs, fixed = TRUE)]
    msgs <- c(msgs,sprintf("Expected %d panel(s) (facets), but your plot has %d.", npe, npu))
  }

  if (length(labels)) {
    lu <- rgame_labels(user)
    le <- rgame_labels(expected)
    for (l in labels) {
      e_lab <- if (is.null(le[[l]])) NA_character_ else le[[l]]
      u_lab <- if (is.null(lu[[l]])) NA_character_ else lu[[l]]
      if (!identical(e_lab, u_lab)) {
        shown <- function(s) if (is.na(s)) "(none)" else sprintf("'%s'", s)
        msgs <- c(msgs, sprintf("The %s label should be %s, yours is %s.",
                                l, shown(e_lab), shown(u_lab)))
      }
    }
  }

  if (length(msgs)) rgame_fail(c("Your plot doesn't quite match the target.", msgs))
  else rgame_pass("Correct! Your plot matches the target.")
}

rgame_run_custom <- function(fn, user, expected, env, output) {
  args <- list(result = user, expected = expected, env = env, output = output)
  args <- args[intersect(names(args), names(formals(fn)))]
  r <- do.call(fn, args)
  if (isTRUE(r)) return(rgame_pass("Correct!"))
  if (is.list(r) && !is.null(r$pass)) return(r)
  if (is.character(r)) return(rgame_fail(r))
  rgame_fail("Not quite right yet.")
}

# ---- submitting an answer ----------------------------------------------------

rgame_submit <- function(id, code) {
  task <- .rgame$tasks[[id]]
  if (is.null(task)) {
    return(rgame_json(list(status = "error", messages = list("Task not loaded."))))
  }
  .rgame$plots$user <- NULL

  env <- rgame_task_env(task)
  r <- rgame_eval(code, env, timeout = task$timeout)

  user_value <- r$value
  status <- "error"
  messages <- character()

  if (!is.null(r$error)) {
    messages <- r$error
  } else {
    if (nzchar(task$variable)) {
      user_value <- if (exists(task$variable, envir = env, inherits = FALSE)) {
        get(task$variable, envir = env, inherits = FALSE)
      } else {
        NULL
      }
    }
    verdict <- tryCatch({
      if (!is.null(task$variable) && nzchar(task$variable) && is.null(user_value)) {
        rgame_fail(sprintf("Your code needs to create a variable called '%s'.", task$variable))
      } else if (!is.null(task$check_fn)) {
        rgame_run_custom(task$check_fn, user_value, task$expected, env, r$output)
      } else {
        switch(task$type,
          value = if (is.data.frame(task$expected)) {
            rgame_compare_table(user_value, task$expected, task$row_order,
                                task$col_order, task$tolerance)
          } else {
            rgame_compare_value(user_value, task$expected, task$tolerance,
                                task$ignore_attributes)
          },
          plot = rgame_compare_ggplot(user_value, task$expected, task$labels),
          output = rgame_compare_output(r$output, task$expected_output),
          rgame_fail(paste("Unknown task type:", task$type))
        )
      }
    }, error = function(e) list(pass = NA, messages = paste("The task's checker failed:", conditionMessage(e))))

    status <- if (isTRUE(verdict$pass)) "correct" else if (isFALSE(verdict$pass)) "incorrect" else "error"
    messages <- verdict$messages
  }

  if (rgame_is_ggplot(user_value)) .rgame$plots$user <- user_value

  rgame_json(list(
    status = status,
    messages = as.list(as.character(messages)),
    output = r$output,
    warnings = as.list(unique(r$warnings)),
    value_preview = if (task$type == "value" && is.null(r$error)) rgame_preview(user_value) else "",
    has_user_plot = rgame_is_ggplot(user_value)
  ))
}

# ---- drawing plots -----------------------------------------------------------

rgame_render <- function(which = "user", id = NULL) {
  p <- if (identical(which, "expected")) .rgame$tasks[[id]]$expected else .rgame$plots$user
  if (rgame_is_ggplot(p)) print(p)
  invisible(NULL)
}
