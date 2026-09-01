# 02_deliverables.R — ONE call that produces everything the poster needs.
#
# RUN IT (after 01_check.R looks right):
#   setwd("~/lancaster_lab")
#   source("src/workbench/02_deliverables.R")
#   out <- run_deliverables()
#
# ------------------------------------------------------------------------------------------------
# WHAT IT PRODUCES
#
#   reports/paper_tables_<date>.txt      TABLE 1 and TABLE 4 — ours beside the paper's       <- paste
#   reports/validation_summary_<date>.txt  the PHI-free readout: attrition, incidence, C, slope
#   reports/survival_readout_<date>.txt  the numbers behind the curves (written by the survival run)
#   figures/*.png                        demographics, survival curves, calibration
#   reports/manifest_<date>.txt          what was produced, what failed, and what each file is for
#
# Everything is copied to WORKSPACE_BUCKET when that is set to a real bucket; when it is not, the
# files sit on disk and the manifest says exactly where. A failed bucket copy is not a failed run,
# and the two used to be indistinguishable at a glance.
#
# ------------------------------------------------------------------------------------------------
# WHY IT IS BUILT AS FIVE INDEPENDENT STAGES
#
# The expensive stage is first and the fragile stage is third. If the paper tables blow up because
# AHAprevent is not installed, you should still come away with the cohort figures and the survival
# readout rather than an empty directory and a stack trace — so each stage is wrapped, records its
# own outcome, and the manifest tells you what you actually have. A partial run is a normal outcome
# on a fresh Workbench instance and it should not read as a catastrophe.
#
# The corollary, and it matters more: **a missing artifact is reported, never silently skipped.**
# The failure this guards against is presenting four figures and a table without noticing that the
# fifth was never produced, which is how a caveat quietly disappears between the run and the poster.
#
# ------------------------------------------------------------------------------------------------
# WHAT LEAVES THE WORKBENCH
#
# The reports are aggregate-only and suppressed at 20 (.MIN_CELL), and paper_tables.R treats 20 as a
# FLOOR — a lower value found elsewhere is raised, not honoured. The FIGURES are the part to look at
# before exporting: a histogram with a visible bar of three people is a small cell, even though no
# number is printed next to it. The manifest says this too, at the point of use.
# ------------------------------------------------------------------------------------------------

.dlv_root_ok <- function() file.exists("src/figures/survival_curves.R")

