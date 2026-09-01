# Tests for the MICE half: impute_panel.R and pooled_validation.R.
#
# These are deterministic and offline. The Workbench path (03_mice.R) is exercised end-to-end by
# run_mice_abstract_synthetic(), which needs AHAprevent; what is checked here is everything that can
# be checked without it, which is most of what can go quietly wrong.

source(file.path("..", "..", "src", "phenotype", "R", "impute_panel.R"))
source(file.path("..", "..", "src", "ascvd", "validation", "pooled_validation.R"))

# A cohort where smoking genuinely predicts the event and is missing at random given age. Both
# properties matter: without the first there is no association for imputation to preserve or destroy.
make_frame <- function(n = 1200, seed = 42, miss = 0.4) {
  set.seed(seed)
  age <- round(runif(n, 40, 78))
  d <- data.frame(
    person_id = seq_len(n), age = age,
    sex     = rep(c("female", "male"), length.out = n),
    sbp     = rnorm(n, 128, 17), total_c = rnorm(n, 192, 40), hdl_c = rnorm(n, 53, 15),
    bmi     = rnorm(n, 29, 6),   egfr    = rnorm(n, 92, 18),
    dm = runif(n) < .15, statin = runif(n) < .3, bp_tx = runif(n) < .35,
    stringsAsFactors = FALSE)
  d$smoking <- runif(n) < plogis(1.0 - 0.04 * (d$age - 40))
  d$event   <- rbinom(n, 1, plogis(-3.2 + 0.9 * d$smoking + 0.03 * (d$age - 55)))
  d$followup_days <- round(runif(n, 400, 1800))
  d$smoking[runif(n) < miss] <- NA
  d
}

# ---- nelson_aalen_hazard --------------------------------------------------------------------------

test_that("nelson_aalen_hazard is non-decreasing in time and finite", {
  set.seed(1)
  t <- round(runif(400, 30, 2000)); e <- rbinom(400, 1, 0.15)
  h <- nelson_aalen_hazard(t, e)
  expect_equal(length(h), length(t))
  expect_true(all(is.finite(h)))
  expect_true(all(h >= 0))
  # A cumulative hazard can only go up with time, so ordering by time must order the hazard too.
  o <- order(t)
  expect_false(is.unsorted(round(h[o], 10)))
})

test_that("nelson_aalen_hazard returns NA for rows with no follow-up, not 0", {
  h <- nelson_aalen_hazard(c(100, NA, 300, 400), c(1, 1, NA, 0))
  expect_true(is.na(h[2]) && is.na(h[3]))
  expect_true(all(is.finite(h[c(1, 4)])))
})

test_that("nelson_aalen_hazard degrades to a constant rather than erroring on a tiny sample", {
  expect_true(all(nelson_aalen_hazard(c(10), c(1)) == 0 | is.na(nelson_aalen_hazard(c(10), c(1)))))
  expect_silent(nelson_aalen_hazard(numeric(0), numeric(0)))
})

# ---- rubin_pool -----------------------------------------------------------------------------------

test_that("rubin_pool recovers the point estimate and widens the interval beyond the naive one", {
  est <- c(0.70, 0.74, 0.72, 0.76, 0.68); se <- rep(0.03, 5)
  p <- rubin_pool(est, se)
  expect_equal(p$est, mean(est))
  # Total variance must exceed the average within-imputation variance whenever the estimates differ:
  # that difference IS the cost of not knowing, and dropping it is the mistake this guards.
  expect_gt(p$se^2, mean(se^2))
  expect_gt(p$upper - p$lower, 2 * 1.96 * mean(se))
  expect_gt(p$fmi, 0); expect_lt(p$fmi, 1)
})

test_that("rubin_pool matches a hand-computed total variance", {
  est <- c(1, 2, 3); se <- c(1, 1, 1)
  p <- rubin_pool(est, se)
  b <- var(est)                       # 1
  expect_equal(p$var_between, b)
  expect_equal(p$var_within, 1)
  expect_equal(p$se^2, 1 + (1 + 1 / 3) * b)
})

