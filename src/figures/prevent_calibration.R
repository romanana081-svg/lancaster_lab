# prevent_calibration.R — the figures that are directly comparable to the PREVENT validation paper.
# T-022 / T-007 (DESIGN stage 5).
#
# WORKBENCH:
#   source("src/figures/survival_curves.R")
#   res <- run_survival_curves()
#   source("src/figures/prevent_calibration.R")
#   cal <- make_prevent_calibration_figures(res)
#
# ------------------------------------------------------------------------------------------------
# WHAT THE VALIDATION PAPER SHOWS, AND WHAT WE HAVE TO DO DIFFERENTLY
#
# Khan et al. validate PREVENT with CALIBRATION plots: predicted risk on the x-axis, observed risk on
# the y-axis, one point per decile of predicted risk, a 45-degree reference line, stratified by sex.
# Points below the line = over-prediction. That is the figure to put next to theirs.
#
# Three things have to be right or the comparison is worse than useless, because a miscalibration
# artefact and a real miscalibration look identical on the plot:
#
# 1. OBSERVED MUST COME FROM A CENSORING-AWARE ESTIMATOR, NOT events/N. A crude proportion treats
#    everyone censored early as a non-event and UNDER-states observed risk -- which in a plot of
#    observed vs predicted reads as over-prediction by PREVENT. That is precisely the conclusion this
#    figure exists to test, so getting it from a censoring artefact would be self-confirming.
#    `16_observed_by_prevent_risk` uses the crude proportion; this file does not, and that is the
#    main reason it exists.
#
#    WHICH estimator (changed 2026-09-29, D-021): AALEN-JOHANSEN when the frame carries
#    `competing_status` (apply_competing_death(), extract_death.R), Kaplan-Meier when it does not.
#    1 - KM treats a death as censoring, i.e. it estimates ASCVD risk in a population where nobody
#    dies of anything else first, and so OVER-states what was actually observed. Aalen-Johansen
#    estimates the cumulative incidence of ASCVD with death as a competing event, which is the
#    quantity a predicted risk should be compared against. With no deaths the two are the same
#    number. The estimator used is returned in the table's `estimator` column and printed on the
#    axis, so a figure can never claim one while showing the other.
#
# 2. THE HORIZONS MUST MATCH. PREVENT predicts 10 years. We have ~4-5. Comparing a 4.5-year observed
#    risk to a 10-year predicted risk shows enormous "over-prediction" that is pure units error.
#    Predicted is converted to the observation horizon under a constant-hazard assumption,
#    p_t = 1 - (1 - p_10)^(t/10), and BOTH numbers are labelled with the horizon on the figure.
#    The constant-hazard step is itself an approximation (ASCVD hazard rises with age, so this
#    slightly UNDER-states the horizon risk) -- stated in the caption rather than hidden.
#
# 3. STRATIFY BY SEX. PREVENT is sex-specific, the paper reports it that way, and a pooled plot can
#    hide opposite-direction miscalibration in the two sexes.
#
# Discrimination (Harrell's C) is computed alongside, because the paper reports C-statistics and it is
# the one number that is unaffected by the horizon mismatch above -- it only uses the ORDERING of
# predicted risk. When the calibration comparison is muddied by follow-up length, C is still clean.
# ------------------------------------------------------------------------------------------------

suppressPackageStartupMessages({ library(ggplot2); library(dplyr) })

.RISK_COLS <- c("prevent_base_10yr_ASCVD", "risk10", "prevent_10yr")

