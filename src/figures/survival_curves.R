# survival_curves.R — one-shot survival-curve driver for the All of Us Workbench. T-021.
#
# PURPOSE: produce Kaplan-Meier curves for incident ASCVD, plus the NUMBERS behind them, in one call,
# without the caller having to know the landmark, the CDR cutoff, or which figure depends on which
# unresolved question.
#
# WORKBENCH (the whole run):
#   setwd("~/lancaster_lab")
#   source("src/figures/survival_curves.R")
#   res <- run_survival_curves()          # connects, picks dates, writes figures, prints the readout
#
# OFFLINE (fixture, layout QA only — the numbers are synthetic):
#   Rscript src/figures/survival_curves.R
#
# ------------------------------------------------------------------------------------------------
# WHAT THIS IS AND IS NOT
#
# It IS: the anchor-free half of the incidence analysis — curves built from event DATES and a shared
# landmark. Covariate VALUES never enter, so the unresolved Q-S6 baseline anchor cannot bias them.
#
# It is NOT the case-anchored cohort (D-019, `risk_set_sampling.R`). That design has no shared clock —
# each case anchors at their own event date minus 30 days — so it answers "does PREVENT rank cases
# above controls", not "what fraction develop ASCVD by year 4". A survival curve needs a common time
# origin, which is what the landmark is for. Both are correct; they answer different questions, and
# putting a KM curve on a case-anchored cohort would be wrong.
#
# It is PRELIMINARY in three named ways, all printed with the readout so they reach the slide:
#   1. Death is not wired in — competing risk is treated as censoring, which OVERSTATES incidence.
#   2. ICD10CM only — pre-~Oct-2015 events are invisible, which left-truncates and mis-assigns
#      prevalence.
#   3. Everyone event-free is censored at the CDR cutoff, not at last contact, which INFLATES
#      person-time and pushes the rate down.
# ------------------------------------------------------------------------------------------------

suppressPackageStartupMessages({ library(dplyr) })

.SURV_SOURCES <- c(
  "src/phenotype/R/run_sql.R",
  "src/phenotype/R/egfr.R",
  "src/phenotype/R/extract_prevent.R",
  "src/phenotype/R/extract_smoking.R",
  "src/phenotype/R/extract_ascvd_events.R",
  "src/ascvd/prevent/run_prevent.R",
  "src/ascvd/validation/literature_benchmarks.R",
  "src/figures/incidence_overview.R")

