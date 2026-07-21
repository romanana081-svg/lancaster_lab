# Independent cross-validation of the PREVENT equation. T-016, external gate.
#
# run_prevent() wraps AHAprevent::prevent_base -- the OFFICIAL AHA implementation (Khan group). That
# closes "did we transcribe the coefficients right?" only if AHAprevent itself is right. This file adds
# an INDEPENDENT oracle: the CRAN `preventr` package, separately authored and (per its own docs)
# validated against the AHA online PREVENT calculator. Two independent implementations agreeing across
# a grid of profiles rules out an implementation bug in either, and transitively ties our pipeline to
# the AHA calculator that `preventr` was checked against.
#
# WHAT THIS DID NOT CLOSE: a directly-cited numeric worked example from Khan 2024 (Circulation) -- the
# paper is paywalled and no open worked example with a full input profile was sourced. The two-package
# agreement is the substitute; a one-profile manual check against the AHA online calculator is the
# 2-minute human confirmation (see meeting.md S2).
#
# Both packages are off-CRAN/optional here, so these tests SKIP when either is absent rather than fail.

skip_if_no_both <- function() {
  if (!requireNamespace("AHAprevent", quietly = TRUE)) skip("AHAprevent not installed")
  if (!requireNamespace("preventr", quietly = TRUE))   skip("preventr not installed")
}

# A deterministic, diverse grid spanning every input's range (no RNG -> reproducible).
prevent_grid <- function() {
  g <- expand.grid(
    sex     = c("female", "male"),
    age     = c(30, 45, 59, 60, 79),   # 59 and 60 straddle the 30yr-window boundary on purpose
    sbp     = c(110, 140, 170),
    bp_tx   = c(FALSE, TRUE),
    total_c = c(150, 200, 260),
    hdl_c   = c(35, 55),
    statin  = c(FALSE, TRUE),
    dm      = c(FALSE, TRUE),
    smoking = c(FALSE, TRUE),
    egfr    = c(45, 75, 100),
    bmi     = c(22, 30, 38),
    stringsAsFactors = FALSE)
  g[unique(round(seq(1, nrow(g), length.out = 240))), ]   # thin to ~240 profiles, deterministically
}

aha_ascvd <- function(p) {
  r <- AHAprevent::prevent_base(
    sex = ifelse(p$sex == "female", 1L, 0L), age = p$age, tc = p$total_c, hdl = p$hdl_c,
    sbp = p$sbp, dm = as.integer(p$dm), smoking = as.integer(p$smoking), bmi = p$bmi,
    egfr = p$egfr, bptreat = as.integer(p$bp_tx), statin = as.integer(p$statin))
  c(yr10 = as.numeric(unlist(r$prevent_base_10yr_ASCVD))[1],
    yr30 = as.numeric(unlist(r$prevent_base_30yr_ASCVD))[1])
}
pr_ascvd <- function(p) {
  r <- preventr::estimate_risk(
    age = p$age, sex = p$sex, sbp = p$sbp, bp_tx = p$bp_tx, total_c = p$total_c, hdl_c = p$hdl_c,
    statin = p$statin, dm = p$dm, smoking = p$smoking, egfr = p$egfr, bmi = p$bmi, quiet = TRUE)
  c(yr10 = r$risk_est_10yr$ascvd * 100, yr30 = r$risk_est_30yr$ascvd * 100)  # proportion -> percent
}

test_that("AHAprevent and preventr agree on 10yr ASCVD to within rounding, across a diverse grid", {
  skip_if_no_both()
  g <- prevent_grid()
  worst <- 0; n <- 0
  for (i in seq_len(nrow(g))) {
    a <- aha_ascvd(g[i, ]); b <- pr_ascvd(g[i, ])
    if (is.na(a["yr10"]) || is.na(b["yr10"])) next
    worst <- max(worst, abs(a["yr10"] - b["yr10"])); n <- n + 1
  }
  expect_gt(n, 100)                       # the grid really did exercise many profiles
  # preventr reports to 0.1%, so the achievable agreement is ~0.05pp. This is the implementation gate.
  expect_lt(worst, 0.06)
})

test_that("AHAprevent and preventr agree on 30yr ASCVD wherever BOTH define it (ages 30-59)", {
  skip_if_no_both()
  g <- prevent_grid(); g <- g[g$age <= 59, ]
  worst <- 0; n <- 0
  for (i in seq_len(nrow(g))) {
    a <- aha_ascvd(g[i, ]); b <- pr_ascvd(g[i, ])
    if (is.na(a["yr30"]) || is.na(b["yr30"])) next
    worst <- max(worst, abs(a["yr30"] - b["yr30"])); n <- n + 1
  }
  expect_gt(n, 50)
  expect_lt(worst, 0.06)
})

test_that("the 30yr age boundary DIFFERS between the packages -- pinned so it can't drift silently", {
  skip_if_no_both()
  # FINDING (2026-07-21): the 30-year window is defined for ages 30-59. AHAprevent (official AHA)
  # enforces this by returning NA at age >= 60; preventr extrapolates a number up to 79. Our pipeline
  # wraps AHAprevent, so it takes the conservative/official behaviour. Primary horizon is 10yr
  # (config horizon_years: 10), so this does not touch the primary analysis -- but ADVISOR must confirm
  # the intended 30yr age range before any 30yr result is reported (meeting.md S4).
  p60 <- list(sex = "male", age = 60, sbp = 130, bp_tx = FALSE, total_c = 200, hdl_c = 50,
              statin = FALSE, dm = FALSE, smoking = FALSE, egfr = 90, bmi = 27)
  p59 <- modifyList(p60, list(age = 59))
  expect_true(is.na(aha_ascvd(p60)["yr30"]))    # AHAprevent: NA at 60
  expect_false(is.na(pr_ascvd(p60)["yr30"]))    # preventr:   number at 60
  expect_false(is.na(aha_ascvd(p59)["yr30"]))   # both define it at 59
  expect_false(is.na(pr_ascvd(p59)["yr30"]))
})
