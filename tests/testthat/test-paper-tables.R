# Tests for the paper-comparable tables (src/ascvd/validation/paper_tables.R).
#
# Two things are being defended here and they fail in different ways:
#
#   1. THE TRANSCRIPTION. Table 1 and Table 4 were typed in by hand from the PMC copy. The defence is
#      arithmetic: the sex-split rows must add to the totals that were transcribed into config.yaml
#      weeks earlier from the abstract, and the Table 4 C-statistics must equal the ones transcribed
#      separately. A typo that survives all of those is a typo in two independent readings.
#
#   2. THE COMPUTATION. The calibration slope and the unit conversion are where a silent wrong answer
#      is easiest: a slope fitted against the WRONG axis (10-year predicted vs horizon observed) still
#      returns a plausible-looking number, and mg/dL read as mmol/L makes our cohort look
#      hypercholesterolaemic by a factor of 39. Both are pinned to values computed by hand.

source(test_path("..", "..", "src", "ascvd", "validation", "literature_benchmarks.R"))
source(test_path("..", "..", "src", "ascvd", "validation", "paper_tables.R"))

# The synthetic calibration points below are exactly collinear, so lm() warns "essentially perfect
# fit". That is a statement about the TEST DATA, not about the function -- and fourteen copies of it
# would bury a warning that mattered. Exactness is worth keeping: it is what lets the assertions name
# 0.5 and 1.0 rather than "about 0.5".
quiet_fit <- function(expr) suppressWarnings(expr)

test_that("Table 1 transcription adds up to the totals transcribed from the abstract", {
  ref <- paper_table1_reference()
  lit <- read_literature_config()
  tot <- function(key, cols)
    sum(ref$value1[ref$key == key & ref$column %in% cols])

  d_cols <- c("derivation_female", "derivation_male")
  v_cols <- c("validation_female", "validation_male")

  # These are the six checks the config comment promises. They compare Table 1 (typed in 2026-08-06)
  # against the abstract figures (typed in weeks earlier), so agreement means two readings agree.
  expect_equal(tot("n_participants", d_cols), lit$prevent_paper$derivation$n_participants)
  expect_equal(tot("n_participants", v_cols), lit$prevent_paper$validation$n_participants)
  expect_equal(tot("events_cvd",     d_cols), lit$prevent_paper$derivation$events_cvd)
  expect_equal(tot("events_cvd",     v_cols), lit$prevent_paper$validation$events_cvd)
  expect_equal(tot("events_ascvd",   d_cols), lit$prevent_paper$derivation$events_ascvd)
  expect_equal(tot("events_ascvd",   v_cols), lit$prevent_paper$validation$events_ascvd)

  # And the grand total from the abstract, which is the number a reader is most likely to check.
  expect_equal(tot("n_participants", c(d_cols, v_cols)), 6612004)
})

test_that("Table 4's ASCVD C-statistics match the independently transcribed ones", {
  ref <- paper_table4_reference("ascvd")
  c_ref <- read_literature_config()$prevent_paper$c_statistic_ascvd
  expect_equal(ref$c_statistic[ref$sex == "female"], c_ref$female)
  expect_equal(ref$c_statistic[ref$sex == "male"],   c_ref$male)

  # The IQI must bracket the estimate. A transposed pair (lo > hi) is the classic transcription slip
  # and prints without complaint.
  expect_true(all(ref$c_iqi_lo <= ref$c_statistic & ref$c_statistic <= ref$c_iqi_hi))
  expect_true(all(ref$slope_iqi_lo <= ref$slope & ref$slope <= ref$slope_iqi_hi))

  # The PCE comparison is the ruler the slope column is read against; if it ever goes missing the
  # table still prints, so assert it is there.
  expect_true(all(is.finite(ref$pce_c)), info = "PCE C-statistics missing from config")
  expect_true(all(ref$pce_slope < 0.7), info = "PCE slopes should be the badly-calibrated end (~0.5)")
})

test_that("all three outcomes are transcribed, not just ours", {
  for (o in c("ascvd", "cvd", "hf")) {
    r <- paper_table4_reference(o)
    expect_equal(nrow(r), 2L, info = o)
    expect_true(all(r$c_statistic > 0.5 & r$c_statistic < 1), info = o)
  }
  # HF discriminates best in the paper; ASCVD worst. If an edit shuffles rows between outcomes, this
  # ordering breaks before anyone notices the numbers moved.
  expect_gt(paper_table4_reference("hf")$c_statistic[1],
            paper_table4_reference("ascvd")$c_statistic[1])
})