test_that("rubin_pool handles the two degenerate ends without producing NaN", {
  one <- rubin_pool(0.7, 0.05)                       # m = 1: no between-imputation variance
  expect_equal(one$est, 0.7); expect_equal(one$var_between, 0)
  expect_true(is.finite(one$lower) && is.finite(one$upper))

  same <- rubin_pool(rep(0.7, 5), rep(0.05, 5))      # identical estimates: imputation added nothing
  expect_equal(same$var_between, 0)
  expect_equal(same$fmi, 0)
  expect_true(is.finite(same$lower))
})

test_that("rubin_pool drops non-finite inputs rather than propagating them", {
  p <- rubin_pool(c(0.7, NA, 0.8, Inf), c(0.05, 0.05, 0.05, 0.05))
  expect_equal(p$m, 2)
  expect_equal(p$est, 0.75)
})

# ---- pooling the metrics --------------------------------------------------------------------------

test_that("pool_concordance keeps the interval inside [0,1] even near the boundary", {
  # Pooling on the raw scale would put the upper bound above 1 here, which cannot be printed.
  cl <- lapply(1:5, function(i)
    data.frame(stratum = "female", n = 900, events = 60,
               c_index = 0.96 + i * 0.004, se = 0.03, stringsAsFactors = FALSE))
  p <- pool_concordance(cl)
  expect_true(p$upper < 1 && p$lower > 0)
  expect_true(p$c_index > 0.95 && p$c_index < 1)
})

test_that("pool_concordance counts how many imputations actually contributed", {
  cl <- list(data.frame(stratum = "male", n = 100, events = 30, c_index = 0.7, se = 0.04),
             NULL,                                        # too few events to score
             data.frame(stratum = "male", n = 100, events = 30, c_index = 0.74, se = 0.04))
  p <- pool_concordance(cl)
  expect_equal(p$m_used, 2)
  expect_equal(p$m_requested, 3)
})

test_that("pool_calibration_slope pools on the natural scale and can cross 1", {
  sl <- lapply(c(0.8, 1.0, 1.2, 0.9, 1.1), function(s)
    data.frame(stratum = "all", slope = s, se = 0.15, n = 500, events = 40))
  p <- pool_calibration_slope(sl)
  expect_equal(p$slope, 1.0)
  expect_lt(p$lower, 1); expect_gt(p$upper, 1)
})

test_that("average_predicted_risk refuses to average misaligned frames", {
  a <- data.frame(person_id = 1:3, risk10 = c(1, 2, 3))
  b <- data.frame(person_id = 1:2, risk10 = c(1, 2))
  expect_error(average_predicted_risk(list(a, b), "risk10"), "different row counts")
  c2 <- data.frame(person_id = c(3, 2, 1), risk10 = c(3, 2, 1))
  expect_error(average_predicted_risk(list(a, c2), "risk10"), "same person order")
  expect_equal(average_predicted_risk(list(a, a), "risk10")$risk10, c(1, 2, 3))
})

# ---- impute_prevent_panel -------------------------------------------------------------------------

test_that("imputation fills every gap and leaves observed values untouched", {
  skip_if_not_installed("mice")
  d   <- make_frame()
  obs <- !is.na(d$smoking)
  imp <- impute_prevent_panel(d, m = 3, maxit = 2, quiet = TRUE)

  expect_equal(length(imp$completed), 3)
  for (cd in imp$completed) {
    expect_false(any(is.na(cd$smoking)))
    expect_type(cd$smoking, "logical")                 # logical in, logical out — not a factor
    expect_equal(cd$smoking[obs], d$smoking[obs])      # observed values are never overwritten
  }
  expect_equal(unname(imp$missing_before[["smoking"]]), sum(is.na(d$smoking)))
  expect_equal(imp$method[["smoking"]], "logreg")
})

test_that("the imputations differ from each other — otherwise pooling is theatre", {
  skip_if_not_installed("mice")
  imp <- impute_prevent_panel(make_frame(), m = 3, maxit = 2, quiet = TRUE)
  expect_false(identical(imp$completed[[1]]$smoking, imp$completed[[2]]$smoking))
})