.find_risk_col <- function(d) {
  hit <- intersect(.RISK_COLS, names(d))
  if (length(hit)) return(hit[1])

  # FALL BACK TO A PATTERN before giving up. The exact column name is whatever
  # AHAprevent::prevent_base() names its output element -- a package detail we do not control and
  # have never verified against an installed copy, because every test that touches AHAprevent skips
  # when it is absent, which it is on the development machine. A capitalisation change there would
  # otherwise take down every calibration output with a message blaming the installation.
  loose <- grep("ascvd", grep("10.?y(ea)?r", names(d), ignore.case = TRUE, value = TRUE),
                ignore.case = TRUE, value = TRUE)
  if (length(loose)) {
    message("using '", loose[1], "' as the PREVENT 10-year ASCVD risk column (matched by pattern, ",
            "not by exact name -- if AHAprevent renamed its output, add it to .RISK_COLS).")
    return(loose[1])
  }

  # No column at all. Say which of the three causes it is rather than asking about the installation,
  # which is the least likely of them once anyone has got this far.
  near <- grep("prevent|ascvd|risk", names(d), ignore.case = TRUE, value = TRUE)
  stop(sprintf("no PREVENT risk column found (looked for: %s, then any name matching 10yr + ascvd).
  Columns present that look related: %s
  The panel was NOT SCORED. In order of likelihood:
    1. run_prevent() was not sourced when the cohort was built -- build_incidence_frame() skips
       scoring silently in that case. Check res$frame$prevent_source; it now records the reason.
    2. run_prevent() errored during the run (look back for a warning naming it).
    3. AHAprevent is genuinely absent: requireNamespace('AHAprevent', quietly = TRUE).
  You do NOT need to re-run the cohort to fix this. Score the frames you already have:
    source('src/ascvd/prevent/run_prevent.R')
    res$frame$at_risk       <- run_prevent(res$frame$at_risk)
    res$frame$at_risk_acute <- run_prevent(res$frame$at_risk_acute)",
               paste(.RISK_COLS, collapse = ", "),
               if (length(near)) paste(near, collapse = ", ") else "(none)"), call. = FALSE)
}

#' Convert a 10-year risk to the observation horizon, assuming a constant hazard.
#'
#' p_t = 1 - (1 - p_10)^(t/10). This is the standard cheap conversion and it is an APPROXIMATION:
#' ASCVD hazard rises with age, so a constant-hazard conversion slightly under-states risk at
#' horizons shorter than 10 years. Reported, not hidden.
#'
#' Deliberately NOT the linear `p_10 * t/10` shortcut used in the runbook's one-line sanity check --
#' that one is fine for an order-of-magnitude check and wrong for a calibration plot, because it
#' over-states at large p exactly where the highest-risk decile lives.
rescale_risk_to_horizon <- function(p10, horizon_years) {
  p10 <- pmin(pmax(as.numeric(p10) / 100, 0), 0.999999)   # PREVENT returns percent
  100 * (1 - (1 - p10)^(horizon_years / 10))
}

#' Does this frame carry competing-event information? Same rule as has_competing_status() in
#' extract_death.R, restated here so this file does not depend on that one being sourced.
.has_competing <- function(d)
  "competing_status" %in% names(d) && any(!is.na(d$competing_status))

#' Observed cumulative incidence of ASCVD at one time point, with its 95% interval.
#'
#' Aalen-Johansen (death as a competing event) when `competing` is TRUE, 1 - Kaplan-Meier
#' otherwise. RIGHT-CENSORING is handled the same way by both: a person censored at time c counts
#' in the risk set up to c and not after, so they inform the estimate for exactly as long as they
#' were watched. What differs is a DEATH -- KM removes the person as if they might still have had
#' the event later, AJ records that they no longer can.
#'
#' @param g  rows of an at-risk frame, already filtered to the at-risk set.
#' @param t_days  the horizon in days.
#' @param competing  use Aalen-Johansen. Decided by the CALLER on the whole frame, never here per
#'   group: a decile that happens to contain no deaths must be estimated the same way as its
#'   neighbours.
#' @return list(observed_pct, lower_pct, upper_pct, n_risk, deaths, estimator)
.observed_risk_at <- function(g, t_days, competing = .has_competing(g)) {
  if (isTRUE(competing)) {
    # The factor's FIRST level is what survfit reads as censoring. All three levels are declared
    # even when a group has no deaths, so the "ascvd" column always exists to be read by name --
    # indexing the state matrix by position is how a group with no deaths returns the death column.
    st  <- factor(g$competing_status, levels = 0:2, labels = c("censored", "ascvd", "death"))
    fit <- survival::survfit(survival::Surv(g$followup_days, st) ~ 1)
    s   <- summary(fit, times = t_days, extend = TRUE)
    ps  <- matrix(s$pstate, ncol = length(fit$states), dimnames = list(NULL, fit$states))
    lo  <- matrix(s$lower,  ncol = length(fit$states), dimnames = list(NULL, fit$states))
    hi  <- matrix(s$upper,  ncol = length(fit$states), dimnames = list(NULL, fit$states))
    nr  <- matrix(s$n.risk, ncol = length(fit$states))
    # With zero ASCVD events in a group the variance is 0 and survfit returns NA bounds. The
    # estimate is a real 0%, so keep the point and let the interval be missing rather than invented.
    list(observed_pct = 100 * unname(ps[1, "ascvd"]), lower_pct = 100 * unname(lo[1, "ascvd"]),
         upper_pct = 100 * unname(hi[1, "ascvd"]), n_risk = unname(nr[1, 1]),
         deaths = sum(g$competing_status == 2L, na.rm = TRUE), estimator = "Aalen-Johansen")
  } else {
    fit <- survival::survfit(survival::Surv(g$followup_days, g$event) ~ 1)
    s   <- summary(fit, times = t_days, extend = TRUE)
    # survfit's `upper` bounds SURVIVAL, so it becomes the LOWER bound on risk.
    list(observed_pct = 100 * (1 - s$surv[1]), lower_pct = 100 * (1 - s$upper[1]),
         upper_pct = 100 * (1 - s$lower[1]), n_risk = s$n.risk[1], deaths = NA_integer_,
         estimator = "Kaplan-Meier")
  }
}