test_that("calibration_slope recovers a slope it was given", {
  # Observed is exactly half of predicted: a perfectly linear, badly calibrated model. Slope 0.5,
  # intercept 0, R^2 1.
  d <- data.frame(stratum = "all", group = 1:10, n = 100, events = 30,
                  predicted_horizon = seq(1, 10), observed_pct = seq(1, 10) * 0.5)
  s <- quiet_fit(calibration_slope(d))
  expect_equal(s$slope, 0.5, tolerance = 1e-8)
  expect_equal(s$intercept, 0, tolerance = 1e-8)
  expect_equal(s$r_squared, 1, tolerance = 1e-8)
  expect_equal(s$n, 1000)

  # A perfectly calibrated model gives 1.0 — the value the paper's column is read against.
  d$observed_pct <- d$predicted_horizon
  expect_equal(quiet_fit(calibration_slope(d))$slope, 1, tolerance = 1e-8)
})

test_that("calibration_slope fits within sex, not across it", {
  # Women well calibrated, men over-predicted by half. A pooled fit would return something in
  # between and hide both, which is exactly why the paper reports it sex-specific.
  d <- rbind(
    data.frame(stratum = "female", group = 1:10, n = 100, events = 30,
               predicted_horizon = seq(1, 10), observed_pct = seq(1, 10)),
    data.frame(stratum = "male", group = 1:10, n = 100, events = 30,
               predicted_horizon = seq(1, 10), observed_pct = seq(1, 10) * 0.5))
  s <- quiet_fit(calibration_slope(d))
  expect_equal(nrow(s), 2L)
  expect_equal(s$slope[s$stratum == "female"], 1.0, tolerance = 1e-8)
  expect_equal(s$slope[s$stratum == "male"],   0.5, tolerance = 1e-8)
})

test_that("calibration_slope refuses to fit too few points", {
  d <- data.frame(stratum = "all", group = 1:3, n = 100, events = 30,
                  predicted_horizon = 1:3, observed_pct = 1:3)
  expect_null(calibration_slope(d))
  expect_null(calibration_slope(NULL))
  expect_error(calibration_slope(data.frame(stratum = "all", observed_pct = 1)),
               "predicted_horizon")
})

# --- a synthetic at-risk frame, shaped like ascvd_status_at() output ------------------------------
fake_at_risk <- function(n_female = 60, n_male = 50, seed = 7) {
  set.seed(seed)
  n <- n_female + n_male
  data.frame(
    person_id = seq_len(n),
    sex = rep(c("female", "male"), c(n_female, n_male)),
    age = rep(60, n),
    sbp = rep(130, n),
    # 193.35 mg/dL is exactly 5.0 mmol/L at 38.67 — the paper's derivation-female value.
    total_c = rep(193.35, n),
    hdl_c   = rep(58.005, n),          # 1.5 mmol/L
    bmi = rep(30, n), egfr = rep(85, n),
    dm = rep(c(TRUE, FALSE), c(30, n - 30)),
    a1c = rep(c(7.0, 5.5), c(30, n - 30)),
    smoking = rep(FALSE, n),
    bp_tx = rep(c(TRUE, FALSE), c(40, n - 40)),
    statin = rep(c(TRUE, FALSE), c(25, n - 25)),
    followup_days = rep(730.5, n),      # exactly 2 years
    event = rep(c(1L, 0L), c(24, n - 24)),
    ascvd_status = rep(c("incident", "event_free"), c(24, n - 24)),
    stringsAsFactors = FALSE)
}

test_that("Table 1 converts our mg/dL into the paper's mmol/L", {
  t1 <- make_paper_table1(fake_at_risk())
  chol <- t1[t1$characteristic == "Total cholesterol, mmol/L", ]
  expect_equal(chol$ours_female, "5.0 (0.0)")
  # ...and the paper column is untouched by that conversion.
  expect_equal(chol$paper_deriv_female, "5.0 (0.8)")

  hdl <- t1[t1$characteristic == "HDL-C, mmol/L", ]
  expect_equal(hdl$ours_female, "1.5 (0.0)")

  # Non-HDL is derived, not measured: (total - HDL) / 38.67 = 3.5.
  nonhdl <- t1[t1$characteristic == "Non-HDL-C, mmol/L", ]
  expect_equal(nonhdl$ours_female, "3.5 (0.0)")

  # A raw mg/dL value would print ~193. Guard the failure mode explicitly.
  expect_false(grepl("19[0-9]", chol$ours_female))
})