test_that("REGRESSION: the outcome terms survive into the imputation model", {
  # mice's remove.lindep() drops any predictor with variance < 1e-4, and an unscaled Nelson-Aalen
  # cumulative hazard at a realistic event rate sits at ~1e-5. It was silently removed from every
  # model, leaving the outcome represented by the event indicator alone and biasing pooled C
  # downward with no error and no warning. Fixed by standardising both terms; this is the guard.
  skip_if_not_installed("mice")
  imp <- impute_prevent_panel(make_frame(n = 2000, miss = 0.35), m = 3, maxit = 3, quiet = TRUE)
  expect_length(imp$outcome_dropped, 0)
  expect_true(imp$used_outcome)
  pm <- imp$mids$predictorMatrix
  expect_true(all(c(".cumhaz", ".event") %in% names(which(pm["smoking", ] == 1))))
})

test_that("the missing_mask lines up with the completed frames", {
  skip_if_not_installed("mice")
  d   <- make_frame()
  imp <- impute_prevent_panel(d, m = 2, maxit = 2, quiet = TRUE)
  expect_equal(length(imp$missing_mask$smoking), nrow(imp$completed[[1]]))
  expect_equal(sum(imp$missing_mask$smoking), unname(imp$missing_before[["smoking"]]))
})

test_that("rows missing a NON-imputed input are dropped and counted, never imputed", {
  skip_if_not_installed("mice")
  d <- make_frame()
  d$sbp[1:50] <- NA                                    # not in `vars`, so these rows must go
  imp <- impute_prevent_panel(d, vars = "smoking", m = 2, maxit = 2, quiet = TRUE)
  expect_equal(imp$n_dropped, 50)
  expect_equal(imp$n_kept, nrow(d) - 50)
  expect_false(any(is.na(imp$completed[[1]]$sbp)))     # dropped, not filled
})

test_that("people with no follow-up are excluded when the outcome is in the model", {
  skip_if_not_installed("mice")
  d <- make_frame()
  d$event[1:40] <- NA                                  # prevalent / excluded — not at risk
  imp <- impute_prevent_panel(d, m = 2, maxit = 2, quiet = TRUE)
  expect_equal(imp$n_kept, nrow(d) - 40)
})

test_that("a target that is missing for everyone is a named error, not a mice stack trace", {
  skip_if_not_installed("mice")
  d <- make_frame(); d$smoking <- NA
  expect_error(impute_prevent_panel(d, m = 2, quiet = TRUE), "missing for ALL")
})

test_that("a target observed at only one level is a named error", {
  skip_if_not_installed("mice")
  d <- make_frame()
  d$smoking[!is.na(d$smoking)] <- FALSE
  expect_error(impute_prevent_panel(d, m = 2, quiet = TRUE), "only ONE observed value")
})

test_that("use_outcome = TRUE demands the at-risk frame and says so", {
  skip_if_not_installed("mice")
  d <- make_frame(); d$event <- NULL; d$followup_days <- NULL
  expect_error(impute_prevent_panel(d, m = 2, quiet = TRUE), "ascvd_status_at")
})

test_that("imputing with the outcome preserves the smoking-event association better than without", {
  # The reason the outcome is in the model at all. Omitting it makes imputed smoking conditionally
  # independent of the event, which attenuates the association toward the null — the bias that would
  # show up as PREVENT discriminating worse in All of Us than it really does.
  skip_if_not_installed("mice")
  d      <- make_frame(n = 3000, seed = 7, miss = 0.5)
  or_of  <- function(cd) {
    tb <- table(cd$smoking, cd$event)
    (tb["TRUE", "1"] * tb["FALSE", "0"]) / (tb["TRUE", "0"] * tb["FALSE", "1"])
  }
  with_o <- impute_prevent_panel(d, m = 5, maxit = 3, quiet = TRUE, seed = 11)
  no_o   <- suppressWarnings(
              impute_prevent_panel(d, m = 5, maxit = 3, quiet = TRUE, seed = 11,
                                   use_outcome = FALSE))
  or_with <- mean(vapply(with_o$completed, or_of, numeric(1)))
  or_none <- mean(vapply(no_o$completed,  or_of, numeric(1)))
  # Both are estimates of the same true OR (~exp(0.9) = 2.46); the one that used the outcome must be
  # the less attenuated of the two, i.e. further from the null of 1.
  expect_gt(or_with, or_none)
  expect_gt(or_with, 1.5)
})
