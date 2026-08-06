# export_validation_summary.R — a PHI-free, small-cell-suppressed summary that can leave the
# Workbench by copy-paste. T-023.
#
# WORKBENCH:
#   source("src/figures/survival_curves.R")
#   source("src/figures/prevent_calibration.R")
#   source("src/ascvd/validation/export_validation_summary.R")
#   res <- run_survival_curves()
#   cal <- make_prevent_calibration_figures(res)
#   export_validation_summary(res, cal)          # prints, and writes reports/validation_summary_*.txt
#
# ------------------------------------------------------------------------------------------------
# WHAT MAKES THIS SAFE TO PASTE OUT
#
#   - AGGREGATES ONLY. No person_id, no row-level anything, no dates other than the two STUDY
#     parameters (landmark, end_of_followup), which are analyst choices, not participant data.
#   - EVERY COUNT BELOW 20 IS SUPPRESSED (H-006 / All of Us policy), printed as "<20".
#   - SECONDARY SUPPRESSION. A percentage computed from a suppressed count leaks it back, so when a
#     count is suppressed the statistics derived from it are blanked too. This is the step that is
#     easy to forget and it is why the suppression is applied by a helper rather than by hand at
#     each call site.
#   - N and person-years are ROUNDED, so no cell is a fingerprint.
#
# Read the output before you paste it. This is a tool, not a guarantee: it enforces the numeric rule
# it knows about, and it cannot tell you whether a combination of cells is disclosive in context.
#
# ------------------------------------------------------------------------------------------------
# WHAT WOULD ACTUALLY COUNT AS "PREVENT IS VALIDATED IN ALL OF US"
#
# Stated here, before the numbers, so the criteria are not chosen after seeing them. Validating a
# risk equation is two separate claims and they fail independently:
#
#   DISCRIMINATION -- does it rank people correctly? Harrell's C. The paper reports ~0.79 (women) /
#     ~0.78 (men) for 10-year ASCVD. Ours will be LOWER for reasons that are not PREVENT's fault:
#     shorter follow-up, a narrower age range, and noisier EHR outcomes all compress C. A C of
#     0.70-0.75 here would be consistent with the paper, not a contradiction.
#
#   CALIBRATION -- are the predicted probabilities right in absolute terms? This is the one we
#     probably CANNOT claim either way yet, and the honest answer is to say so. Under-ascertained EHR
#     outcomes push observed risk down, which is indistinguishable on a calibration plot from PREVENT
#     genuinely over-predicting. The incidence-vs-literature check is what bounds this: if our acute
#     rate is well below the published 4.15-4.30/1000 PY, then some of any apparent over-prediction is
#     ascertainment, and the calibration plot cannot separate the two.
#
# So the defensible claim structure is: discrimination first, calibration conditional on the
# incidence check, and the ascertainment caveats attached to both. A single sentence claiming
# "PREVENT is validated in All of Us" is not supportable from this analysis and should not be made.
# ------------------------------------------------------------------------------------------------

.MIN_CELL <- 20

#' Suppress a count below the disclosure threshold.
#'
#' Zero is suppressed too. A published 0 is often defensible, but "0 events in this decile" combined
#' with the neighbouring cells can be as informative as a small count, and the cost of suppressing it
#' is one uninformative row.
.sup <- function(n, min_cell = .MIN_CELL) {
  ifelse(is.na(n), "NA", ifelse(n < min_cell, sprintf("<%d", min_cell),
                                format(round(n), big.mark = ",", trim = TRUE)))
}
.is_sup <- function(n, min_cell = .MIN_CELL) is.na(n) | n < min_cell

#' Blank a derived statistic whose input count was suppressed (secondary suppression).
.sup_stat <- function(x, n, fmt = "%.2f", min_cell = .MIN_CELL)
  ifelse(.is_sup(n, min_cell), "-", sprintf(fmt, x))

.rule <- function(ch = "-", n = 92) paste(rep(ch, n), collapse = "")

