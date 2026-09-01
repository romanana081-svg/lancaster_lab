# pooled_validation.R — Rubin's rules for the validation metrics computed across imputed datasets.
#
#   source("src/ascvd/validation/pooled_validation.R")
#   pool_concordance(lapply(imp$completed, function(d) prevent_concordance(d, by_sex = TRUE)))
#
# ------------------------------------------------------------------------------------------------
# WHY POOLING IS A SEPARATE STEP, AND WHY IT IS NOT "TAKE THE AVERAGE"
#
# Averaging the m C-statistics gets the point estimate right and the CONFIDENCE INTERVAL wrong — too
# narrow, because it throws away the fact that the m datasets disagree. Reporting a narrow interval on
# imputed data is the one way this analysis could actively mislead: it would claim more certainty than
# complete-case analysis while resting on values we made up.
#
# Rubin's rules keep both halves. Total variance T = Ubar + (1 + 1/m)B, where
#   Ubar = the average WITHIN-imputation variance   — ordinary sampling error, and
#   B    = the BETWEEN-imputation variance          — the price of not knowing.
# The (1 + 1/m) factor is the finite-m correction; it is why m = 5 is honest rather than a shortcut.
#
# The fraction of missing information (FMI) that comes out is the diagnostic to actually read: it says
# how much of the uncertainty in this estimate is due to imputation rather than sample size. FMI far
# above the fraction of missing VALUES means the imputation model is carrying more weight than it can
# bear, and the answer is a better model (or a narrower claim), not a larger m.
#
# ------------------------------------------------------------------------------------------------
# TWO SCALES, ON PURPOSE
#
# The C-statistic is bounded in [0, 1] and its sampling distribution is skewed near the bounds, so it
# is pooled on the LOGIT scale and transformed back — which is what keeps the interval inside [0, 1]
# instead of printing an upper bound of 1.03. The calibration slope is unbounded and is pooled on its
# natural scale. Doing it the other way round is not a rounding difference; it is the difference
# between an interval that can be printed and one that cannot.
# ------------------------------------------------------------------------------------------------

#' Rubin's rules for one scalar estimand.
#'
#' @param est numeric vector of length m — the estimate from each imputed dataset.
#' @param se  numeric vector of length m — its standard error in each.
#' @param dfcom complete-data degrees of freedom, for the Barnard-Rubin small-sample adjustment.
#'   Inf (the default) skips it, which is right at cohort scale and wrong for a handful of events —
#'   pass n - p when the event count is small.
#' @param conf confidence level.
#' @return list(est, se, var_within, var_between, df, lower, upper, fmi, m, riv)
rubin_pool <- function(est, se, dfcom = Inf, conf = 0.95) {
  ok  <- is.finite(est) & is.finite(se) & se >= 0
  est <- est[ok]; se <- se[ok]
  m   <- length(est)
  if (!m) return(NULL)

  qbar <- mean(est)
  ubar <- mean(se^2)                      # average within-imputation variance
  # var() of a single value is NA, and m = 1 is a legitimate degenerate case (one imputation, or m-1
  # of them failed). Between-imputation variance is then 0 by definition — unknown, not infinite —
  # and the result reduces to the single-dataset answer, which is the honest reading.
  b    <- if (m > 1) stats::var(est) else 0
  tvar <- ubar + (1 + 1 / m) * b

  # Relative increase in variance due to nonresponse. Guard both degenerate ends: identical estimates
  # across imputations (b = 0 -> riv = 0 -> infinite df, i.e. imputation added nothing) and a zero
  # within-variance (riv = Inf -> df = m-1, i.e. ALL the uncertainty is between-imputation).
  riv <- if (ubar > 0) (1 + 1 / m) * b / ubar else if (b > 0) Inf else 0
  df_old <- if (m <= 1) Inf else if (is.finite(riv) && riv > 0) (m - 1) * (1 + 1 / riv)^2 else Inf
  fmi    <- if (is.finite(riv)) (riv + 2 / (df_old + 3)) / (riv + 1) else 1

  # Barnard-Rubin (1999): with few events the complete-data df is itself small, and the classical
  # formula above can hand back more degrees of freedom than the complete data ever had.
  df <- if (is.finite(dfcom) && is.finite(df_old)) {
    df_obs <- (dfcom + 1) / (dfcom + 3) * dfcom * (1 - fmi)
    if (df_obs > 0) df_old * df_obs / (df_old + df_obs) else df_old
  } else df_old

  tcrit <- stats::qt(1 - (1 - conf) / 2, df = if (is.finite(df)) max(df, 1) else Inf)
  list(est = qbar, se = sqrt(tvar), var_within = ubar, var_between = b,
       df = df, lower = qbar - tcrit * sqrt(tvar), upper = qbar + tcrit * sqrt(tvar),
       fmi = fmi, m = m, riv = riv)
}

