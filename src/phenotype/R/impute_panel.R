# impute_panel.R — multiple imputation by chained equations (MICE) for the missing PREVENT inputs.
#
# WORKBENCH (you almost certainly want src/workbench/03_mice.R, not this file directly):
#   install.packages("mice")            # once per instance
#   source("src/phenotype/R/impute_panel.R")
#   imp <- impute_prevent_panel(at_risk, vars = "smoking", m = 5)
#   imp$completed[[1]]                  # one completed copy of the frame, smoking filled in
#
# ------------------------------------------------------------------------------------------------
# WHY THIS EXISTS
#
# The validation cohort is not limited by lipids or by creatinine. It is limited by SMOKING, which is
# survey-derived: on the 2026-07-21 real run only 39.8% of people with an otherwise-complete PREVENT
# panel had a usable smoking answer (216,167 -> 84,176). Under the complete-case rule the other 60%
# are discarded, and they are not discarded at random — survey completion tracks engagement, which
# tracks age, education and health. So complete-case analysis here is not the conservative option; it
# is a choice with its own bias, made silently.
#
# MICE fills those gaps by drawing each missing value from a model fitted to everyone who DOES have
# it, repeating that m times so the extra uncertainty from not knowing shows up as between-imputation
# variance rather than disappearing. Pooling happens in pooled_validation.R (Rubin's rules).
#
# ------------------------------------------------------------------------------------------------
# THE THREE THINGS THAT MAKE THIS VALID RATHER THAN DECORATIVE
#
# 1. THE OUTCOME MUST BE IN THE IMPUTATION MODEL. This is the classic mistake and it is invisible.
#    Imputing smoking from age/BP/lipids ALONE makes imputed smoking independent of who had an event,
#    conditional on those. Every imputed person then dilutes the smoking-outcome association toward
#    the null, and the C-statistic — the number the abstract is about — is biased DOWNWARD. You would
#    conclude PREVENT discriminates worse in All of Us than it does, and the cause would be our
#    imputation, not the equation. So the outcome enters as White & Royston's (2009) pair: the event
#    indicator AND the Nelson-Aalen cumulative hazard at each person's follow-up time. Using the raw
#    survival TIME instead is the well-documented wrong version of this fix.
#
# 2. ONLY THE NAMED GAPS GET FILLED. Every other PREVENT input has to be observed; rows missing one
#    are dropped and COUNTED, not quietly imputed. Imputing five of six measurements for one person
#    does not recover their risk, it invents a population-average person and then scores them — which
#    inflates N while adding no information and flattening the risk distribution. The default
#    `vars = "smoking"` is therefore the honest primary analysis: fill the survey gap, require the
#    labs. Widening `vars` is a sensitivity analysis and should be reported as one.
#
# 3. THE IMPUTATION IS OF INPUTS, NEVER OF RISK. We impute smoking and then re-run the published
#    PREVENT equation unchanged on each completed dataset. At no point is a risk score itself imputed,
#    averaged into existence, or refitted — this is an external validation, and the equation's
#    coefficients are not ours to touch (D-020 scope).
#
# WHAT MICE CANNOT FIX: this assumes values are missing at random GIVEN the variables in the model. If
# people conceal smoking in a way unrelated to anything else we measured, that is MNAR and no
# imputation recovers it. Say so in the limitations; do not let "we used MICE" read as "we solved it".
# ------------------------------------------------------------------------------------------------

# The variables that go into the imputation model. Deliberately exactly the PREVENT input set: these
# are the quantities that predict each other, and adding unrelated columns (person_id, dates, the
# placeholder_inputs string) is how a mice() call becomes a twenty-minute one that then fails.
.PREVENT_MICE_VARS <- c("age", "sex", "sbp", "total_c", "hdl_c", "egfr", "bmi",
                        "dm", "statin", "bp_tx", "smoking")

#' Centre and scale to unit variance, leaving a constant vector alone (dividing it by sd = 0 would
#' turn a harmless constant into NaN and take the whole imputation model with it).
.scale1 <- function(x) {
  s <- stats::sd(x, na.rm = TRUE)
  if (!is.finite(s) || s == 0) return(x)
  (x - mean(x, na.rm = TRUE)) / s
}