#' Source everything the survival run needs, from the repo root.
#'
#' Separate from the run itself so a caller who already sourced things does not double-source, and so
#' a missing file names itself rather than surfacing later as "could not find function".
source_survival_deps <- function(root = ".", quiet = FALSE) {
  missing <- character(0)
  for (p in .SURV_SOURCES) {
    f <- file.path(root, p)
    if (file.exists(f)) source(f) else missing <- c(missing, p)
  }
  if (length(missing))
    stop(sprintf("source_survival_deps(): missing %d file(s) — is the working directory the repo root?
  %s", length(missing), paste(missing, collapse = "\n  ")), call. = FALSE)
  if (!requireNamespace("survival", quietly = TRUE))
    stop("the `survival` package is not installed. In the Workbench: install.packages('survival')",
         call. = FALSE)
  if (!quiet) message("sourced ", length(.SURV_SOURCES), " files; survival ",
                      as.character(utils::packageVersion("survival")))
  invisible(TRUE)
}

#' Derive the administrative censoring date from the data, rather than guessing it.
#'
#' The CDR cutoff is not a parameter anyone should be inventing: it is a property of the dataset, and
#' getting it wrong silently rescales every incidence rate. Takes the LATEST date across the three
#' tables that can carry an event or a measurement, because censoring earlier than the data actually
#' runs throws away real follow-up.
#'
#' @return list(end_of_followup, per_table) — `per_table` is printed so an outlier date (a data-entry
#'   year 2099) is visible rather than silently becoming the cutoff.
derive_end_of_followup <- function(con) {
  q <- function(sql) tryCatch(as.Date(DBI::dbGetQuery(con, sql)[[1]][1]), error = function(e) as.Date(NA))
  per_table <- c(
    condition = q("SELECT MAX(CAST(condition_start_date AS DATE)) FROM condition_occurrence"),
    procedure = q("SELECT MAX(CAST(procedure_date AS DATE)) FROM procedure_occurrence"),
    measurement = q("SELECT MAX(CAST(measurement_date AS DATE)) FROM measurement"))
  per_table <- per_table[!is.na(per_table)]
  if (!length(per_table))
    stop("derive_end_of_followup(): no dates found in condition/procedure/measurement.", call. = FALSE)
  # Guard the 2099 case: a single absurd date should not become the cutoff for everyone.
  today_ish <- as.Date("2030-01-01")
  sane <- per_table[per_table < today_ish]
  if (!length(sane)) sane <- per_table
  list(end_of_followup = max(sane), per_table = per_table)
}

#' Pick a landmark that actually yields a cohort, and say why it was picked.
#'
#' The landmark is a real decision (see the runbook), but a landmark that leaves NOBODY with a
#' complete panel is not a decision, it is a bug — and it is the exact failure mode of the `as_of`
#' rule added by D-017: the panel is built as-of the landmark, so a landmark earlier than most
#' people's measurements produces an empty cohort with a correct-looking error. This walks candidate
#' dates from LATEST to earliest and returns the first that clears both bars:
#'   - at least `min_followup_years` of follow-up remains before the cutoff, and
#'   - at least `min_n` people have a complete panel as of that date.
#'
#' Latest-first is deliberate: a later landmark means more people have accumulated a panel, and the
#' binding constraint is panel completeness, not follow-up length. The chosen date is REPORTED, so
#' this is a defensible default someone can override — not an invisible one.
#'
#' @return list(landmark, end_of_followup, tried = data.frame(candidate, n_panel, n_complete, years))
choose_landmark <- function(con, end_of_followup, candidates = NULL,
                            min_followup_years = 2, min_n = 200,
                            attach_smoking_status = TRUE) {
  end_of_followup <- as.Date(end_of_followup)
  if (is.null(candidates)) {
    # January 1 of each year leaving >= min_followup_years, newest first.
    last_yr <- as.integer(format(end_of_followup - min_followup_years * 365.25, "%Y"))
    candidates <- as.Date(sprintf("%d-01-01", seq(last_yr, last_yr - 7)))
  }
  candidates <- as.Date(candidates)
  smk <- NULL
  tried <- data.frame(candidate = as.Date(character(0)), n_panel = integer(0),
                      n_complete = integer(0), years = numeric(0))
  for (d in as.list(candidates)) {
    yrs <- as.numeric(end_of_followup - d) / 365.25
    if (yrs < min_followup_years) next
    panel <- tryCatch(extract_prevent_panel(con, as_of = d), error = function(e) NULL)
    if (is.null(panel)) next
    if (isTRUE(attach_smoking_status) && exists("extract_smoking", mode = "function")) {
      if (is.null(smk)) smk <- tryCatch(extract_smoking(con), error = function(e) NULL)
      if (!is.null(smk)) panel <- attach_smoking(panel, smk)
    }
    col <- if (isTRUE(attach_smoking_status) && "complete_panel_smoking" %in% names(panel))
             "complete_panel_smoking" else "complete_panel"
    n_complete <- sum(panel[[col]], na.rm = TRUE)
    tried <- rbind(tried, data.frame(candidate = d, n_panel = nrow(panel),
                                     n_complete = n_complete, years = round(yrs, 2)))
    if (n_complete >= min_n)
      return(list(landmark = d, end_of_followup = end_of_followup, tried = tried))
  }
  stop(sprintf("choose_landmark(): no candidate landmark yields >= %d complete panels with >= %.1f
  years of follow-up before %s. Tried:\n%s\nEither the cutoff is wrong, or the panel is far sparser
  than expected — check derive_end_of_followup() and sql/02 before overriding min_n.",
               min_n, min_followup_years, format(end_of_followup),
               paste(utils::capture.output(print(tried)), collapse = "\n")), call. = FALSE)
}

#' Cumulative incidence at fixed horizons, with a confidence interval — the readout, not the picture.
#'
#' A curve is unreadable off a projector at the back of a room. These are the numbers to say out loud,
#' and the CI is what makes "2.8%" honest when it rests on 40 events.
#'
#' @param at_risk  the frame from ascvd_status_at() (NA `event` rows are excluded — those are the
#'   prevalent and short-interval exclusions, which must not enter a denominator).
#' @param times    horizons in YEARS.
#' @return data.frame(years, n_risk, n_event, cuminc_pct, lower_pct, upper_pct)
km_at <- function(at_risk, times = c(1, 2, 3, 4, 5), group = NULL) {
  d <- at_risk[!is.na(at_risk$event) & !is.na(at_risk$followup_days) & at_risk$followup_days >= 0, ]
  if (!nrow(d)) return(NULL)
  f <- if (is.null(group)) survival::Surv(d$followup_days, d$event) ~ 1 else
       stats::as.formula(sprintf("survival::Surv(followup_days, event) ~ %s", group))
  fit <- survival::survfit(f, data = d)
  s <- summary(fit, times = times * 365.25, extend = TRUE)
  strata <- if (is.null(s$strata)) rep("all", length(s$time)) else
            sub("^[^=]*=", "", as.character(s$strata))
  # survfit's `upper` is an upper bound on SURVIVAL, so it becomes the LOWER bound on cumulative
  # incidence. Flipping these is a classic and completely silent error.
  data.frame(strata = strata,
             years      = round(s$time / 365.25, 2),
             n_risk     = s$n.risk,
             n_event    = s$n.event,
             cuminc_pct = round(100 * (1 - s$surv), 2),
             lower_pct  = round(100 * (1 - s$upper), 2),
             upper_pct  = round(100 * (1 - s$lower), 2),
             stringsAsFactors = FALSE)
}

#' The whole survival run: connect, choose dates, write figures, print the readout.
#'
#' @param con  open DBI connection, or NULL to call connect_cdr().
#' @param landmark,end_of_followup  NULL to derive them (and report the derivation).
#' @param outdir  where the PNGs go.
#' @param copy_to_bucket  gsutil the PNGs to WORKSPACE_BUCKET/figures/ when running in the Workbench.
#' @param refresh  re-source the pipeline files even if they appear to be loaded already. TRUE by
#'   default, and it is the default for a reason: an R session in the Workbench is long-lived and
#'   survives a `git pull`, so functions defined from an OLDER checkout stay in the global environment
#'   looking perfectly present. Guarding on `exists()` asks "is it defined?" when the question is "is
#'   it CURRENT?" -- and the failure is an `unused argument` error pointing at a call site that is
#'   correct, which sends you looking in the wrong file. Set FALSE only if you have deliberately
#'   modified one of these functions in-session and want to keep your version.
#' @return list(frame, km, km_acute, km_by_sex, landmark, end_of_followup, summary_path)
run_survival_curves <- function(con = NULL, outdir = "figures",
                                landmark = NULL, end_of_followup = NULL,
                                attach_smoking_status = TRUE,
                                min_days_panel_to_event = 30,
                                scorable_only = TRUE,
                                horizons = c(1, 2, 3, 4, 5),
                                copy_to_bucket = TRUE, refresh = TRUE) {
  if (isTRUE(refresh) || !exists("make_incidence_figures", mode = "function"))
    source_survival_deps(quiet = TRUE)
  # Fail on a STALE signature with a message that names the cause. Without this the symptom is
  # `unused argument (min_days_panel_to_event = ...)` raised inside make_incidence_figures(), which
  # reads as a bug in the caller rather than as a stale definition, and costs ten minutes of reading
  # a call site that is correct.
  if (!"min_days_panel_to_event" %in% names(formals(make_incidence_figures)))
    stop("make_incidence_figures() is an OLD version — it has no `min_days_panel_to_event` argument
  (added with D-017). The file on disk is behind. In the Workbench TERMINAL tab:
      cd ~/lancaster_lab && git pull && git log --oneline -1
  then re-run. If the pull is current, something else in the session is masking it: restart R.",
         call. = FALSE)
  own_con <- FALSE
  if (is.null(con)) { con <- connect_cdr(); own_con <- TRUE
                      on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE) }
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

  say <- function(...) message(sprintf(...))
  say("\n=== 1. dates ===")
  if (is.null(end_of_followup)) {
    d <- derive_end_of_followup(con)
    end_of_followup <- d$end_of_followup
    say("  max date per table: %s",
        paste(sprintf("%s=%s", names(d$per_table), format(d$per_table)), collapse = "  "))
    say("  end_of_followup (derived) : %s", format(end_of_followup))
  } else {
    end_of_followup <- as.Date(end_of_followup)
    say("  end_of_followup (supplied): %s", format(end_of_followup))
  }
  if (is.null(landmark)) {
    ch <- choose_landmark(con, end_of_followup, attach_smoking_status = attach_smoking_status)
    landmark <- ch$landmark
    say("  landmark candidates tried:")
    for (i in seq_len(nrow(ch$tried)))
      say("    %s  panel=%s  complete=%s  follow-up=%.1f y", format(ch$tried$candidate[i]),
          format(ch$tried$n_panel[i], big.mark = ","),
          format(ch$tried$n_complete[i], big.mark = ","), ch$tried$years[i])
    say("  landmark (chosen)         : %s  <- latest date with a usable cohort", format(landmark))
  } else {
    landmark <- as.Date(landmark)
    say("  landmark (supplied)       : %s", format(landmark))
  }
  say("  follow-up window          : %.2f years", as.numeric(end_of_followup - landmark) / 365.25)

  say("\n=== 2. building the cohort and writing figures (this is the slow part) ===")
  fr <- make_incidence_figures(con, outdir = outdir, landmark = landmark,
                               end_of_followup = end_of_followup,
                               scorable_only = scorable_only,
                               attach_smoking_status = attach_smoking_status,
                               min_days_panel_to_event = min_days_panel_to_event)

  say("\n=== 3. attrition ===")
  print(fr$counts)

  km       <- km_at(fr$at_risk,       horizons)
  km_acute <- km_at(fr$at_risk_acute, horizons)
  km_sex   <- if ("sex" %in% names(fr$at_risk)) km_at(fr$at_risk, horizons, group = "sex") else NULL

  say("\n=== 4. cumulative incidence — ALL ASCVD (D-016 primary outcome) ===")
  print(km)
  say("\n=== 4b. cumulative incidence — ACUTE ONLY (the literature-comparable outcome) ===")
  print(km_acute)
  if (!is.null(km_sex)) { say("\n=== 4c. by sex ==="); print(km_sex) }

  say("\n=== 5. does the rate agree with the published PREVENT rate? ===")
  # `outcome` must MATCH the frame being passed. It is not cosmetic: it selects which benchmark band
  # the rate is judged against, and the checker refuses to issue a verdict on the broad outcome at all
  # (the published rate is a hard-outcome rate). Passing the acute frame while leaving outcome at its
  # "broad" default produces a NOT COMPARABLE non-answer on the one comparison that was the point.
  lit <- NULL
  if (exists("check_incidence_from_status", mode = "function")) {
    lit <- list()
    lit$acute <- tryCatch(check_incidence_from_status(
             fr$at_risk_acute, outcome = "acute_event",
             label = sprintf("acute ASCVD, landmark %s", format(landmark))),
             error = function(e) { message("  literature check failed: ", conditionMessage(e)); NULL })
    lit$broad <- tryCatch(check_incidence_from_status(
             fr$at_risk, outcome = "broad",
             label = sprintf("all ASCVD (D-016), landmark %s", format(landmark))),
             error = function(e) NULL)
  } else message("  literature_benchmarks.R not sourced — skipping.")

  # Write the readout to a file so it can leave the Workbench by copy-paste. Aggregate only, small
  # cells are the caller's responsibility to check before pasting (H-006: suppress < 20).
  summary_path <- file.path(outdir, sprintf("survival_readout_%s.txt", format(Sys.Date())))
  con_out <- file(summary_path, open = "wt")
  writeLines(c(
    sprintf("SURVIVAL READOUT  %s", format(Sys.Date())),
    sprintf("landmark %s -> end_of_followup %s (%.2f years)", format(landmark),
            format(end_of_followup), as.numeric(end_of_followup - landmark) / 365.25),
    sprintf("smoking: %s", fr$smoking_source),
    sprintf("30-day panel-to-event rule (D-017): %d days", min_days_panel_to_event),
    "", "-- attrition --", utils::capture.output(print(fr$counts)),
    "", "-- cumulative incidence, ALL ASCVD --", utils::capture.output(print(km)),
    "", "-- cumulative incidence, ACUTE ONLY --", utils::capture.output(print(km_acute)),
    if (!is.null(km_sex)) c("", "-- by sex --", utils::capture.output(print(km_sex))),
    "", "-- caveats that belong on the slide --",
    "1. death not wired in: competing risk treated as censoring -> incidence OVERSTATED",
    "2. ICD10CM only: pre-~Oct-2015 events invisible -> early years left-truncated",
    "3. censored at the CDR cutoff, not last contact -> person-time inflated, rate pushed DOWN",
    "4. Q-S6 baseline anchor open: figures 14/15/17 are anchor-free; figure 16 is PROVISIONAL"),
    con_out)
  close(con_out)
  say("\nreadout written to %s  <- paste this back", summary_path)

  if (isTRUE(copy_to_bucket) && nzchar(Sys.getenv("WORKSPACE_BUCKET"))) {
    cmd <- sprintf("gsutil -m cp %s/*.png %s/figures/", outdir, Sys.getenv("WORKSPACE_BUCKET"))
    say("copying figures to the bucket: %s", cmd)
    try(system(cmd, intern = TRUE), silent = TRUE)
  }

  invisible(list(frame = fr, km = km, km_acute = km_acute, km_by_sex = km_sex,
                 landmark = landmark, end_of_followup = end_of_followup,
                 literature = lit, summary_path = summary_path))
}

# --- offline entry point: fixture, for layout QA only ---------------------------------------------
if (sys.nframe() == 0) {
  source_survival_deps(".")
  fx <- "fixture/db/aou_fixture.duckdb"
  if (!file.exists(fx)) stop("fixture not built: see docs/environment.md")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  # Two fixture-only settings, both of which would be WRONG in the Workbench:
  #   scorable_only = FALSE -- the fixture has only 4 complete panels, and a 4-person at-risk set
  #     carries no events, so figures 14/15/17 would never be written and the layout would go
  #     unchecked. Relaxing it here exercises the curve-writing path on ~160 people.
  #   landmark 2016-01-01 -- chosen, not derived: the fixture's conditions run 2009-2021, so this
  #     leaves ~5 years of follow-up. choose_landmark() is exercised separately below.
  eof <- derive_end_of_followup(con)$end_of_followup
  message("fixture: derived end_of_followup = ", format(eof))
  run_survival_curves(con, outdir = "reports/figures_fixture_demo",
                      landmark = as.Date("2016-01-01"), end_of_followup = eof,
                      attach_smoking_status = FALSE, scorable_only = FALSE,
                      horizons = c(1, 2, 3, 4, 5), copy_to_bucket = FALSE)
}