#' Observed risk at a horizon within each predicted-risk group, plus predicted.
#'
#' @param at_risk  the frame from ascvd_status_at(), carrying the PREVENT risk column. If it has been
#'   through apply_competing_death() the observed risk is Aalen-Johansen; otherwise Kaplan-Meier.
#' @param horizon_years  the horizon to evaluate at. Must be <= the follow-up actually available.
#' @param n_groups  10 for deciles (what the paper uses), 5 if events are scarce.
#' @param by_sex  compute within sex.
#' @return data.frame(stratum, group, n, events, deaths, predicted_10yr, predicted_horizon,
#'                    observed_pct, lower_pct, upper_pct, n_risk_at_horizon, estimator)
calibration_table <- function(at_risk, horizon_years, n_groups = 10, by_sex = FALSE) {
  rc <- .find_risk_col(at_risk)
  d  <- at_risk[!is.na(at_risk$event) & !is.na(at_risk[[rc]]) &
                !is.na(at_risk$followup_days) & at_risk$followup_days >= 0, , drop = FALSE]
  if (!nrow(d)) return(NULL)
  d$.risk <- as.numeric(d[[rc]])
  competing <- .has_competing(d)
  if (competing && any(is.na(d$competing_status)))
    stop("calibration_table(): `competing_status` is NA for ", sum(is.na(d$competing_status)),
         " at-risk row(s). Every at-risk person must have one of 0/1/2 -- run the frame through
  apply_competing_death() as a whole rather than attaching the column by hand.", call. = FALSE)
  strata_var <- if (isTRUE(by_sex) && "sex" %in% names(d)) d$sex else rep("all", nrow(d))
  d$.stratum <- as.character(strata_var)

  out <- lapply(split(d, d$.stratum), function(g) {
    if (nrow(g) < n_groups * 2) return(NULL)
    # Group WITHIN stratum: PREVENT is sex-specific, so a pooled cut would put most women in the low
    # deciles and most men in the high ones, and each "decile" would then be mostly one sex.
    brk <- unique(stats::quantile(g$.risk, probs = seq(0, 1, length.out = n_groups + 1), na.rm = TRUE))
    if (length(brk) < 3) return(NULL)
    g$.grp <- cut(g$.risk, breaks = brk, include.lowest = TRUE, labels = FALSE)
    rows <- lapply(sort(unique(g$.grp)), function(k) {
      gk  <- g[g$.grp == k, , drop = FALSE]
      obs <- .observed_risk_at(gk, horizon_years * 365.25, competing = competing)
      data.frame(
        stratum = gk$.stratum[1], group = k, n = nrow(gk), events = sum(gk$event == 1L),
        deaths  = obs$deaths,
        predicted_10yr    = mean(gk$.risk),
        predicted_horizon = mean(rescale_risk_to_horizon(gk$.risk, horizon_years)),
        observed_pct = obs$observed_pct,
        lower_pct    = obs$lower_pct,
        upper_pct    = obs$upper_pct,
        n_risk_at_horizon = obs$n_risk,
        estimator = obs$estimator,
        stringsAsFactors = FALSE)
    })
    do.call(rbind, rows)
  })
  res <- do.call(rbind, Filter(Negate(is.null), out))
  if (is.null(res)) return(NULL)
  rownames(res) <- NULL
  res
}

#' Harrell's C for the PREVENT score — the discrimination number the paper reports.
#'
#' Unaffected by the 10-year-vs-4-year horizon mismatch: concordance uses only the ORDER of predicted
#' risk, not its scale. So when calibration is hard to compare, this still is.
#'
#' COMPETING DEATHS: this is the CAUSE-SPECIFIC C. It reads only `event` and `followup_days`, and
#' after apply_competing_death() a person who died has event = 0 with follow-up ending at death --
#' so they are compared with others only while alive. That is the conventional choice and the one
#' comparable to the published C; the alternative (keeping the dead in the risk set forever, Wolbers
#' 2009) answers a different question and is not what this computes.
prevent_concordance <- function(at_risk, by_sex = FALSE) {
  rc <- .find_risk_col(at_risk)
  d  <- at_risk[!is.na(at_risk$event) & !is.na(at_risk[[rc]]) &
                !is.na(at_risk$followup_days) & at_risk$followup_days >= 0, , drop = FALSE]
  if (!nrow(d) || sum(d$event) < 10) return(NULL)
  one <- function(g, lab) {
    if (sum(g$event) < 10) return(NULL)
    cc <- survival::concordance(survival::Surv(g$followup_days, g$event) ~ g[[rc]], reverse = TRUE)
    data.frame(stratum = lab, n = nrow(g), events = sum(g$event),
               c_index = unname(cc$concordance),
               se = sqrt(unname(cc$var)), stringsAsFactors = FALSE)
  }
  res <- if (isTRUE(by_sex) && "sex" %in% names(d))
           do.call(rbind, lapply(split(d, d$sex), function(g) one(g, as.character(g$sex[1]))))
         else one(d, "all")
  if (is.null(res)) return(NULL)
  res$lower <- res$c_index - 1.96 * res$se
  res$upper <- res$c_index + 1.96 * res$se
  rownames(res) <- NULL
  res
}

#' KM cumulative-incidence curves stratified by predicted-risk group.
#'
#' The "survival curve" form of the calibration question: do the curves separate, and in the right
#' order? Separation is discrimination made visible; the paper's calibration plot is the same
#' information collapsed to one time point.
.km_by_group <- function(at_risk, n_groups = 5) {
  rc <- .find_risk_col(at_risk)
  d  <- at_risk[!is.na(at_risk$event) & !is.na(at_risk[[rc]]) &
                !is.na(at_risk$followup_days) & at_risk$followup_days >= 0, , drop = FALSE]
  if (!nrow(d)) return(NULL)
  brk <- unique(stats::quantile(d[[rc]], probs = seq(0, 1, length.out = n_groups + 1), na.rm = TRUE))
  if (length(brk) < 3) return(NULL)
  d$grp <- cut(d[[rc]], breaks = brk, include.lowest = TRUE, labels = FALSE)
  # Label with the actual risk range, so a reader can see WHAT "group 5" means without a lookup.
  lab <- tapply(d[[rc]], d$grp, function(x) sprintf("%.1f-%.1f%%", min(x), max(x)))
  fit <- survival::survfit(survival::Surv(followup_days, event) ~ grp, data = d)
  s   <- summary(fit)
  g   <- sub("^[^=]*=", "", as.character(s$strata))
  data.frame(years = s$time / 365.25, cuminc = 100 * (1 - s$surv),
             group = factor(g, levels = names(lab), labels = sprintf("%s (%s)", names(lab), lab)),
             stringsAsFactors = FALSE)
}

#' Write the paper-comparable figures.
#'
#' @param res  the list returned by run_survival_curves(), OR a bare at_risk data.frame.
#' @param horizon_years  NULL to use the largest whole year that most people actually reach.
#' @param outcome  "broad" (D-016 primary) or "acute" (literature-comparable). The paper's outcome is
#'   a HARD outcome, so "acute" is the honest comparison and it is the DEFAULT here -- the opposite of
#'   the incidence figures, deliberately.
make_prevent_calibration_figures <- function(res, outdir = "figures", horizon_years = NULL,
                                             outcome = c("acute", "broad"), n_groups = 10,
                                             n_curve_groups = 5, dpi = 150) {
  outcome <- match.arg(outcome)
  if (!requireNamespace("survival", quietly = TRUE)) stop("install.packages('survival')")
  at_risk <- if (is.data.frame(res)) res else
             if (outcome == "acute") res$frame$at_risk_acute else res$frame$at_risk
  if (is.null(at_risk)) stop("could not find the at-risk frame in `res`.", call. = FALSE)
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
  save <- function(name, p, w = 7.5, h = 5.2)
    ggsave(file.path(outdir, name), p, width = w, height = h, dpi = dpi, bg = "white")

  # Pick a horizon most people actually reach. Evaluating at a horizon beyond the bulk of follow-up
  # gives a KM estimate resting on a handful of people, with a CI to match -- the classic tail
  # artefact that makes a calibration plot look wildly miscalibrated at the top decile.
  fu <- at_risk$followup_days[!is.na(at_risk$event)]
  if (is.null(horizon_years)) {
    horizon_years <- max(1, floor(stats::quantile(fu, 0.75, na.rm = TRUE) / 365.25))
    message(sprintf("horizon not supplied — using %d year(s) (75th pct of follow-up is %.1f y)",
                    horizon_years, stats::quantile(fu, 0.75, na.rm = TRUE) / 365.25))
  }

  cal      <- calibration_table(at_risk, horizon_years, n_groups = n_groups, by_sex = FALSE)
  cal_sex  <- calibration_table(at_risk, horizon_years, n_groups = n_groups, by_sex = TRUE)
  cidx     <- prevent_concordance(at_risk, by_sex = FALSE)
  cidx_sex <- prevent_concordance(at_risk, by_sex = TRUE)
  km_grp   <- .km_by_group(at_risk, n_groups = n_curve_groups)

  lab_outcome <- if (outcome == "acute") "acute ASCVD (hard outcome — the paper's outcome)"
                 else "all ASCVD (D-016 broad outcome — NOT the paper's outcome)"
  cap_horizon <- sprintf(paste("Predicted 10-year PREVENT risk converted to %d years assuming a",
                               "constant hazard: p_t = 1-(1-p10)^(t/10).\nThat conversion slightly",
                               "UNDER-states risk (ASCVD hazard rises with age), so true",
                               "over-prediction is if anything larger than shown."), horizon_years)

  # --- 18. KM curves by predicted-risk group ------------------------------------------------------
  if (!is.null(km_grp) && nrow(km_grp)) {
    save("18_km_by_prevent_risk.png",
      ggplot(km_grp, aes(years, cuminc, color = group)) +
        geom_step(linewidth = 1.05) +
        scale_y_continuous(labels = function(x) paste0(x, "%")) +
        scale_color_brewer(palette = "RdYlBu", direction = -1,
                           name = "PREVENT 10-yr risk\ngroup (range)") +
        labs(title = "Observed ASCVD by predicted-risk group",
             subtitle = paste0("Kaplan-Meier cumulative incidence\n", lab_outcome),
             x = "Years since landmark", y = "Cumulative incidence",
             caption = paste("Curves should separate in order — that IS discrimination, shown as a",
                             "survival curve.\nSeparation here is the same information the",
                             "calibration plot collapses into one time point.")) +
        theme_minimal(base_size = 13) +
        theme(panel.grid.minor = element_blank(),
              plot.title = element_text(face = "bold"),
              plot.caption = element_text(color = "grey45", size = 9, hjust = 0)))
  }

  # --- 19. calibration: observed vs predicted, the paper's figure --------------------------------
  mk_cal_plot <- function(df, title, subtitle, facet = FALSE) {
    lim <- range(c(df$predicted_horizon, df$observed_pct, df$lower_pct, df$upper_pct), na.rm = TRUE)
    lim <- c(0, max(lim, na.rm = TRUE) * 1.08)
    p <- ggplot(df, aes(predicted_horizon, observed_pct)) +
      geom_abline(slope = 1, intercept = 0, color = "grey55", linetype = "22") +
      geom_errorbar(aes(ymin = lower_pct, ymax = upper_pct), width = 0, color = "grey60") +
      geom_point(size = 2.8, color = "#4C72B0") +
      coord_equal(xlim = lim, ylim = lim) +
      scale_x_continuous(labels = function(x) paste0(x, "%")) +
      scale_y_continuous(labels = function(x) paste0(x, "%")) +
      labs(title = title, subtitle = subtitle,
           x = sprintf("Predicted %d-year risk (PREVENT)", horizon_years),
           y = sprintf("Observed %d-year risk (%s)", horizon_years, df$estimator[1]),
           caption = paste0("Points BELOW the dashed line = PREVENT over-predicts. Bars are 95% CI on",
                            " the observed ", df$estimator[1], " estimate.\n", cap_horizon,
                            "\nObserved is ", df$estimator[1], ", NOT events/N — a crude proportion",
                            " counts early-censored people as non-events\nand would manufacture",
                            " exactly the over-prediction this figure tests for.",
                            if (identical(df$estimator[1], "Kaplan-Meier"))
                              paste0("\nDeath is NOT modelled here (no competing_status on the",
                                     " frame), so observed risk is biased UPWARD.") else "")) +
      theme_minimal(base_size = 13) +
      theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
            plot.caption = element_text(color = "grey45", size = 8.5, hjust = 0))
    if (facet) p <- p + facet_wrap(~ stratum)
    p
  }

  if (!is.null(cal) && nrow(cal)) {
    # Newline, not " · ": coord_equal() fixes the panel's aspect ratio, so a long single-line
    # subtitle is clipped at the plot edge rather than wrapped. Caught on the synthetic run.
    sub <- sprintf("%s\n%s groups · N = %s, events = %s",
                   lab_outcome, nrow(cal), format(sum(cal$n), big.mark = ","),
                   format(sum(cal$events), big.mark = ","))
    if (!is.null(cidx))
      sub <- paste0(sub, sprintf("\nHarrell's C = %.3f (95%% CI %.3f-%.3f)",
                                 cidx$c_index[1], cidx$lower[1], cidx$upper[1]))
    save("19_calibration_observed_vs_predicted.png",
         mk_cal_plot(cal, "PREVENT calibration in All of Us", sub), w = 7.2, h = 7.4)
  }

  if (!is.null(cal_sex) && nrow(cal_sex) && length(unique(cal_sex$stratum)) > 1) {
    sub <- paste0(lab_outcome, " · deciles within sex (PREVENT is sex-specific)")
    if (!is.null(cidx_sex))
      sub <- paste0(sub, "\n", paste(sprintf("C(%s) = %.3f", cidx_sex$stratum, cidx_sex$c_index),
                                     collapse = "   "))
    save("20_calibration_by_sex.png",
         mk_cal_plot(cal_sex, "PREVENT calibration, by sex", sub, facet = TRUE), w = 10, h = 6)
  }

  # Report what was ACTUALLY written. Claiming "figures written" while cal was NULL is the same class
  # of error as the stale-index summary line: a confident message that a reader has no way to check.
  if (is.null(cal) || !nrow(cal)) {
    n_scored <- sum(!is.na(at_risk[[.find_risk_col(at_risk)]]) & !is.na(at_risk$event))
    warning(sprintf("NO calibration figures written: only %d person(s) have BOTH a PREVENT risk and
  follow-up. PREVENT returns NA unless every input is present, so this is almost always
  scorable_only = FALSE upstream, or a missing input (bp_tx / smoking). Nothing to plot.", n_scored),
            call. = FALSE)
  } else {
    message(sprintf("calibration figures written to %s/ (horizon %d y, outcome = %s)",
                    outdir, horizon_years, outcome))
    print(cal)
  }
  if (!is.null(cidx)) { message("\nDiscrimination (Harrell's C):"); print(cidx) }
  if (!is.null(cidx_sex)) print(cidx_sex)

  invisible(list(calibration = cal, calibration_by_sex = cal_sex,
                 concordance = cidx, concordance_by_sex = cidx_sex,
                 horizon_years = horizon_years, outcome = outcome))
}