#' Nelson-Aalen cumulative hazard evaluated at each person's own follow-up time.
#'
#' This is the "outcome" that belongs in a survival imputation model (White & Royston 2009). It is a
#' monotone summary of the event history, so including it lets the imputation model learn "people who
#' reached this time still event-free look like X" — precisely the information that keeps the
#' covariate-outcome association intact through imputation.
#'
#' NOT the raw time, and not the event indicator on its own: either alone is the documented wrong
#' version and biases the association in a direction nobody notices.
#'
#' @return numeric vector, same length as `time`; 0 where the curve is too degenerate to interpolate
#'   (a fixture-sized run), which makes it a harmless constant rather than an error. NA where `time`
#'   or `event` was NA, since those rows are not in the at-risk set at all.
nelson_aalen_hazard <- function(time, event) {
  if (!requireNamespace("survival", quietly = TRUE)) stop("install.packages('survival')")
  ok  <- !is.na(time) & !is.na(event) & time >= 0
  out <- rep(NA_real_, length(time))
  if (sum(ok) < 2L) return(replace(out, ok, 0))
  fit <- survival::survfit(survival::Surv(time[ok], event[ok]) ~ 1)
  # survfit carries the Nelson-Aalen estimate directly in modern `survival`; -log(surv) (the
  # Fleming-Harrington form) is the fallback and agrees to within the usual second-order difference.
  H <- if (!is.null(fit$cumhaz)) as.numeric(fit$cumhaz)
       else -log(pmax(as.numeric(fit$surv), .Machine$double.eps))
  if (length(fit$time) < 2L) return(replace(out, ok, 0))
  # Step interpolation with rule = 2: a person censored before the first event time gets H = 0, one
  # beyond the last gets the final H. That is what a cumulative hazard means at those times.
  out[ok] <- stats::approx(as.numeric(fit$time), H, xout = time[ok],
                           method = "constant", rule = 2, f = 0)$y
  out
}