test_that("the paper column reproduces the paper's printed precision", {
  # Two significant figures, which is what the printed table uses: 123 (16) and 78, but 5.0 (0.8)
  # and 8.0. This is the check that our column and theirs cannot differ in precision alone — reading
  # "58.0" beside "53" as a real difference is the mistake it prevents.
  t1 <- make_paper_table1(fake_at_risk())
  cell <- function(lbl, col) t1[[col]][t1$characteristic == lbl]
  expect_equal(cell("Systolic BP, mm Hg", "paper_deriv_female"), "123 (16)")
  expect_equal(cell("Age, y", "paper_deriv_female"), "53 (13)")
  expect_equal(cell("BMI, kg/m2", "paper_deriv_female"), "29 (5)")
  expect_equal(cell("Total cholesterol, mmol/L", "paper_deriv_female"), "5.0 (0.8)")
  expect_equal(cell("White, %", "paper_deriv_female"), "78")
  expect_equal(cell("Black, %", "paper_deriv_male"), "8.0")
  expect_equal(cell("Antihypertensive tx, %", "paper_deriv_female"), "23")

  # No cell may exceed the column it is printed in, or it truncates and silently loses a digit.
  wide <- vapply(t1[, -1], function(col) max(nchar(col)), integer(1))
  expect_true(all(wide <= 11), info = paste(names(wide)[wide > 11], collapse = ", "))
})

test_that("Table 1 reports follow-up in years and puts our N beside theirs", {
  t1 <- make_paper_table1(fake_at_risk())
  fu <- t1[t1$characteristic == "Follow-up, y", ]
  expect_equal(fu$ours_female, "2.0 (0.0)")
  expect_equal(fu$paper_valid_female, "5.0 (3.2)")

  n <- t1[t1$characteristic == "N participants", ]
  expect_equal(n$ours_female, "60")
  expect_equal(n$paper_valid_female, "1,894,882")

  # The rows we cannot fill must be visibly blank on our side and populated on theirs — a dropped
  # row would read as "we measured everything they did".
  for (lbl in c("UACR, mg/g", "SDI decile", "Deaths", "HF events", "White, %")) {
    r <- t1[t1$characteristic == lbl, ]
    expect_equal(r$ours_female, "-", info = lbl)
    expect_true(nzchar(r$paper_deriv_female) && r$paper_deriv_female != "-", info = lbl)
  }
})

test_that("Table 1 suppresses a small sex group and everything derived from it", {
  ar <- fake_at_risk(n_female = 60, n_male = 8)     # 8 men, below the threshold of 20
  t1 <- make_paper_table1(ar)
  expect_equal(t1$ours_male[t1$characteristic == "N participants"], "<20")
  expect_equal(t1$ours_male[t1$characteristic == "Age, y"], "-")
  expect_equal(t1$ours_male[t1$characteristic == "Diabetes, %"], "-")
  # The other sex is unaffected.
  expect_equal(t1$ours_female[t1$characteristic == "N participants"], "60")
})

test_that("Table 1 suppresses a percentage whose numerator is small", {
  ar <- fake_at_risk(n_female = 60, n_male = 50)
  ar$statin <- c(rep(TRUE, 3), rep(FALSE, nrow(ar) - 3))   # 3 statin users among 60 women
  t1 <- make_paper_table1(ar)
  # 5.0% of 60 hands back "3 people". Denominator-only suppression would print it.
  expect_equal(t1$ours_female[t1$characteristic == "Statin tx, %"], "-")
})

test_that("Table 1 uses only the at-risk rows", {
  ar <- fake_at_risk()
  prevalent <- ar[1:20, ]
  prevalent$event <- NA_integer_
  prevalent$ascvd_status <- "prevalent"
  prevalent$age <- 999                       # would wreck the mean if it leaked in
  t1 <- make_paper_table1(rbind(ar, prevalent))
  # "60 (0)", not "60.0 (0.0)": cells >= 20 print at the paper's integer precision (.pt_mean_sd_fmt).
  expect_equal(t1$ours_female[t1$characteristic == "Age, y"], "60 (0)")
})

test_that("Table 4 refuses to invent numbers when calibration was never run", {
  expect_error(make_paper_table4(list(), NULL), "cal.*required|required.*cal")
  expect_error(make_paper_table4(list(), list(horizon_years = 2)), "concordance_by_sex")
})

