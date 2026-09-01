# 03_mice.R — the abstract. ONE call: impute the missing inputs, validate PREVENT, write the draft.
#
# RUN IT:
#   setwd("~/lancaster_lab")
#   install.packages("mice")                      # once per Workbench instance
#   source("src/workbench/03_mice.R")
#   out <- run_mice_abstract()
#
# It writes, and every one of them is aggregate-only and safe to paste back:
#   reports/abstract_<date>.txt        the structured abstract, numbers already substituted
#   reports/mice_validation_<date>.txt complete-case vs MICE side by side, plus the diagnostics
#   figures/21_calibration_mice_by_sex.png
#   figures/22_smoking_imputation_check.png
#
# ------------------------------------------------------------------------------------------------
# WHAT THIS IS FOR
#
# 01_check.R asks "is the pipeline right?". 02_deliverables.R produces the poster's full artifact set.
# This file is the short path to the ABSTRACT: one landmark, one outcome, two analyses — complete-case
# and MICE — reported next to each other, because the comparison IS the methodological contribution.
# "We validated PREVENT" is a result anyone can get from 84,176 people. "We validated PREVENT and
# showed the answer does not depend on discarding the 60% who skipped the smoking question" is the
# one worth the abstract, and it needs both arms or it is an assertion.
#
# THE ARMS ARE DELIBERATELY NESTED, NOT PARALLEL:
#   complete-case : complete measurements AND a smoking answer   (the 02_deliverables cohort)
#   MICE          : complete measurements, smoking IMPUTED       (a superset — same people, plus the
#                                                                 non-answerers)
# Every person in the first is in the second, so a difference between the arms is attributable to the
# added people and to nothing else. If the two arms had different measurement requirements you could
# not say that, and the comparison would be decoration.
#
# ------------------------------------------------------------------------------------------------
# WHAT IT DOES NOT DO
#
# It does not decide whether PREVENT "works" here, and it does not write that sentence for you. The
# draft states what was measured and marks every interpretive claim with [[ ]] for you to resolve
# against the numbers. Three of those markers are not stylistic — they are the caveats that make the
# difference between a defensible abstract and a retracted one, and they are listed at the foot of the
# validation report:
#   * death is not wired in, so observed risk (and the calibration slope) is biased UPWARD;
#   * this is the EHR cohort, not the srWGS cohort (A-017);
#   * calibration is only claimable alongside the incidence check — under-ascertained outcomes and a
#     genuinely over-predicting model look identical on a calibration plot.
# Discrimination (C) is the robust half and survives all three. Lead with it.
# ------------------------------------------------------------------------------------------------

# Small-cell floor. Mirrors paper_tables.R: 20 is a FLOOR, and a smaller value found elsewhere in the
# session is raised to it rather than honoured, so this file cannot be made unsafe from a distance.
.MICE_MIN_CELL_FLOOR <- 20L
.mice_min_cell <- function() {
  v <- tryCatch(if (exists(".MIN_CELL", inherits = TRUE)) get(".MIN_CELL", inherits = TRUE)
                else .MICE_MIN_CELL_FLOOR, error = function(e) .MICE_MIN_CELL_FLOOR)
  v <- suppressWarnings(as.integer(v))
  if (!length(v) || is.na(v)) v <- .MICE_MIN_CELL_FLOOR
  max(v, .MICE_MIN_CELL_FLOOR)
}

.mice_n <- function(n, min_cell = .mice_min_cell())
  if (is.na(n)) "-" else if (n > 0 && n < min_cell) sprintf("<%d", min_cell) else
    format(n, big.mark = ",")

#' Format an estimate with its interval, or suppress it when the stratum is too small to report.
.mice_ci <- function(row, col, fmt = "%.3f", events = NULL, min_cell = .mice_min_cell()) {
  if (is.null(row) || !nrow(row)) return("-")
  ev <- if (is.null(events)) row$events[1] else events
  if (!is.na(ev) && ev < min_cell) return(sprintf("suppressed (<%d events)", min_cell))
  sprintf(paste0(fmt, " (", fmt, "-", fmt, ")"), row[[col]][1], row$lower[1], row$upper[1])
}

.mice_row <- function(tbl, stratum) {
  if (is.null(tbl) || !nrow(tbl)) return(NULL)
  r <- tbl[as.character(tbl$stratum) == stratum, , drop = FALSE]
  if (!nrow(r)) NULL else r
}

#' Score one completed dataset with the published PREVENT equation.
#'
#' Strips any pre-existing prevent_base_* columns first. run_prevent() cbind()s its output, so scoring
#' a frame that was already scored upstream (build_incidence_frame does it once) produces DUPLICATE
#' column names — and `d$prevent_base_10yr_ASCVD` then returns the FIRST one, which is the stale
#' all-NA version from before imputation. Silent, and it would zero out the entire MICE arm.
.mice_score <- function(d) {
  d <- d[, !grepl("^prevent_base_", names(d)), drop = FALSE]
  run_prevent(d)
}