#' One call: run the analysis and write every artifact the poster needs.
#'
#' @param con  open DBI connection, or NULL to open (and close) one.
#' @param figdir,repdir  output directories.
#' @param require_smoking  demographics figures with smoking REQUIRED (D-013's reading). See
#'   01_check.R. Kept aligned with the survival run's `attach_smoking_status` so the demographic
#'   figures describe the SAME cohort the tables are computed on — the alternative is a Table 1 and a
#'   set of figures that disagree about N, which is worse than either choice on its own.
#' @param horizon_years  calibration horizon. NULL = derived from the 75th percentile of follow-up,
#'   which keeps the KM estimate off the thin tail where a calibration plot fabricates
#'   miscalibration out of a handful of people.
#' @param copy_to_bucket  gsutil the outputs to WORKSPACE_BUCKET when it is a real bucket.
#' @param landmark,end_of_followup,scorable_only  passed straight to run_survival_curves(). Leave as
#'   NULL/TRUE in the Workbench — the landmark is *derived*, and a hand-picked one is a study-design
#'   choice made by accident. They exist because the fixture is 300 people: offline, no candidate
#'   landmark clears the 200-complete-panel bar, so the run cannot be smoke-tested at all without
#'   them. A script that can only be exercised against real data is a script whose first real run is
#'   also its first test.
#'   Offline smoke test (fixture-only settings, WRONG in the Workbench — see run_deliverables_fixture):
#'     run_deliverables(landmark = as.Date("2016-01-01"), scorable_only = FALSE,
#'                      require_smoking = FALSE, copy_to_bucket = FALSE)
#' @return invisibly, list(res, cal, tables, status, manifest_path).
run_deliverables <- function(con = NULL, figdir = "figures", repdir = "reports",
                             require_smoking = TRUE, horizon_years = NULL,
                             copy_to_bucket = TRUE,
                             landmark = NULL, end_of_followup = NULL, scorable_only = TRUE) {
  if (!.dlv_root_ok())
    stop("run_deliverables(): working directory is not the repo root.
  In the Workbench:  setwd(\"~/lancaster_lab\")
  Current wd: ", getwd(), call. = FALSE)

  source("src/phenotype/R/run_sql.R")
  source("src/figures/survival_curves.R")
  source_survival_deps(quiet = TRUE)
  source("src/figures/prevent_calibration.R")
  source("src/figures/cohort_overview.R")
  source("src/ascvd/validation/export_validation_summary.R")
  source("src/ascvd/validation/paper_tables.R")

  if (is.null(con)) {
    con <- connect_cdr()
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  }
  for (d in c(figdir, repdir)) if (!dir.exists(d)) dir.create(d, recursive = TRUE)

  # Three states, not two. A stage that runs without erroring has NOT necessarily produced what it
  # was for: make_prevent_calibration_figures() returns an object and warns when nobody was scorable,
  # and render_paper_tables() prints Table 1 and quietly skips Table 4 when that object is empty. A
  # manifest that reports both as "OK" is worse than no manifest — it is a document asserting you have
  # a C-statistic when you do not. So each stage declares what a *complete* result looks like, and
  # anything short of it is PARTIAL with the reason attached.
  status <- list()
  note   <- function(stage, state, detail) status[[stage]] <<- list(state = state, detail = detail)
  say    <- function(...) message(sprintf(...))
  stage  <- function(name, expr, complete_when = NULL, partial_msg = "") {
    say("\n=== %s ===", name)
    tryCatch({
      v <- force(expr)
      if (!is.null(complete_when) && !isTRUE(complete_when(v))) {
        note(name, "PARTIAL", partial_msg); say("  PARTIAL: %s", partial_msg)
      } else note(name, "OK", "")
      v
    }, error = function(e) { note(name, "FAILED", conditionMessage(e))
                             say("  FAILED: %s", conditionMessage(e)); NULL })
  }

  # -- 1. the survival run: cohort, attrition, landmark, incidence vs the literature ---------------
  # Required. Everything else is computed FROM its at-risk frame, so there is no partial-credit path
  # if this fails — which is why it is the one stage that stops the run rather than being recorded.
  res <- stage("1/5 survival run (cohort, attrition, incidence)",
    run_survival_curves(con, outdir = figdir,
                        landmark = landmark, end_of_followup = end_of_followup,
                        scorable_only = scorable_only,
                        attach_smoking_status = require_smoking,
                        copy_to_bucket = FALSE, refresh = FALSE))
  if (is.null(res))
    stop("run_deliverables(): the survival run failed, and every downstream artifact is computed
  from its at-risk frame. Fix this before continuing — the message above names the cause. If it is
  'no cohort at any candidate landmark', that is D-017's as-of rule, not a bug: see
  docs/workbench_survival_runbook.md.", call. = FALSE)

  # -- 2. calibration + discrimination ------------------------------------------------------------
  # Needs AHAprevent and a scored panel. This is the stage most likely to fail on a fresh instance,
  # and it is the one that carries the C-statistic — so its failure is called out loudly rather than
  # left to surface later as an unexplained "Table 4 skipped".
  cal <- stage("2/5 calibration and C-statistic",
    make_prevent_calibration_figures(res, outdir = figdir, horizon_years = horizon_years),
    complete_when = function(v) !is.null(v) &&
      (!is.null(v$concordance_by_sex) || !is.null(v$calibration_by_sex)),
    partial_msg = "ran, but produced NO C-statistic and NO calibration table — nobody was scorable")
  if (!identical(status[["2/5 calibration and C-statistic"]]$state, "OK"))
    say("  -> Table 4 will be SKIPPED, and Table 4 IS the validation claim. Without it you have a
  cohort description and no performance result. Usual causes: AHAprevent not installed
  (remotes::install_github(\"AHA-DS-Analytics/PREVENT\")); or PREVENT returned NA for everyone,
  which happens when ANY single input is missing — check bp_tx and smoking in the 01_check output.")

  # -- 3. the paper tables ------------------------------------------------------------------------
  tabs <- stage("3/5 paper tables (Table 1 and Table 4)",
    render_paper_tables(res, cal, outdir = repdir, events_from = "acute"),
    complete_when = function(v) !is.null(v) && !is.null(v$table4),
    partial_msg = "Table 1 written; TABLE 4 ABSENT — no C-statistic, no calibration slope")

  # -- 4. demographic figures ---------------------------------------------------------------------
  stage("4/5 demographic figures",
    make_cohort_figures(con, outdir = figdir, require_smoking = require_smoking))

  # -- 5. the PHI-free validation summary ---------------------------------------------------------
  sum_path <- file.path(repdir, sprintf("validation_summary_%s.txt", Sys.Date()))
  stage("5/5 validation summary",
    export_validation_summary(res, cal, path = sum_path))

  # -- manifest -----------------------------------------------------------------------------------
  figs  <- sort(list.files(figdir, pattern = "\\.png$", full.names = FALSE))
  reps  <- sort(list.files(repdir, pattern = "\\.txt$", full.names = FALSE))
  state <- vapply(status, function(s) s$state, character(1))
  det   <- vapply(status, function(s) s$detail, character(1))
  ok    <- state == "OK"

  man <- c(
    "DELIVERABLES MANIFEST",
    sprintf("generated : %s", format(Sys.time(), "%Y-%m-%d %H:%M")),
    sprintf("CDR       : %s", Sys.getenv("WORKSPACE_CDR", "<unset — offline fixture run>")),
    sprintf("cohort    : landmark %s -> %s", format(res$landmark), format(res$end_of_followup)),
    sprintf("smoking   : %s", if (require_smoking) "REQUIRED (no answer => excluded)"
                              else "NOT required (FALSE for everyone — risk biased DOWN)"),
    "",
    "-- stages --",
    sprintf("  %-42s %-8s%s", names(status), state,
            ifelse(nzchar(det), paste0(" — ", det), "")),
    if (!all(ok)) c("",
      "  PARTIAL means the stage ran without erroring and did not produce what it is for.",
      "  Read the reason before treating the artifact set as complete."),
    "",
    "-- reports (aggregate only, suppressed at 20 — safe to paste) --",
    if (length(reps)) sprintf("  %s/%s", repdir, reps) else "  (none)",
    "",
    "-- figures --",
    if (length(figs)) sprintf("  %s/%s", figdir, figs) else "  (none)",
    "",
    "-- BEFORE ANY OF THIS GOES ON A POSTER --",
    "1. State the cohort on every number. These are EHR-cohort results, not srWGS-cohort results,",
    "   until H-005 is resolved (A-017). 'Participants with EHR data' is true and defensible;",
    "   letting a reader assume it is the genomics cohort is not.",
    "2. Calibration is claimable only WITH the incidence check. Under-ascertained outcomes and a",
    "   genuinely over-predicting model look identical on a calibration plot (DESIGN 6.3).",
    "3. The interval columns are not the same quantity. Ours is a 95% sampling CI in one cohort;",
    "   the paper's is an IQI across 21 cohorts. Never merge them into one '95%' column.",
    "4. Death is not wired in, so our observed risk — and therefore our calibration slope — is",
    "   biased UPWARD. This is the largest methodological gap and it belongs on the poster.",
    "5. Check the FIGURES for small cells. The reports are suppressed automatically; a histogram",
    "   bar of three people is a small cell that no suppression rule caught.",
    "6. 'PREVENT is validated in All of Us' is not a supportable sentence from this analysis.")
  man_path <- file.path(repdir, sprintf("manifest_%s.txt", Sys.Date()))
  writeLines(man, man_path)
  cat(paste(man, collapse = "\n"), "\n")

  # -- bucket -------------------------------------------------------------------------------------
  bucket <- Sys.getenv("WORKSPACE_BUCKET")
  if (isTRUE(copy_to_bucket)) {
    looks_real <- nzchar(bucket) && grepl("^gs://[a-z0-9][a-z0-9._-]{2,}$", bucket) &&
                  !grepl("\\.\\.\\.", bucket)
    if (!looks_real) {
      say("\nNOT copying to a bucket: WORKSPACE_BUCKET is %s.",
          if (!nzchar(bucket)) "unset" else sprintf("'%s', which is not a valid bucket name", bucket))
      say("  Everything is on disk — download from the Workbench file browser:")
      say("    %s", normalizePath(figdir, winslash = "/", mustWork = FALSE))
      say("    %s", normalizePath(repdir, winslash = "/", mustWork = FALSE))
    } else {
      for (cmd in c(sprintf("gsutil -m cp %s/*.png %s/figures/", figdir, bucket),
                    sprintf("gsutil -m cp %s/*.txt %s/reports/", repdir, bucket))) {
        say("copying: %s", cmd)
        try(system(cmd), silent = TRUE)
      }
      say("  (if a copy failed, the files are still on disk — that is not a failed run)")
    }
  }

  if (!all(ok))
    say("\n*** %d of %d stages did NOT complete (%s) — see the manifest. Do not assume the missing
  artifact was optional; check what it was for before building the poster without it. ***",
        sum(!ok), length(ok), paste(unique(state[!ok]), collapse = " + "))

  invisible(list(res = res, cal = cal, tables = tabs, status = status, manifest_path = man_path))
}

#' Offline smoke test against the fixture. NOT a scientific run.
#'
#' Every setting here is wrong for the Workbench and right for a 300-person synthetic CDR:
#'   scorable_only = FALSE   — the fixture has 4 complete panels; a 4-person at-risk set carries no
#'                             events, so nothing downstream would execute and the whole path would
#'                             go unchecked. Relaxing it exercises the run on ~160 people.
#'   landmark = 2016-01-01   — chosen, not derived. choose_landmark() cannot clear its 200-panel bar
#'                             on a fixture this size, and lowering that bar for real data would be a
#'                             silent design change.
#'   require_smoking = FALSE — survey smoking coverage in the fixture is near zero.
#'
#' The point is not the numbers, which are meaningless. It is that all five stages run, every
#' artifact is written, and the manifest is accurate — so the first Workbench run is not also the
#' first time this code has ever executed.
run_deliverables_fixture <- function(outdir = "reports/deliverables_fixture_demo") {
  source("src/phenotype/R/run_sql.R")
  con <- connect_cdr()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  message("FIXTURE SMOKE TEST — the numbers are synthetic and mean nothing.")
  run_deliverables(con, figdir = file.path(outdir, "figures"), repdir = outdir,
                   landmark = as.Date("2016-01-01"), scorable_only = FALSE,
                   require_smoking = FALSE, copy_to_bucket = FALSE)
}