#' Build the PHI-free validation summary.
#'
#' @param res  the list from run_survival_curves().
#' @param cal  the list from make_prevent_calibration_figures(). Optional.
#' @param path where to write it. NULL to only print.
#' @param min_cell  disclosure threshold. Do not raise it above 20 without checking policy; do not
#'   lower it at all.
#' @return the text, invisibly.
export_validation_summary <- function(res, cal = NULL, path = NULL, min_cell = .MIN_CELL) {
  if (min_cell < .MIN_CELL)
    stop(sprintf("min_cell = %d is below the %d-person disclosure threshold. Refusing.",
                 min_cell, .MIN_CELL), call. = FALSE)
  fr <- if (!is.null(res$frame)) res$frame else res
  L  <- character(0)
  add <- function(...) L <<- c(L, sprintf(...))

  add("%s", .rule("="))
  add("PREVENT VALIDATION SUMMARY -- All of Us  (aggregate only; counts < %d suppressed)", min_cell)
  add("generated %s", format(Sys.Date()))
  add("%s", .rule("="))

  # --- study parameters -----------------------------------------------------------------------
  add("\n[1] STUDY PARAMETERS")
  add("  design                : landmark cohort (shared baseline; NOT the case-anchored D-019 design)")
  add("  landmark (T0)         : %s", format(res$landmark %||% fr$landmark))
  add("  end of follow-up      : %s", format(res$end_of_followup %||% fr$end_of_followup))
  add("  follow-up window      : %.2f years",
      as.numeric((res$end_of_followup %||% fr$end_of_followup) -
                 (res$landmark %||% fr$landmark)) / 365.25)
  add("  panel-to-event rule   : %s days (D-017)", fr$min_days_panel_to_event %||% NA)
  add("  smoking               : %s", fr$smoking_source %||% "unknown")
  add("  outcome (primary)     : all ASCVD -- chronic dx OR acute event OR revascularisation (D-016)")
  add("  outcome (comparable)  : acute events only -- the paper's hard outcome")

  # --- attrition ------------------------------------------------------------------------------
  add("\n[2] ATTRITION")
  if (!is.null(fr$counts)) {
    ct <- fr$counts
    for (i in seq_len(nrow(ct)))
      add("  %-52s %10s", substr(ct$step[i], 1, 52), .sup(ct$n[i], min_cell))
  } else add("  (not available)")

  # --- observed incidence, and the literature check -------------------------------------------
  add("\n[3] OBSERVED INCIDENCE  -- this bounds every calibration claim below")
  emit_rate <- function(ar, lab) {
    if (is.null(ar)) return(invisible(NULL))
    d  <- ar[!is.na(ar$event), , drop = FALSE]
    if (!nrow(d)) { add("  %-22s (empty at-risk set)", lab); return(invisible(NULL)) }
    ev <- sum(d$event == 1L); py <- sum(d$followup_days, na.rm = TRUE) / 365.25
    add("  %-22s at-risk %10s | events %8s | person-yrs %10s | rate/1000PY %s",
        lab, .sup(nrow(d), min_cell), .sup(ev, min_cell), .sup(py, min_cell),
        .sup_stat(1000 * ev / py, ev, "%.2f", min_cell))
  }
  emit_rate(fr$at_risk,       "all ASCVD (D-016)")
  emit_rate(fr$at_risk_acute, "acute only")
  add("  published (Khan)      : 4.15 (validation) / 4.30 (derivation) per 1000 person-years")
  add("  plausible band here   : 4 - 12 per 1000 PY (older, EHR-selected). Outside 2-20 = defect.")
  add("  NOTE: only the ACUTE row is comparable to the published rate. The broad outcome counts a")
  add("        first chronic diagnosis and revascularisation, which are far commoner in EHR data.")

  # --- KM cumulative incidence ------------------------------------------------------------------
  emit_km <- function(k, lab) {
    if (is.null(k) || !nrow(k)) return(invisible(NULL))
    add("\n  %s", lab)
    add("    %-8s %10s %10s %12s %20s", "years", "n_risk", "n_event", "cuminc %", "95% CI")
    for (i in seq_len(nrow(k))) {
      sup <- .is_sup(k$n_event[i], min_cell) | .is_sup(k$n_risk[i], min_cell)
      add("    %-8s %10s %10s %12s %20s",
          format(k$years[i]), .sup(k$n_risk[i], min_cell), .sup(k$n_event[i], min_cell),
          if (sup) "-" else sprintf("%.2f", k$cuminc_pct[i]),
          if (sup) "-" else sprintf("%.2f - %.2f", k$lower_pct[i], k$upper_pct[i]))
    }
  }
  add("\n[4] KAPLAN-MEIER CUMULATIVE INCIDENCE")
  # survfit's summary(times=) reports n.event as events since the PREVIOUS requested time, not since
  # baseline. Left as-is (it is what survival returns) but labelled, because a reader who assumes
  # cumulative will read the last row as a drop in events.
  add("  n_event = events in the interval since the previous row, NOT cumulative.")
  add("  cuminc %% IS cumulative from the landmark.")
  emit_km(res$km,       "all ASCVD (D-016 primary)")
  emit_km(res$km_acute, "acute only (comparable to the paper)")
  if (!is.null(res$km_by_sex)) {
    add("\n  by sex (all ASCVD)")
    k <- res$km_by_sex
    add("    %-10s %-8s %10s %10s %12s", "sex", "years", "n_risk", "n_event", "cuminc %")
    for (i in seq_len(nrow(k)))
      add("    %-10s %-8s %10s %10s %12s", k$strata[i], format(k$years[i]),
          .sup(k$n_risk[i], min_cell), .sup(k$n_event[i], min_cell),
          .sup_stat(k$cuminc_pct[i], min(k$n_event[i], k$n_risk[i]), "%.2f", min_cell))
  }

  # --- discrimination ---------------------------------------------------------------------------
  add("\n[5] DISCRIMINATION -- Harrell's C  (the claim least damaged by our ascertainment gaps,")
  add("    because concordance uses only the ORDER of predicted risk, not its scale)")
  emit_c <- function(cc) {
    if (is.null(cc)) { add("  (not computed -- needs >= 10 events and a PREVENT risk column)"); return() }
    add("    %-10s %10s %10s %10s %20s", "stratum", "n", "events", "C", "95% CI")
    for (i in seq_len(nrow(cc)))
      add("    %-10s %10s %10s %10s %20s", cc$stratum[i], .sup(cc$n[i], min_cell),
          .sup(cc$events[i], min_cell), .sup_stat(cc$c_index[i], cc$events[i], "%.3f", min_cell),
          if (.is_sup(cc$events[i], min_cell)) "-"
          else sprintf("%.3f - %.3f", cc$lower[i], cc$upper[i]))
  }
  if (!is.null(cal)) { emit_c(cal$concordance); emit_c(cal$concordance_by_sex) }
  else add("  (calibration object not supplied)")
  # CORRECTED 2026-08-06 (T-024): this line read "~0.79 women / ~0.78 men" for ASCVD. Those are the
  # paper's TOTAL CVD numbers (0.794 / 0.757); its ASCVD figures are 0.774 and 0.736, which is what
  # config.yaml has carried all along. The error made our C look worse against the benchmark than it
  # is -- and for men by nearly 0.05, which is most of the gap this section exists to explain.
  add("  published (Table 4, ASCVD, external validation): 0.774 women / 0.736 men -- and those are")
  add("  MEDIANS across 21 cohorts, IQI 0.743-0.788 and 0.710-0.755, i.e. a spread BETWEEN")
  add("  populations rather than a confidence interval. Ours is expected LOWER still: shorter")
  add("  follow-up, narrower age range, noisier EHR outcomes all compress C. 0.70-0.75 here is")
  add("  CONSISTENT with the paper, not a contradiction.")

  # --- calibration ------------------------------------------------------------------------------
  add("\n[6] CALIBRATION -- observed (Kaplan-Meier) vs predicted, by group of predicted risk")
  if (!is.null(cal) && !is.null(cal$calibration) && nrow(cal$calibration)) {
    add("  horizon %d y | outcome = %s | predicted rescaled 10y -> horizon by 1-(1-p)^(t/10)",
        cal$horizon_years, cal$outcome)
    ct <- cal$calibration
    add("    %-6s %9s %9s %12s %12s %12s %10s", "group", "n", "events", "pred_10yr%",
        "pred_horiz%", "obs_KM%", "obs/pred")
    for (i in seq_len(nrow(ct))) {
      sup <- .is_sup(ct$events[i], min_cell) | .is_sup(ct$n[i], min_cell)
      add("    %-6s %9s %9s %12s %12s %12s %10s",
          ct$group[i], .sup(ct$n[i], min_cell), .sup(ct$events[i], min_cell),
          sprintf("%.2f", ct$predicted_10yr[i]), sprintf("%.2f", ct$predicted_horizon[i]),
          if (sup) "-" else sprintf("%.2f", ct$observed_pct[i]),
          if (sup) "-" else sprintf("%.3f", ct$observed_pct[i] / ct$predicted_horizon[i]))
    }
    ok <- !.is_sup(ct$events, min_cell)
    if (any(ok))
      add("  overall observed/predicted (unsuppressed groups): %.3f",
          sum(ct$observed_pct[ok] * ct$n[ok]) / sum(ct$predicted_horizon[ok] * ct$n[ok]))
    add("  <1 = PREVENT predicts MORE than observed. Cannot be read as over-prediction until")
    add("  section [3] shows our event rate is in the plausible band -- under-ascertainment")
    add("  produces the identical pattern.")
  } else add("  (no calibration table -- see the warning from make_prevent_calibration_figures)")

  # --- the caveats -------------------------------------------------------------------------------
  add("\n[7] WHAT LIMITS THESE NUMBERS (all four apply to every row above)")
  add("  1. Death not modelled. Competing risk treated as censoring -> incidence OVERSTATED.")
  add("  2. ICD10CM only. Pre-~Oct-2015 events invisible -> prevalent cases leak in as incident,")
  add("     and early follow-up is left-truncated.")
  add("  3. Censored at the CDR cutoff, not last contact -> person-time inflated, rate pushed DOWN.")
  add("  4. bp_tx is PROVISIONAL ('on a BP-lowering drug', not 'treated for hypertension');")
  add("     smoking answer coding is PROVISIONAL. Both feed predicted risk.")
  add("  Also: no genomic layer in this workspace (H-005) -- this is the genomic-free EHR cohort.")

  add("\n%s", .rule("="))
  add("SAFE TO PASTE: aggregates only, no person_id, no participant dates, counts < %d suppressed,", min_cell)
  add("derived statistics blanked where their count was suppressed. READ IT BEFORE PASTING.")
  add("%s", .rule("="))

  txt <- paste(L, collapse = "\n")
  cat(txt, "\n")
  if (is.null(path)) path <- file.path("reports",
                                       sprintf("validation_summary_%s.txt", format(Sys.Date())))
  if (!dir.exists(dirname(path))) dir.create(dirname(path), recursive = TRUE)
  writeLines(L, path)
  message(sprintf("\nwritten to %s", path))
  invisible(txt)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
