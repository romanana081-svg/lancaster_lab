# Tests for 03_mice.R -- the abstract route.
#
# What is checked here is the counting, not the statistics: which rows are in each arm, and whether
# the N printed beside an estimate is the N the estimate was computed on. That distinction has no
# consequences on synthetic data where everybody is at risk, which is exactly why it needs a test --
# run_mice_abstract_synthetic() cannot see it, and the real cohort is where it bites.

ROOT <- file.path("..", "..")
source(file.path(ROOT, "src", "workbench", "03_mice.R"))

# A frame shaped like ascvd_status_at() output: every panel row present, prevalent and
# short-interval people KEPT with event / followup_days set to NA.
make_at_risk <- function(n = 900, n_prevalent = 240, seed = 7) {
  set.seed(seed)
  age <- round(runif(n, 40, 78))
  d <- data.frame(
    person_id = seq_len(n), age = age,
    sex     = rep(c("female", "male"), length.out = n),
    sbp     = round(rnorm(n, 130, 17)), total_c = round(rnorm(n, 195, 40)),
    hdl_c   = round(rnorm(n, 53, 14)),  bmi     = round(rnorm(n, 29, 6), 1),
    egfr    = round(pmax(20, rnorm(n, 90, 18)), 1),
    dm = runif(n) < .15, statin = runif(n) < .3, bp_tx = runif(n) < .35,
    stringsAsFactors = FALSE)
  d$smoking <- runif(n) < plogis(1.0 - 0.04 * (d$age - 40))
  d$event   <- rbinom(n, 1, plogis(-2.4 + 0.9 * d$smoking + 0.035 * (d$age - 55)))
  d$followup_days <- round(runif(n, 400, 1800))

  # The rows the estimators drop and the report used to count anyway.
  prev <- seq_len(n_prevalent)
  d$event[prev] <- NA_integer_
  d$followup_days[prev] <- NA_real_

  d$complete_panel     <- TRUE
  d$has_smoking_answer <- TRUE
  # 30% of people never answered the survey: the MICE arm's whole reason to exist.
  d$has_smoking_answer[runif(n) < 0.30] <- FALSE
  d$smoking[!d$has_smoking_answer] <- NA
  d$complete_panel_smoking <- d$has_smoking_answer
  d
}

# ---- .mice_at_risk ---------------------------------------------------------------------------

test_that(".mice_at_risk keeps exactly the rows every estimator keeps", {
  d <- data.frame(event = c(1L, 0L, NA, 0L, 1L),
                  followup_days = c(500, 900, 700, NA, -3))
  keep <- .mice_at_risk(d)
  # NA event (prevalent / short-interval), NA follow-up, and negative follow-up all go.
  expect_equal(nrow(keep), 2L)
  expect_equal(keep$event, c(1L, 0L))
})

test_that(".mice_at_risk is the same rule prevent_concordance uses", {
  skip_if_not(file.exists(file.path(ROOT, "src", "figures", "prevent_calibration.R")))
  src <- readLines(file.path(ROOT, "src", "figures", "prevent_calibration.R"))
  # If the estimator's filter is ever changed, this test is the thing that notices: the arms and the
  # estimates would otherwise drift apart silently, and only the printed N would be wrong.
  expect_true(any(grepl("!is.na(at_risk$event)", src, fixed = TRUE)))
  expect_true(any(grepl("at_risk$followup_days >= 0", src, fixed = TRUE)))
})

# ---- .mice_require_arms ----------------------------------------------------------------------

test_that("an empty MICE arm with no panel rows blames the landmark", {
  empty <- make_at_risk(300, n_prevalent = 0)[0, ]
  expect_error(.mice_require_arms(empty, empty, empty, empty, as.Date("2016-01-01")),
               "MICE arm is empty")
  expect_error(.mice_require_arms(empty, empty, empty, empty, as.Date("2016-01-01")),
               "as of the 2016-01-01 landmark", fixed = TRUE)
})