test_that("Table 4 pairs our numbers with the paper's and labels the interval kinds apart", {
  cal <- list(
    horizon_years = 2, outcome = "acute",
    concordance_by_sex = data.frame(
      stratum = c("female", "male"), n = c(1000, 900), events = c(60, 55),
      c_index = c(0.712, 0.688), se = c(0.02, 0.02),
      lower = c(0.673, 0.649), upper = c(0.751, 0.727), stringsAsFactors = FALSE),
    calibration_by_sex = rbind(
      data.frame(stratum = "female", group = 1:10, n = 100, events = 6,
                 predicted_horizon = seq(1, 10), observed_pct = seq(1, 10) * 0.8),
      data.frame(stratum = "male", group = 1:10, n = 90, events = 5.5,
                 predicted_horizon = seq(1, 10), observed_pct = seq(1, 10) * 1.2)))

  t4 <- quiet_fit(make_paper_table4(list(), cal))
  val <- function(metric, col) t4[[col]][t4$metric == metric]
  expect_equal(val("C-statistic", "ours_female"), "0.712")
  expect_equal(val("Calibration slope", "ours_female"), "0.80")
  expect_equal(val("Calibration slope", "ours_male"), "1.20")
  expect_equal(val("C-statistic", "paper_female"), "0.774")
  expect_equal(val("Calibration slope", "paper_male"), "1.04")
  expect_equal(val("PCEs: calibration slope", "paper_female"), "0.54")

  # The horizon and cohort-count rows are what stop the two slope columns being read as the same
  # measurement: 2 years against 10, one cohort against 21.
  expect_equal(val("Horizon, y", "ours_female"), "2")
  expect_equal(val("Horizon, y", "paper_female"), "10")
  expect_equal(val("Cohorts contributing", "ours_female"), "1")
  expect_equal(val("Cohorts contributing", "paper_female"), "21")
  # The PCE ruler belongs to the paper's cohorts only — claiming it for ours would be inventing a
  # comparison we never ran.
  expect_equal(val("PCEs: C-statistic", "ours_female"), "-")

  notes <- attr(t4, "notes")
  expect_true(any(grepl("IQI", notes)))
  expect_true(any(grepl("competing risk|censoring", notes)))
  expect_true(any(grepl("horizon", notes, ignore.case = TRUE)))
})

test_that("Table 4 suppresses a sex with too few events", {
  cal <- list(
    horizon_years = 2, outcome = "acute",
    concordance_by_sex = data.frame(
      stratum = c("female", "male"), n = c(1000, 900), events = c(60, 11),
      c_index = c(0.712, 0.688), se = c(0.02, 0.05),
      lower = c(0.673, 0.590), upper = c(0.751, 0.786), stringsAsFactors = FALSE),
    calibration_by_sex = data.frame(
      stratum = "female", group = 1:10, n = 100, events = 6,
      predicted_horizon = seq(1, 10), observed_pct = seq(1, 10) * 0.8))
  t4 <- quiet_fit(make_paper_table4(list(), cal))
  val <- function(metric, col) t4[[col]][t4$metric == metric]
  expect_equal(val("Events", "ours_male"), "<20")
  expect_equal(val("C-statistic", "ours_male"), "-")
  expect_equal(val("Calibration slope", "ours_male"), "-")
  expect_equal(val("C-statistic", "ours_female"), "0.712")
})

test_that("render_paper_tables writes a file that carries the caveats with the numbers", {
  out <- withr::local_tempdir()
  r <- render_paper_tables(fake_at_risk(), cal = NULL, outdir = out)
  expect_true(file.exists(r$path))
  txt <- paste(readLines(r$path), collapse = "\n")
  expect_true(grepl("TABLE 1", txt))
  expect_true(grepl("Khan", txt))
  # The reason Tables 2 and 3 are absent must travel with the file, or their absence reads as an
  # oversight to anyone who opens it without this repo.
  expect_true(grepl("re-deriving PREVENT", txt))
  expect_true(grepl("death table not wired|death table", txt))

  # Every data row must keep its label and its numbers on ONE line. print(data.frame) does not: it
  # wraps a 7-column frame into blocks and the second block arrives with no `characteristic` column,
  # so nothing in it can be identified. In a file that exists to be pasted elsewhere, that is the
  # difference between a table and a pile of numbers.
  lines <- readLines(r$path)
  age <- grep("^Age, y", lines, value = TRUE)
  expect_length(age, 1)
  expect_true(grepl("53 \\(13\\)", age))        # the paper's derivation-female age, on the same line
  expect_true(all(nchar(lines) <= 100))
})