.logit  <- function(p) log(p / (1 - p))
.expit  <- function(x) 1 / (1 + exp(-x))

#' Pool Harrell's C across imputed datasets, per stratum, on the logit scale.
#'
#' @param conc_list list of prevent_concordance() outputs — one per imputed dataset. NULLs (a dataset
#'   with too few events to score) are dropped and COUNTED, never silently ignored: pooling 3 of 5
#'   imputations and calling it m = 5 misstates the between-imputation variance.
#' @return data.frame(stratum, m_used, m_requested, n, events, c_index, se, lower, upper, fmi)
pool_concordance <- function(conc_list, conf = 0.95) {
  m_req <- length(conc_list)
  good  <- Filter(function(x) !is.null(x) && nrow(x) > 0, conc_list)
  if (!length(good)) return(NULL)
  all   <- do.call(rbind, good)

  out <- lapply(split(all, all$stratum), function(g) {
    # Clamp off the bounds before the logit: a C of exactly 0 or 1 is a degenerate sample, not an
    # infinity, and letting it through poisons the whole pooled estimate with a non-finite term.
    cc <- pmin(pmax(g$c_index, 1e-6), 1 - 1e-6)
    # Delta method: Var(logit C) = Var(C) / (C(1-C))^2.
    p  <- rubin_pool(.logit(cc), g$se / (cc * (1 - cc)), conf = conf)
    if (is.null(p)) return(NULL)
    data.frame(stratum = g$stratum[1], m_used = nrow(g), m_requested = m_req,
               n = round(mean(g$n)), events = round(mean(g$events)),
               c_index = .expit(p$est), se = p$se,
               lower = .expit(p$lower), upper = .expit(p$upper),
               fmi = p$fmi, stringsAsFactors = FALSE)
  })
  res <- do.call(rbind, Filter(Negate(is.null), out))
  if (!is.null(res)) rownames(res) <- NULL
  res
}

#' Pool the calibration slope across imputed datasets, per stratum, on its natural scale.
#'
#' @param slope_list list of calibration_slope() outputs — one per imputed dataset.
#' @return data.frame(stratum, m_used, m_requested, slope, se, lower, upper, fmi, n, events)
pool_calibration_slope <- function(slope_list, conf = 0.95) {
  m_req <- length(slope_list)
  good  <- Filter(function(x) !is.null(x) && nrow(x) > 0, slope_list)
  if (!length(good)) return(NULL)
  all   <- do.call(rbind, good)

  out <- lapply(split(all, all$stratum), function(g) {
    p <- rubin_pool(g$slope, g$se, conf = conf)
    if (is.null(p)) return(NULL)
    data.frame(stratum = g$stratum[1], m_used = nrow(g), m_requested = m_req,
               slope = p$est, se = p$se, lower = p$lower, upper = p$upper, fmi = p$fmi,
               n = round(mean(g$n)), events = round(mean(g$events)), stringsAsFactors = FALSE)
  })
  res <- do.call(rbind, Filter(Negate(is.null), out))
  if (!is.null(res)) rownames(res) <- NULL
  res
}

#' One frame carrying each person's predicted risk AVERAGED across the imputed datasets.
#'
#' For the calibration FIGURE only. This is a display convention, not the pooled estimand: averaging
#' risks and then taking one slope is not the same quantity as pooling m slopes by Rubin's rules, and
#' it under-states the uncertainty in exactly the way the header warns about. So the plot is drawn
#' from this, the NUMBER quoted in the abstract comes from pool_calibration_slope(), and the caption
#' has to say which — otherwise a reader takes the interval off the figure.
#'
#' @param frames  list of scored, completed data.frames (same rows, same order — asserted, not hoped).
#' @param risk_col the PREVENT risk column name.
#' @return frames[[1]] with `risk_col` replaced by the across-imputation mean.
average_predicted_risk <- function(frames, risk_col) {
  frames <- Filter(function(d) !is.null(d) && risk_col %in% names(d), frames)
  if (!length(frames)) return(NULL)
  n <- nrow(frames[[1]])
  if (!all(vapply(frames, nrow, integer(1)) == n))
    stop("average_predicted_risk(): the imputed frames have different row counts, so averaging would
  silently align the wrong people. They come from one impute_prevent_panel() call and must match.",
         call. = FALSE)
  if ("person_id" %in% names(frames[[1]]) &&
      !all(vapply(frames, function(d) identical(d$person_id, frames[[1]]$person_id), logical(1))))
    stop("average_predicted_risk(): the imputed frames are not in the same person order.", call. = FALSE)

  out <- frames[[1]]
  out[[risk_col]] <- rowMeans(vapply(frames, function(d) as.numeric(d[[risk_col]]),
                                     numeric(n)), na.rm = TRUE)
  out
}
