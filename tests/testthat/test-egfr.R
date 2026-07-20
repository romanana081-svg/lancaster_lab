# Tests for egfr.R — CKD-EPI 2021 creatinine, race-free. T-003.

source(file.path("..", "..", "src", "phenotype", "R", "egfr.R"))

test_that("CKD-EPI 2021 reproduces worked values from the formula (Inker 2021 coefficients)", {
  # 50-year-old female, Scr 0.9 mg/dL. Hand-computed from the published equation.
  expect_equal(egfr_ckd_epi_2021(0.9, 50, "female"), 77.9, tolerance = 0.05)
  # 60-year-old male, Scr 1.5 mg/dL.
  expect_equal(egfr_ckd_epi_2021(1.5, 60, "male"), 53.0, tolerance = 0.05)
})

test_that("it is race-free by construction and sex-aware", {
  # There is no race argument at all -- the 2021 equation removed it (the whole point).
  expect_false("race" %in% names(formals(egfr_ckd_epi_2021)))
  # Female gets the 1.012 multiplier and different kappa/alpha, so same Scr/age differs by sex.
  expect_true(egfr_ckd_epi_2021(1.0, 55, "female") != egfr_ckd_epi_2021(1.0, 55, "male"))
})

test_that("it vectorises and returns NA for missing or unrecognised inputs", {
  v <- egfr_ckd_epi_2021(c(0.9, 1.5), c(50, 60), c("female", "male"))
  expect_length(v, 2)
  expect_equal(v[1], 77.9, tolerance = 0.05)
  expect_true(is.na(egfr_ckd_epi_2021(NA_real_, 50, "female")))
  expect_true(is.na(egfr_ckd_epi_2021(1.0, 50, "PMI: Skip")))  # unknown sex -> NA, never guessed
})

test_that("higher creatinine lowers eGFR, monotonically", {
  e <- egfr_ckd_epi_2021(c(0.6, 1.0, 2.0, 4.0), 50, "male")
  expect_true(all(diff(e) < 0))
})