#' One call: complete-case vs MICE validation of PREVENT, and the abstract draft.
#'
#' @param con  open DBI connection, or NULL to open (and close) one.
#' @param m  imputed datasets. 5 is conventional; the report prints the fraction of missing
#'   information so you can tell whether it needed to be larger.
#' @param impute_vars  which PREVENT inputs to impute. DEFAULT "smoking" — the survey-derived input
#'   that is the binding constraint on N. Widening this is a SENSITIVITY analysis: imputing a
#'   measurement someone never had invents an average person rather than recovering a real one, so if
#'   you change it, say so in the methods and report both.
#' @param outcome  "acute" (hard ASCVD — the paper's outcome, and the default) or "broad" (D-016).
#' @param horizon_years  NULL derives it from the 75th percentile of follow-up and uses the SAME
#'   horizon for both arms, which is what makes them comparable.
#' @param landmark,end_of_followup  NULL derives them exactly as the main run does. Supply them to
#'   pin this analysis to a run you already have, so the two agree about who was studied.
#' @param seed  passed to mice. Quote it in the methods section.
#' @return invisibly, list(complete_case, mice, imputation, horizon_years, landmark, paths, frame).
run_mice_abstract <- function(con = NULL, m = 5, impute_vars = "smoking",
                              outcome = c("acute", "broad"), horizon_years = NULL,
                              landmark = NULL, end_of_followup = NULL,
                              figdir = "figures", repdir = "reports",
                              seed = 20260901L, copy_to_bucket = TRUE) {
  outcome <- match.arg(outcome)
  if (!file.exists("src/figures/survival_curves.R"))
    stop("run_mice_abstract(): working directory is not the repo root.
  In the Workbench:  setwd(\"~/lancaster_lab\")
  Current wd: ", getwd(), call. = FALSE)
  if (!requireNamespace("mice", quietly = TRUE))
    stop("run_mice_abstract(): `mice` is not installed. In the Workbench:  install.packages(\"mice\")",
         call. = FALSE)

  source("src/figures/survival_curves.R")
  source_survival_deps(quiet = TRUE)
  source("src/figures/prevent_calibration.R")
  source("src/phenotype/R/impute_panel.R")
  source("src/ascvd/validation/paper_tables.R")
  source("src/ascvd/validation/pooled_validation.R")
  source("src/ascvd/validation/export_validation_summary.R")

  if (is.null(con)) {
    con <- connect_cdr()
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  }
  for (d in c(figdir, repdir)) if (!dir.exists(d)) dir.create(d, recursive = TRUE)
  say <- function(...) message(sprintf(...))

  # -- 1. the cohort ------------------------------------------------------------------------------
  # scorable_only = FALSE, on purpose and it is the whole trick: we need the people who are NOT
  # currently scorable, because they are the ones imputation is for. The two arms are carved out of
  # this one frame below, so they share a landmark, a follow-up window and an event definition.
  say("\n=== 1/6 cohort (both arms come from this one build) ===")
  if (is.null(end_of_followup)) end_of_followup <- derive_end_of_followup(con)$end_of_followup
  if (is.null(landmark))
    landmark <- choose_landmark(con, end_of_followup, attach_smoking_status = TRUE)$landmark
  say("  landmark %s -> %s (%.2f years)", format(landmark), format(end_of_followup),
      as.numeric(end_of_followup - landmark) / 365.25)

  fr <- build_incidence_frame(con, landmark, end_of_followup,
                              scorable_only = FALSE, attach_smoking_status = TRUE,
                              min_days_panel_to_event = 30)
  at_risk <- if (outcome == "acute") fr$at_risk_acute else fr$at_risk
  if (!is.null(fr$prevent_source)) say("  PREVENT: %s", fr$prevent_source)
  if (grepl("^NOT SCORED", fr$prevent_source %||% ""))
    stop("run_mice_abstract(): the panel was NOT SCORED, so neither arm has a risk to validate.
  The reason is printed above and it is almost always the AHAprevent package. Fix that first —
  everything this script produces is downstream of a PREVENT risk column.", call. = FALSE)

  mice_abstract_from_frame(at_risk, landmark, end_of_followup, m = m,
                           impute_vars = impute_vars, outcome = outcome,
                           horizon_years = horizon_years, figdir = figdir, repdir = repdir,
                           seed = seed, copy_to_bucket = copy_to_bucket, frame = fr)
}

#' The analysis half, given an at-risk frame. Split out from run_mice_abstract() so that every line
#' below can be exercised WITHOUT a database — see run_mice_abstract_synthetic(). The alternative is
#' a script whose first real run in the Workbench is also the first time it has ever executed.
#'
#' @param at_risk  a scored at-risk frame: PREVENT inputs, a prevent_base_* risk column, `event`,
#'   `followup_days`, `complete_panel` and `complete_panel_smoking`.
#' @inheritParams run_mice_abstract
mice_abstract_from_frame <- function(at_risk, landmark, end_of_followup, m = 5,
                                     impute_vars = "smoking", outcome = "acute",
                                     horizon_years = NULL, figdir = "figures", repdir = "reports",
                                     seed = 20260901L, copy_to_bucket = TRUE, frame = NULL) {
  say <- function(...) message(sprintf(...))
  for (d in c(figdir, repdir)) if (!dir.exists(d)) dir.create(d, recursive = TRUE)
  risk_col <- .find_risk_col(at_risk)

  # -- 2. the two arms ----------------------------------------------------------------------------
  cc_set   <- at_risk[which(at_risk$complete_panel_smoking), , drop = FALSE]  # the 02_deliverables cohort
  mice_set <- at_risk[which(at_risk$complete_panel), , drop = FALSE]          # + the non-answerers
  say("\n=== 2/6 arms ===")
  say("  complete-case : %s at risk", format(nrow(cc_set), big.mark = ","))
  say("  MICE-eligible : %s at risk (%s with no smoking answer)",
      format(nrow(mice_set), big.mark = ","),
      format(sum(is.na(mice_set$smoking)), big.mark = ","))

  # One horizon for both arms. Derived from the MICE set because it is the superset; evaluating the
  # two arms at different horizons would make the C-statistics incomparable for a reason invisible in
  # the output table.
  if (is.null(horizon_years)) {
    fu <- mice_set$followup_days[!is.na(mice_set$event)]
    horizon_years <- max(1, floor(stats::quantile(fu, 0.75, na.rm = TRUE) / 365.25))
    say("  horizon       : %d year(s) (75th pct of follow-up = %.1f y)",
        horizon_years, stats::quantile(fu, 0.75, na.rm = TRUE) / 365.25)
  }

  # -- 3. complete-case arm -----------------------------------------------------------------------
  say("\n=== 3/6 complete-case validation ===")
  cc_c     <- prevent_concordance(cc_set, by_sex = TRUE)
  cc_cal   <- calibration_table(cc_set, horizon_years, n_groups = 10, by_sex = TRUE)
  cc_slope <- calibration_slope(cc_cal)
  if (is.null(cc_c)) say("  no C-statistic (fewer than 10 events) — the MICE arm may still have one.")

  # -- 4. impute ----------------------------------------------------------------------------------
  say("\n=== 4/6 MICE (m = %d, imputing: %s) ===", m, paste(impute_vars, collapse = ", "))
  imp <- impute_prevent_panel(mice_set, vars = impute_vars, m = m, seed = seed, quiet = TRUE)
  say("  kept %s of %s rows; %s",
      format(imp$n_kept, big.mark = ","), format(imp$n_in, big.mark = ","),
      paste(sprintf("%s missing in %s", format(imp$missing_before, big.mark = ","),
                    names(imp$missing_before)), collapse = "; "))
  say("  method: %s | outcome in the imputation model: %s",
      paste(sprintf("%s=%s", names(imp$method), imp$method), collapse = " "),
      if (!imp$used_outcome) "NO — C will be biased DOWN"
      else if (length(imp$outcome_dropped))
        sprintf("DROPPED by mice (%s) — C biased DOWN", paste(imp$outcome_dropped, collapse = ", "))
      else "YES (event + Nelson-Aalen, both retained)")

  # -- 5. score and pool --------------------------------------------------------------------------
  say("\n=== 5/6 scoring %d imputed datasets and pooling (Rubin's rules) ===", m)
  scored  <- suppressMessages(lapply(imp$completed, .mice_score))
  mi_c    <- pool_concordance(lapply(scored, function(d) prevent_concordance(d, by_sex = TRUE)))
  mi_cals <- lapply(scored, function(d) calibration_table(d, horizon_years, n_groups = 10,
                                                          by_sex = TRUE))
  mi_slope <- pool_calibration_slope(lapply(mi_cals, calibration_slope))
  # The figure is drawn on the across-imputation MEAN risk; the quoted slope is the pooled one. Both
  # are produced, and the report says which is which — see average_predicted_risk()'s header.
  mean_frame <- average_predicted_risk(scored, risk_col)
  mi_cal_fig <- if (!is.null(mean_frame))
    calibration_table(mean_frame, horizon_years, n_groups = 10, by_sex = TRUE) else NULL

  # -- 6. figures ---------------------------------------------------------------------------------
  say("\n=== 6/6 figures and report ===")
  .mice_figures(mi_cal_fig, imp, scored, mice_set, horizon_years, outcome, figdir, m)

  # -- report -------------------------------------------------------------------------------------
  paths <- .mice_write(cc_set, mice_set, cc_c, cc_slope, mi_c, mi_slope, imp,
                       landmark, end_of_followup, horizon_years, outcome, m, impute_vars,
                       seed, repdir, risk_col)

  if (isTRUE(copy_to_bucket)) .mice_bucket(figdir, repdir, say)

  cat(paste(readLines(paths$abstract), collapse = "\n"), "\n")
  say("\nwritten:\n  %s\n  %s", paths$abstract, paths$report)
  say("Paste either file back — both are aggregate-only and suppressed at %d.", .mice_min_cell())

  invisible(list(complete_case = list(concordance = cc_c, calibration = cc_cal, slope = cc_slope),
                 mice = list(concordance = mi_c, slope = mi_slope, calibration_mean = mi_cal_fig,
                             scored = scored),
                 imputation = imp, horizon_years = horizon_years, landmark = landmark,
                 outcome = outcome, paths = paths, frame = frame))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- figures -------------------------------------------------------------------------------------

.mice_figures <- function(cal_fig, imp, scored, mice_set, horizon_years, outcome, figdir, m) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("  ggplot2 absent — skipping figures (the numbers are unaffected).")
    return(invisible(NULL))
  }
  suppressPackageStartupMessages(library(ggplot2))

  # 21. the calibration plot, MICE arm.
  if (!is.null(cal_fig) && nrow(cal_fig)) {
    lim <- c(0, max(c(cal_fig$predicted_horizon, cal_fig$upper_pct), na.rm = TRUE) * 1.08)
    p <- ggplot(cal_fig, aes(predicted_horizon, observed_pct)) +
      geom_abline(slope = 1, intercept = 0, colour = "grey55", linetype = "22") +
      geom_errorbar(aes(ymin = lower_pct, ymax = upper_pct), width = 0, colour = "grey60") +
      geom_point(size = 2.8, colour = "#4C72B0") +
      facet_wrap(~ stratum) + coord_equal(xlim = lim, ylim = lim) +
      scale_x_continuous(labels = function(x) paste0(x, "%")) +
      scale_y_continuous(labels = function(x) paste0(x, "%")) +
      labs(title = "PREVENT calibration after multiple imputation",
           subtitle = sprintf("%s ASCVD - deciles within sex - m = %d imputations - N = %s",
                              outcome, m, format(nrow(mice_set), big.mark = ",")),
           x = sprintf("Predicted %d-year risk (PREVENT)", horizon_years),
           y = sprintf("Observed %d-year risk (Kaplan-Meier)", horizon_years),
           caption = paste0("Points BELOW the line = over-prediction. Plotted on the across-",
                            "imputation MEAN predicted risk;\nthe quoted calibration slope and its ",
                            "interval come from Rubin's rules, not from this figure.\nDeath is not ",
                            "wired in, so observed risk here is biased UPWARD.")) +
      theme_minimal(base_size = 13) +
      theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
            plot.caption = element_text(colour = "grey45", size = 8.5, hjust = 0))
    ggsave(file.path(figdir, "21_calibration_mice_by_sex.png"), p,
           width = 10, height = 6, dpi = 150, bg = "white")
  }

  # 22. the diagnostic a reviewer asks for: do the imputed values look like the observed ones?
  # A large gap is not automatically wrong — the whole point is that non-answerers differ — but an
  # implausible one (imputed smoking at 3% or at 90%) means the model, not the data.
  v <- imp$vars[1]
  was_na <- imp$missing_mask[[v]]   # aligned to the KEPT rows, i.e. to every imp$completed[[i]]
  if (!is.null(was_na) && any(was_na)) {
    rows <- do.call(rbind, lapply(seq_along(imp$completed), function(i) {
      d <- imp$completed[[i]]
      data.frame(imputation = i,
                 group = c("observed", "imputed"),
                 pct = c(100 * mean(d[[v]][!was_na], na.rm = TRUE),
                         100 * mean(d[[v]][was_na],  na.rm = TRUE)),
                 stringsAsFactors = FALSE)
    }))
    rows <- rows[is.finite(rows$pct), , drop = FALSE]
    if (nrow(rows)) {
      p2 <- ggplot(rows, aes(factor(imputation), pct, fill = group)) +
        geom_col(position = position_dodge(width = 0.75), width = 0.65) +
        scale_fill_manual(values = c(observed = "#4C72B0", imputed = "#DD8452"), name = NULL) +
        scale_y_continuous(labels = function(x) paste0(x, "%")) +
        labs(title = sprintf("Imputation check: %s", v),
             subtitle = "prevalence among people who answered vs. people whose value was imputed",
             x = "imputation", y = sprintf("%s = TRUE", v),
             caption = paste0("The two bars SHOULD differ — non-answerers are not a random sample, ",
                              "which is why complete-case\nanalysis is biased. What would be wrong ",
                              "is an implausible imputed value, or wild variation across m.")) +
        theme_minimal(base_size = 13) +
        theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
              plot.caption = element_text(colour = "grey45", size = 8.5, hjust = 0))
      ggsave(file.path(figdir, "22_smoking_imputation_check.png"), p2,
             width = 7.5, height = 5, dpi = 150, bg = "white")
    }
  }
  invisible(NULL)
}