test_that("an empty MICE arm WITH panel rows blames prevalence, not the landmark", {
  d <- make_at_risk(200, n_prevalent = 200)      # everyone prevalent: panel rows exist, none at risk
  at <- .mice_at_risk(d)
  expect_equal(nrow(at), 0L)
  err <- expect_error(.mice_require_arms(at, at, d, d, as.Date("2019-01-01")))
  expect_match(conditionMessage(err), "none of them is at risk", fixed = TRUE)
  expect_false(grepl("check choose_landmark", conditionMessage(err), fixed = TRUE))
})

test_that("an empty complete-case arm points at attach_smoking_status", {
  d  <- make_at_risk(300, n_prevalent = 0)
  mi <- .mice_at_risk(d)
  cc <- mi[0, ]
  err <- expect_error(.mice_require_arms(cc, mi, cc, d, as.Date("2019-01-01")))
  expect_match(conditionMessage(err), "complete-case arm is empty", fixed = TRUE)
  expect_match(conditionMessage(err), "attach_smoking_status = TRUE", fixed = TRUE)
})

test_that("both arms populated passes silently", {
  d <- make_at_risk()
  cc <- .mice_at_risk(d[d$complete_panel_smoking, ])
  mi <- .mice_at_risk(d)
  expect_silent(.mice_require_arms(cc, mi, d[d$complete_panel_smoking, ], d, as.Date("2019-01-01")))
})

# ---- the reported N is the analysed N --------------------------------------------------------

test_that("the report and the abstract quote the at-risk N, not the panel N", {
  skip_if_not_installed("mice")
  skip_if_not_installed("AHAprevent")
  skip_if_not_installed("survival")
  skip_if_not(file.exists(file.path(ROOT, "src", "figures", "survival_curves.R")))

  # mice_abstract_from_frame() and its dependencies resolve paths from the repo root.
  old <- setwd(ROOT); on.exit(setwd(old), add = TRUE)
  source("src/figures/survival_curves.R"); source_survival_deps(quiet = TRUE)
  source("src/figures/prevent_calibration.R")
  source("src/phenotype/R/impute_panel.R")
  source("src/ascvd/validation/paper_tables.R")
  source("src/ascvd/validation/pooled_validation.R")
  source("src/workbench/03_mice.R")

  d <- make_at_risk(900, n_prevalent = 240)
  d <- run_prevent(d)
  out_dir <- file.path(tempdir(), "mice_n_test")
  res <- suppressMessages(suppressWarnings(
    mice_abstract_from_frame(d, landmark = as.Date("2019-01-01"),
                             end_of_followup = as.Date("2024-01-01"), m = 2, horizon_years = 3,
                             figdir = file.path(out_dir, "figures"), repdir = out_dir,
                             seed = 1L, copy_to_bucket = FALSE)))

  n_panel_mice <- nrow(d)                                   # 900
  n_at_risk    <- sum(!is.na(d$event))                      # 660
  expect_true(n_at_risk < n_panel_mice)

  rep_txt <- readLines(res$paths$report)
  n_line  <- grep("at-risk N (the analysis sample)", rep_txt, value = TRUE, fixed = TRUE)
  expect_length(n_line, 1L)
  expect_match(n_line, format(n_at_risk, big.mark = ","), fixed = TRUE)
  expect_false(grepl(format(n_panel_mice, big.mark = ","), n_line, fixed = TRUE))

  # The pre-filter count is still REPORTED -- dropping people silently is the other failure mode.
  expect_match(grep("^  panel rows", rep_txt, value = TRUE)[1],
               format(n_panel_mice, big.mark = ","), fixed = TRUE)

  # And the sentence a reader copies into the abstract carries the same number.
  abs_txt <- readLines(res$paths$abstract)
  quoted  <- grep("increased the analytic sample to", abs_txt, value = TRUE)
  expect_length(quoted, 1L)
  expect_match(quoted, format(n_at_risk, big.mark = ","), fixed = TRUE)
})