#' Multiply impute the named PREVENT inputs of a frame.
#'
#' @param frame  an at-risk frame (extract_prevent_panel() output, put through ascvd_status_at() so
#'   `event` / `followup_days` exist). Extra columns are carried through untouched — only `vars` are
#'   ever modified.
#' @param vars  which inputs to impute. DEFAULT "smoking", the binding constraint. Anything else in
#'   the PREVENT input set must be observed, or the row is dropped and counted (see point 2 above).
#' @param m  number of imputed datasets. 5 is the conventional default and is ample when the estimands
#'   are a C-statistic and a slope; raise it when the fraction of missing information is large (the
#'   pooling step reports FMI, so you can check rather than guess).
#' @param maxit  chained-equations iterations. 5 is mice's default and converges immediately when only
#'   one variable is imputed, because there is then no chain to converge.
#' @param seed  fixed, so the run is reproducible. Quote the number in the methods section.
#' @param use_outcome  include the event indicator and Nelson-Aalen hazard. TRUE, and you should have
#'   a specific reason to change it — point 1 above says what turning it off silently costs.
#' @return list(
#'   completed  : list of `m` data.frames, each a copy of the KEPT rows of `frame`, `vars` filled;
#'   m, vars, seed, used_outcome,
#'   n_in, n_kept, n_dropped, dropped_reason,
#'   missing_before : named integer vector — how many values of each `vars` were missing;
#'   method         : the mice method actually used per variable;
#'   mids           : the raw mice object, for convergence plots — plot(imp$mids))
impute_prevent_panel <- function(frame, vars = "smoking", m = 5, maxit = 5,
                                 seed = 20260901L, use_outcome = TRUE, quiet = FALSE) {
  if (!requireNamespace("mice", quietly = TRUE))
    stop("impute_prevent_panel(): the `mice` package is not installed in this R session.
  In the Workbench:  install.packages(\"mice\")
  It is a CRAN package with no system dependencies, so this normally just works.", call. = FALSE)
  stopifnot(is.data.frame(frame), m >= 1, maxit >= 1)

  miss_col <- setdiff(vars, names(frame))
  if (length(miss_col))
    stop(sprintf("impute_prevent_panel(): frame has no column(s) %s.",
                 paste(miss_col, collapse = ", ")), call. = FALSE)

  aux   <- intersect(.PREVENT_MICE_VARS, names(frame))
  other <- setdiff(aux, vars)

  # --- who can be imputed at all -----------------------------------------------------------------
  # Everything OUTSIDE `vars` must be observed. Dropped rows are counted and returned, never absorbed:
  # an N that grew for an unexplained reason is worse than a smaller N.
  keep   <- stats::complete.cases(frame[, other, drop = FALSE])
  reason <- sprintf("missing a non-imputed PREVENT input (%s)", paste(other, collapse = ", "))

  if (isTRUE(use_outcome)) {
    if (!all(c("event", "followup_days") %in% names(frame)))
      stop("impute_prevent_panel(): use_outcome = TRUE needs `event` and `followup_days`. Pass the
  at-risk frame from ascvd_status_at(), not the raw panel. (use_outcome = FALSE would run, and would
  bias the C-statistic downward — see the header, point 1.)", call. = FALSE)
    keep   <- keep & !is.na(frame$event) & !is.na(frame$followup_days) & frame$followup_days >= 0
    reason <- paste(reason, "or not in the at-risk set (prevalent / excluded / no follow-up)")
  }

  n_in <- nrow(frame)
  sub  <- frame[keep, , drop = FALSE]
  if (!nrow(sub))
    stop(sprintf("impute_prevent_panel(): every one of the %d rows was dropped — %s.
  Nothing to impute. Check that you passed the at-risk frame, and that the measurements really are
  present (a code list that resolved to nothing makes a whole input NA for everyone, with no error).",
                 n_in, reason), call. = FALSE)

  missing_before <- vapply(vars, function(v) sum(is.na(sub[[v]])), integer(1))
  if (all(missing_before == 0L))
    message("impute_prevent_panel(): nothing is missing in ", paste(vars, collapse = ", "),
            " among the kept rows — the imputed datasets will be identical copies. That is a valid ",
            "result, not a failure; report it as complete data.")

  # --- build the modelling frame -----------------------------------------------------------------
  # mice needs factors for its binary models. Logical columns are converted here and converted BACK on
  # the way out, so the rest of the pipeline (run_prevent() casts with as.integer()) never sees a
  # factor where it expects a logical.
  mdat   <- sub[, aux, drop = FALSE]
  is_lgl <- vapply(mdat, is.logical, logical(1))
  for (nm in names(mdat)[is_lgl]) mdat[[nm]] <- factor(mdat[[nm]], levels = c(FALSE, TRUE))
  if ("sex" %in% names(mdat)) mdat$sex <- factor(as.character(mdat$sex))

  if (isTRUE(use_outcome)) {
    # STANDARDISE BOTH, and this is load-bearing rather than tidiness. mice's remove.lindep() drops
    # any predictor whose variance is below eps = 1e-4, silently, once per variable per iteration per
    # imputation. At realistic ASCVD event rates the Nelson-Aalen cumulative hazard lives on 0..0.05,
    # so its variance is ~1e-5 and it was being removed from EVERY imputation model — leaving the
    # outcome represented by the event indicator alone, which is the documented wrong version of this
    # fix (see the header, point 1) and produces no error, no warning, and a C-statistic biased down.
    # Caught on the synthetic run only because loggedEvents was read. Scaling is a linear transform,
    # so a GLM's coefficients absorb it exactly: nothing is lost, and the variance floor is cleared.
    mdat$.cumhaz <- .scale1(nelson_aalen_hazard(sub$followup_days, sub$event))
    mdat$.event  <- .scale1(as.integer(sub$event))
  }

  # A target with no observed values, or a binary target seen at only one level, cannot be modelled.
  # mice's own message for this is opaque and the cause is almost always an upstream extractor that
  # returned nothing — so name that here rather than let it surface as a linear-algebra error.
  for (v in vars) {
    obs <- mdat[[v]][!is.na(mdat[[v]])]
    if (!length(obs))
      stop(sprintf("impute_prevent_panel(): `%s` is missing for ALL %d kept rows, so there is nothing
  to learn an imputation model from. That is an extraction failure, not an imputation problem — for
  smoking, check that extract_smoking() found the survey question (sql/03).", v, nrow(sub)),
           call. = FALSE)
    if (is.factor(mdat[[v]]) && length(unique(as.character(obs))) < 2L)
      stop(sprintf("impute_prevent_panel(): `%s` takes only ONE observed value (%s) among the kept
  rows. A binary imputation model cannot be fitted, and if it could it would assign that same value to
  everybody. Check the extractor's answer mapping before imputing.",
                   v, unique(as.character(obs))[1]), call. = FALSE)
  }

  meth <- mice::make.method(mdat)
  # Impute ONLY the named targets. Everything else is blanked to "" so a stray NA elsewhere can never
  # be filled behind our back — with `other` already complete this is belt-and-braces, and it is the
  # brace that keeps `vars` meaning what the methods section says it means.
  meth[setdiff(names(meth), vars)] <- ""
  for (v in vars)
    meth[[v]] <- if (is.factor(mdat[[v]]))
                   (if (nlevels(droplevels(mdat[[v]])) > 2L) "polyreg" else "logreg")
                 else "pmm"   # predictive mean matching draws an OBSERVED value, so an imputed SBP is
                              # always a real SBP that someone had, never 214.7 from a normal tail.

  mids <- mice::mice(mdat, m = m, method = meth,
                     predictorMatrix = mice::make.predictorMatrix(mdat),
                     maxit = maxit, seed = seed, printFlag = !quiet)

  # --- put the imputed values back on the ORIGINAL frame ------------------------------------------
  completed <- lapply(seq_len(m), function(i) {
    ci  <- mice::complete(mids, i)
    out <- sub
    for (v in vars)
      out[[v]] <- if (is.logical(sub[[v]])) as.logical(as.character(ci[[v]]))
                  else if (is.factor(ci[[v]])) as.character(ci[[v]])
                  else ci[[v]]
    out
  })

  # --- did the outcome actually survive into the imputation models? -------------------------------
  # Asking the predictorMatrix is NOT enough: it records what was REQUESTED, and mice can still drop a
  # column at fit time (collinearity, or the variance floor that bit .cumhaz above). The only honest
  # record is loggedEvents. This is checked rather than assumed because the failure is invisible in
  # every output — the imputations look fine, the pooling looks fine, and only the C-statistic moves.
  le <- mids$loggedEvents
  outcome_dropped <- if (isTRUE(use_outcome) && !is.null(le) && nrow(le))
                       unique(le$out[le$out %in% c(".cumhaz", ".event")]) else character(0)
  if (length(outcome_dropped))
    warning(sprintf("impute_prevent_panel(): mice DROPPED %s from the imputation model(s).
  The outcome is then under-represented and the pooled C-statistic is biased DOWNWARD — see the
  header, point 1. Inspect imp$mids$loggedEvents for the reason (usually collinearity with another
  predictor). Do NOT report the C-statistic as an unbiased estimate until this is resolved.",
                    paste(outcome_dropped, collapse = " and ")), call. = FALSE)

  # WHICH values were imputed, aligned to the kept rows. Returned rather than recomputed downstream:
  # once `completed` is filled there is no way to tell an imputed value from an observed one, and the
  # observed-vs-imputed diagnostic — the one a reviewer asks for — depends entirely on knowing.
  missing_mask <- lapply(vars, function(v) is.na(sub[[v]]))
  names(missing_mask) <- vars

  list(completed = completed, mids = mids, m = m, vars = vars, seed = seed,
       used_outcome = isTRUE(use_outcome),
       n_in = n_in, n_kept = nrow(sub), n_dropped = n_in - nrow(sub), dropped_reason = reason,
       missing_before = missing_before, missing_mask = missing_mask,
       outcome_dropped = outcome_dropped, logged_events = le,
       method = vapply(vars, function(v) as.character(meth[[v]]), character(1)))
}