.mice_bucket <- function(figdir, repdir, say) {
  bucket <- Sys.getenv("WORKSPACE_BUCKET")
  if (!nzchar(bucket) || !grepl("^gs://[a-z0-9][a-z0-9._-]{2,}$", bucket)) {
    say("\nNot copying to a bucket (WORKSPACE_BUCKET is %s). Files are on disk:\n  %s\n  %s",
        if (!nzchar(bucket)) "unset" else "not a valid bucket name",
        normalizePath(figdir, winslash = "/", mustWork = FALSE),
        normalizePath(repdir, winslash = "/", mustWork = FALSE))
    return(invisible(NULL))
  }
  for (cmd in c(sprintf("gsutil -m cp %s/*.png %s/figures/", figdir, bucket),
                sprintf("gsutil -m cp %s/*.txt %s/reports/", repdir, bucket)))
    try(system(cmd), silent = TRUE)
  say("\ncopied to %s (a failed copy is not a failed run — the files are still on disk)", bucket)
}

# ---- the sentences the draft can write for itself ---------------------------------------------------

#' Turn the two arms and the published benchmark into FACTUAL sentences.
#'
#' These used to be [[ ]] markers for a human to resolve, and three of them were mechanical: do the
#' two arms' intervals overlap, does ours land inside the published range, does the slope interval
#' contain 1. A person re-deriving those by eye at 11pm before a deadline gets one of them backwards.
#'
#' What is generated is strictly descriptive — overlap, direction, containment. The JUDGEMENT
#' (is this good enough to claim PREVENT transports to All of Us?) stays a [[ ]] marker, because it
#' depends on the incidence check and the death caveat, neither of which this function can see.
#'
#' @return list(arms, benchmark, calibration) — each a character vector of complete sentences, or a
#'   [[ ]] marker when the inputs were too thin to say anything.
.mice_verdict <- function(cc_c, mi_c, mi_slope, mc = .mice_min_cell()) {
  sexes  <- c("female", "male")
  usable <- function(r) !is.null(r) && nrow(r) && (is.na(r$events[1]) || r$events[1] >= mc)
  # The stratum labels are the panel's coding; an abstract says "women" and "men". Translating at the
  # point of writing keeps the data coding honest and the prose readable.
  who    <- function(s) c(female = "women", male = "men")[[s]]

  # -- 1. did imputation change the answer? -------------------------------------------------------
  cmp <- lapply(sexes, function(s) {
    a <- .mice_row(cc_c, s); b <- .mice_row(mi_c, s)
    if (!usable(a) || !usable(b)) return(NULL)
    list(sex = s, cc = a$c_index[1], mi = b$c_index[1],
         # Overlapping 95% intervals is a weak criterion, and that is the right strength here: the
         # claim being made is "imputation did not overturn the result", not "the two are equal".
         overlap = a$lower[1] <= b$upper[1] && b$lower[1] <= a$upper[1])
  })
  cmp <- Filter(Negate(is.null), cmp)

  arms <- if (!length(cmp)) {
    "  [[Too few events to compare the arms — say so rather than implying agreement.]]"
  } else if (all(vapply(cmp, function(x) x$overlap, logical(1)))) {
    c(sprintf(paste("  Complete-case and imputed C-statistics had overlapping 95%% confidence",
                    "intervals in %s,"),
              if (length(cmp) > 1) "both sexes" else sprintf("%s participants", cmp[[1]]$sex)),
      "  so the discrimination result does not depend on excluding participants who did not answer",
      "  the smoking question.")
  } else {
    d <- Filter(function(x) !x$overlap, cmp)
    c(sprintf("  Complete-case and imputed C-statistics differed in %s (%s).",
              paste(vapply(d, function(x) who(x$sex), character(1)), collapse = " and "),
              paste(vapply(d, function(x) sprintf("%s: %.2f -> %.2f", who(x$sex), x$cc, x$mi),
                           character(1)), collapse = "; ")),
      "  [[This is the interesting case: complete-case analysis was giving a different answer.",
      "    Say which direction and why the responders differ from the non-responders.]]")
  }

  # -- 2. how do we sit against the published validation? -----------------------------------------
  ref <- tryCatch(paper_table4_reference("ascvd"), error = function(e) NULL)
  bench <- if (is.null(ref) || is.null(mi_c)) {
    "  [[Compare the pooled C to Khan et al.'s published range by sex.]]"
  } else {
    parts <- Filter(Negate(is.null), lapply(sexes, function(s) {
      b <- .mice_row(mi_c, s); r <- ref[ref$sex == s, , drop = FALSE]
      if (!usable(b) || !nrow(r)) return(NULL)
      where <- if (b$c_index[1] < r$c_iqi_lo[1]) "below"
               else if (b$c_index[1] > r$c_iqi_hi[1]) "above" else "within"
      sprintf("%s in %s (%.2f vs %.2f-%.2f)", where, who(s), b$c_index[1],
              r$c_iqi_lo[1], r$c_iqi_hi[1])
    }))
    if (!length(parts)) "  [[Compare the pooled C to the published range.]]" else
      c("  Against the published PREVENT validation (inter-quartile range across 21 cohorts), our",
        sprintf("  pooled C-statistic was %s.", paste(unlist(parts), collapse = ", and ")))
  }

  # -- 3. calibration slope against the identity --------------------------------------------------
  calib <- if (is.null(mi_slope)) {
    "  [[No pooled calibration slope was produced — do not imply calibration was assessed.]]"
  } else {
    parts <- Filter(Negate(is.null), lapply(sexes, function(s) {
      r <- .mice_row(mi_slope, s)
      if (!usable(r)) return(NULL)
      sprintf("  in %s, %.2f (95%% CI %.2f-%.2f), %s;", who(s), r$slope[1], r$lower[1], r$upper[1],
              if (r$lower[1] <= 1 && r$upper[1] >= 1) "consistent with the identity"
              else if (r$upper[1] < 1) "below 1, i.e. PREVENT over-predicted"
              else "above 1, i.e. PREVENT under-predicted")
    }))
    parts <- unlist(parts)
    parts[length(parts)] <- sub(";$", ".", parts[length(parts)])   # last clause ends the sentence
    if (!length(parts)) "  [[No reportable calibration slope.]]" else
      # One line per sex: these sentences carry two numbers and a clause each, and a single joined
      # line ran past 160 characters, which a submission form silently reflows into nonsense.
      c("  The pooled calibration slope was:", parts,
        "  Note the direction of the known bias before interpreting this: deaths are not ascertained,",
        "  so observed risk is over-stated and the slope is biased UPWARD.")
  }

  list(arms = arms, benchmark = bench, calibration = calib)
}

# ---- the two written artifacts ---------------------------------------------------------------------

.mice_write <- function(cc_set, mice_set, cc_c, cc_slope, mi_c, mi_slope, imp,
                        landmark, end_of_followup, horizon_years, outcome, m, impute_vars,
                        seed, repdir, risk_col) {
  mc     <- .mice_min_cell()
  sexes  <- c("female", "male")
  ev_cc  <- sum(cc_set$event == 1L, na.rm = TRUE)
  ev_mi  <- sum(mice_set$event == 1L, na.rm = TRUE)
  n_add  <- nrow(mice_set) - nrow(cc_set)
  pct_add <- if (nrow(cc_set) > 0) 100 * n_add / nrow(cc_set) else NA_real_
  yrs    <- as.numeric(end_of_followup - landmark) / 365.25

  fmi <- if (!is.null(mi_c)) sprintf("%.2f", max(mi_c$fmi, na.rm = TRUE)) else "-"

  # ---- the comparison report --------------------------------------------------------------------
  hdr <- function(t) c("", strrep("=", 96), t, strrep("=", 96))
  rowf <- function(lab, a, b) sprintf("  %-34s %-28s %-28s", lab, a, b)

  rep_lines <- c(
    sprintf("MICE VALIDATION OF PREVENT — %s", Sys.Date()),
    sprintf("CDR        : %s", Sys.getenv("WORKSPACE_CDR", "<unset — offline fixture run>")),
    sprintf("landmark   : %s -> %s (%.2f years of follow-up)",
            format(landmark), format(end_of_followup), yrs),
    sprintf("outcome    : %s ASCVD | horizon %d year(s) | risk column %s",
            outcome, horizon_years, risk_col),
    sprintf("imputation : mice, m = %d, seed = %d, imputing %s (%s)",
            m, seed, paste(impute_vars, collapse = ", "),
            paste(sprintf("%s=%s", names(imp$method), imp$method), collapse = " ")),
    sprintf("             outcome in the imputation model: %s",
            if (!imp$used_outcome)
              "NO — C-statistics below are biased DOWNWARD; re-run with use_outcome = TRUE"
            else if (length(imp$outcome_dropped))
              sprintf("REQUESTED but mice DROPPED %s — C is biased DOWNWARD, do not report it",
                      paste(imp$outcome_dropped, collapse = " and "))
            else "YES — event indicator + Nelson-Aalen cumulative hazard, both retained"),
    sprintf("suppression: counts and estimates below %d are printed as '<%d' or suppressed", mc, mc),

    hdr("1. WHAT IMPUTATION BOUGHT"),
    rowf("", "COMPLETE CASE", "MICE"),
    rowf("at-risk N", .mice_n(nrow(cc_set)), .mice_n(nrow(mice_set))),
    rowf("incident events", .mice_n(ev_cc), .mice_n(ev_mi)),
    rowf("smoking", "observed for all",
         sprintf("%s imputed", .mice_n(unname(imp$missing_before[[1]])))),
    "",
    sprintf("  MICE adds %s people (+%.0f%%) and %s events. Those people are in the cohort because",
            .mice_n(n_add), pct_add, .mice_n(ev_mi - ev_cc)),
    "  their measurements were complete and only the SURVEY answer was missing — nobody was added by",
    "  inventing a lab value.",

    hdr("2. DISCRIMINATION — Harrell's C (the headline; robust to the caveats in section 5)"),
    rowf("", "COMPLETE CASE", "MICE (pooled)"),
    unlist(lapply(sexes, function(s) {
      a <- .mice_row(cc_c, s); b <- .mice_row(mi_c, s)
      rowf(sprintf("C, %s", s),
           .mice_ci(a, "c_index", events = if (is.null(a)) NA else a$events[1]),
           .mice_ci(b, "c_index", events = if (is.null(b)) NA else b$events[1]))
    })),
    "",
    sprintf("  Pooled intervals use Rubin's rules on the logit scale. Max fraction of missing"),
    sprintf("  information (FMI) across strata: %s. FMI well above the fraction of missing VALUES", fmi),
    "  means the imputation model is carrying more weight than the data — report it, and consider a",
    "  larger m before a stronger claim.",

    hdr("3. CALIBRATION — slope of observed on predicted, by decile"),
    rowf("", "COMPLETE CASE", "MICE (pooled)"),
    unlist(lapply(sexes, function(s) {
      a <- .mice_row(cc_slope, s); b <- .mice_row(mi_slope, s)
      rowf(sprintf("slope, %s", s), .mice_ci(a, "slope", fmt = "%.2f"),
           .mice_ci(b, "slope", fmt = "%.2f"))
    })),
    "",
    "  1.00 is perfect. Read this ONLY alongside the incidence check in the 01_check output: an",
    "  under-ascertained outcome and a genuinely over-predicting equation produce the same picture.",

    hdr("4. IMPUTATION DIAGNOSTICS"),
    sprintf("  rows offered to mice        : %s", .mice_n(imp$n_in)),
    sprintf("  rows kept                   : %s", .mice_n(imp$n_kept)),
    sprintf("  rows dropped                : %s (%s)", .mice_n(imp$n_dropped), imp$dropped_reason),
    sprintf("  values imputed              : %s",
            paste(sprintf("%s: %s", names(imp$missing_before),
                          vapply(imp$missing_before, .mice_n, character(1))), collapse = "; ")),
    "  see figures/22_smoking_imputation_check.png — observed vs imputed prevalence, per imputation.",
    "  The two SHOULD differ (that is the bias complete-case analysis has); what would be wrong is an",
    "  implausible imputed value or wild variation across m.",

    hdr("5. CAVEATS THAT BELONG IN THE ABSTRACT, NOT JUST THE PAPER"),
    "  1. DEATH IS NOT WIRED IN. Competing risk is treated as censoring, so observed risk — and the",
    "     calibration slope — is biased UPWARD. This is the largest methodological gap.",
    "  2. THIS IS THE EHR COHORT, not the srWGS cohort (A-017). Say 'participants with EHR data'.",
    "  3. ICD-10-CM only: events before ~Oct 2015 are invisible, so early years are left-truncated.",
    "  4. Censoring is at the CDR cutoff, not last contact — person-time is inflated, rates pushed DOWN.",
    "  5. MICE assumes missing AT RANDOM given the model. If people conceal smoking for reasons",
    "     unrelated to anything measured here, that is MNAR and no imputation fixes it.",
    "  6. The smoking answer MAP is still provisional (extract_smoking.R); dm's medication list is",
    "     provisional (sql/05). Both feed the risk score.",
    "")

  rep_path <- file.path(repdir, sprintf("mice_validation_%s.txt", Sys.Date()))
  writeLines(rep_lines, rep_path)

  # ---- the abstract draft -----------------------------------------------------------------------
  verdict <- .mice_verdict(cc_c, mi_c, mi_slope, mc)
  cfmt <- function(tbl, s) {
    r <- .mice_row(tbl, s)
    if (is.null(r) || (!is.na(r$events[1]) && r$events[1] < mc)) return("[[suppressed]]")
    sprintf("%.2f (95%% CI %.2f-%.2f)", r$c_index[1], r$lower[1], r$upper[1])
  }
  sfmt <- function(tbl, s) {
    r <- .mice_row(tbl, s)
    if (is.null(r) || (!is.na(r$events[1]) && r$events[1] < mc)) return("[[suppressed]]")
    sprintf("%.2f (95%% CI %.2f-%.2f)", r$slope[1], r$lower[1], r$upper[1])
  }

  abs_lines <- c(
    sprintf("DRAFT ABSTRACT — generated %s from the run above. Every [[ ]] is a judgement", Sys.Date()),
    "you have to make against the numbers; nothing else in here is unsubstituted.",
    strrep("-", 96), "",
    "TITLE",
    "  External validation of the AHA PREVENT equations in All of Us, with multiple imputation for",
    "  missing risk-factor data",
    "",
    "BACKGROUND",
    "  The AHA PREVENT equations estimate 10-year cardiovascular risk without race. External",
    "  validation in diverse, real-world cohorts is limited. In electronic health record cohorts the",
    "  binding constraint is rarely the laboratory panel but the survey-derived inputs: in All of Us,",
    sprintf("  smoking status was available for only %.0f%% of participants with an otherwise complete",
            if (nrow(mice_set) > 0) 100 * nrow(cc_set) / nrow(mice_set) else NA_real_),
    "  PREVENT panel. Complete-case analysis discards these participants, who differ systematically",
    "  from responders.",
    "",
    "METHODS",
    sprintf("  We identified All of Us participants (Controlled Tier) aged 30-79 with electronic health"),
    sprintf("  record data and a complete PREVENT input panel as of a %s landmark, followed to %s",
            format(landmark), format(end_of_followup)),
    sprintf("  (%.1f years). Incident %s ASCVD was ascertained from ICD-10-CM and CPT codes; the",
            yrs, outcome),
    "  baseline panel was required to predate any event by at least 30 days. The published PREVENT",
    "  base equations were applied UNCHANGED — no coefficients were refitted. Missing smoking status",
    sprintf("  was handled by multiple imputation by chained equations (m = %d), with the imputation", m),
    "  model containing all PREVENT inputs plus the event indicator and the Nelson-Aalen cumulative",
    "  hazard. Discrimination (Harrell's C) and the calibration slope of observed on predicted risk by",
    sprintf("  decile were computed at %d year(s), separately by sex, and pooled across imputations",
            horizon_years),
    "  using Rubin's rules. Observed risk was estimated by Kaplan-Meier.",
    "",
    "RESULTS",
    sprintf("  Complete-case analysis included %s participants (%s incident events). Multiple",
            .mice_n(nrow(cc_set)), .mice_n(ev_cc)),
    sprintf("  imputation increased the analytic sample to %s participants (%s events), a %.0f%%",
            .mice_n(nrow(mice_set)), .mice_n(ev_mi), pct_add),
    "  increase.",
    sprintf("  Discrimination, complete case: C = %s in women and %s in men.",
            cfmt(cc_c, "female"), cfmt(cc_c, "male")),
    sprintf("  Discrimination, pooled across imputations: C = %s in women and %s in men.",
            cfmt(mi_c, "female"), cfmt(mi_c, "male")),
    sprintf("  Calibration slope, pooled: %s in women and %s in men.",
            sfmt(mi_slope, "female"), sfmt(mi_slope, "male")),
    verdict$arms,
    verdict$benchmark,
    verdict$calibration,
    "",
    "CONCLUSIONS",
    "  The published AHA PREVENT equations, applied unchanged, discriminated incident ASCVD in a",
    "  diverse real-world EHR cohort, and multiple imputation of survey-derived risk factors",
    sprintf("  increased the analytic sample by %.0f%% without refitting the model.", pct_add),
    "  [[ONE SENTENCE OF INTERPRETATION — and it is the only thing left to write. Discrimination is",
    "    the defensible half (it uses only the ORDER of predicted risk). A calibration claim needs",
    "    the incidence check from 01_check.R alongside it, because an under-ascertained outcome and",
    "    a genuinely over-predicting equation are indistinguishable on a calibration plot.]]",
    "",
    "LIMITATIONS (do not drop these to make the word count)",
    "  Deaths were not ascertained, so competing risk was treated as censoring and observed risk is",
    "  biased upward. Follow-up was shorter than the equations' 10-year horizon; predicted risk was",
    "  rescaled under a constant-hazard assumption. Results describe participants with EHR data, not",
    "  the genomic cohort. Events before ~October 2015 are not captured. Smoking imputation assumes",
    "  missingness at random given the model.",
    "",
    strrep("-", 96),
    sprintf("word count of the abstract body (BACKGROUND..CONCLUSIONS, excluding [[ ]]): ~%d", 0L),
    "Numbers above are aggregate and suppressed at 20. Full comparison: mice_validation_*.txt")

  # Count words on the substituted text only, so the number is about the abstract and not about the
  # instructions to yourself. Cheap, and word count is the first thing a submission portal rejects on.
  # Both ends are located by grep rather than by offset: a line added to the template later would
  # otherwise silently shift the range, and the count would still look plausible.
  from <- which(abs_lines == "BACKGROUND")[1]
  to   <- which(abs_lines == "LIMITATIONS (do not drop these to make the word count)")[1] - 1L
  body <- abs_lines[seq.int(from, to)]
  body <- body[!grepl("\\[\\[", body)]
  wc   <- sum(lengths(strsplit(trimws(body), "\\s+")))
  abs_lines[grep("^word count of the abstract body", abs_lines)] <-
    sprintf("word count of the abstract body (BACKGROUND..CONCLUSIONS, excluding [[ ]]): ~%d", wc)

  abs_path <- file.path(repdir, sprintf("abstract_%s.txt", Sys.Date()))
  writeLines(abs_lines, abs_path)

  list(abstract = abs_path, report = rep_path)
}

# ---- offline smoke test ---------------------------------------------------------------------------

#' End-to-end run on SYNTHETIC data. NOT a scientific result — the numbers mean nothing.
#'
#' The fixture cannot exercise this path: its survey smoking coverage is near zero, so
#' impute_prevent_panel() correctly refuses (nothing observed to build a model from) and the whole
#' script goes unrun. So the smoke test generates its own cohort instead, with three properties that
#' the real data has and that the code has to survive:
#'   * smoking genuinely predicts the event, so a C-statistic exists to be biased;
#'   * smoking is missing at random GIVEN age and diabetes, i.e. non-answerers are not a random
#'     sample — the situation complete-case analysis gets wrong;
#'   * both sexes are present, so the by-sex stratification and the suppression rules are exercised.
#'
#' What this proves is not that the analysis is correct — synthetic data cannot show that — but that
#' every line runs, both arms produce numbers, the pooling is finite, and the report and the abstract
#' are written. That is the failure mode worth catching before a Workbench session.
#'
#' @return the same structure as run_mice_abstract().
run_mice_abstract_synthetic <- function(n = 5000, m = 5, outdir = "reports/mice_synthetic_demo",
                                        seed = 20260901L) {
  source("src/figures/prevent_calibration.R")
  source("src/ascvd/prevent/run_prevent.R")
  source("src/phenotype/R/impute_panel.R")
  source("src/ascvd/validation/paper_tables.R")
  source("src/ascvd/validation/pooled_validation.R")
  message("SYNTHETIC SMOKE TEST — every number below is made up and means nothing.")

  set.seed(seed)
  sex <- rep(c("female", "male"), length.out = n)
  age <- round(runif(n, 40, 78))
  d <- data.frame(
    person_id = seq_len(n), age = age, sex = sex,
    sbp     = round(rnorm(n, 128, 17)),
    total_c = round(rnorm(n, 192, 40)),
    hdl_c   = round(rnorm(n, 53, 15)),
    bmi     = round(rnorm(n, 29, 6), 1),
    egfr    = round(pmax(20, rnorm(n, 92 - 0.4 * (age - 40), 18)), 1),
    dm      = runif(n) < 0.14,
    statin  = runif(n) < 0.28,
    bp_tx   = runif(n) < 0.34,
    stringsAsFactors = FALSE)
  # Truth: smoking is commoner in the young, and it raises the hazard. Both matter — a smoking
  # variable that predicted nothing would let an imputation bug pass unnoticed.
  p_smk     <- plogis(1.2 - 0.045 * (d$age - 40))
  d$smoking <- runif(n) < p_smk

  lp     <- 0.055 * (d$age - 55) + 0.011 * (d$sbp - 128) + 0.85 * d$smoking +
            0.60 * d$dm + 0.30 * (d$sex == "male")
  t_evt  <- rexp(n, rate = 0.006 * exp(lp - mean(lp)))       # years to event
  t_cens <- runif(n, 1.5, 5.0)                               # administrative censoring
  d$event          <- as.integer(t_evt <= t_cens)
  d$followup_days  <- round(pmin(t_evt, t_cens) * 365.25)

  # MAR missingness: older people and people with diabetes are LESS likely to have answered the
  # survey. Depends on observed variables only, which is what MICE assumes and what makes the
  # complete-case arm biased in a way the comparison should reveal.
  p_ans <- plogis(2.4 - 0.055 * (d$age - 40) - 0.55 * d$dm)
  d$smoking[runif(n) > p_ans] <- NA

  d$complete_panel         <- TRUE                # every measurement present, by construction
  d$has_smoking_answer     <- !is.na(d$smoking)
  d$complete_panel_smoking <- d$has_smoking_answer
  d <- run_prevent(d)

  message(sprintf("  synthetic cohort: n = %d, events = %d, smoking answered by %d (%.0f%%)",
                  n, sum(d$event), sum(d$has_smoking_answer),
                  100 * mean(d$has_smoking_answer)))

  mice_abstract_from_frame(d, landmark = as.Date("2019-01-01"),
                           end_of_followup = as.Date("2024-01-01"),
                           m = m, horizon_years = 3, figdir = file.path(outdir, "figures"),
                           repdir = outdir, seed = seed, copy_to_bucket = FALSE)
}
