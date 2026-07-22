# Tests for the PREVENT equation step — run_prevent() over AHAprevent::prevent_base. T-016.
#
# The AHAprevent package is the OFFICIAL AHA implementation (Khan group), not on CRAN, so these tests
# skip where it is not installed rather than fail. Install: remotes::install_github("AHA-DS-Analytics/PREVENT").

source(file.path("..", "..", "src", "phenotype", "R", "extract_prevent.R"))
source(file.path("..", "..", "src", "ascvd", "prevent", "run_prevent.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
skip_if_no_aha <- function() {
  if (!requireNamespace("AHAprevent", quietly = TRUE))
    skip("AHAprevent not installed (official AHA package, not on CRAN)")
}
with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("prevent_base reproduces the AHA package's documented worked example (T-016 gate)", {
  skip_if_no_aha()
  # The example from AHAprevent's own docs: a 45-year-old woman, TC 200, HDL 60, SBP 120, diabetes,
  # non-smoker, BMI 25, eGFR 95, untreated, no statin. Reproducing the OFFICIAL implementation's
  # output to within rounding is the validation gate: if these drift, the equation has changed under
  # us. (Cross-tie to the AHA online calculator / Khan 2024 is the external check.)
  r <- AHAprevent::prevent_base(sex = 1, age = 45, tc = 200, hdl = 60, sbp = 120, dm = 1,
                                smoking = 0, bmi = 25, egfr = 95, bptreat = 0, statin = 0)
  # prevent_base returns named list-columns; unname(unlist()) to compare as bare numbers.
  expect_equal(unname(unlist(r$prevent_base_10yr_ASCVD)), 2.101978, tolerance = 1e-4)
  expect_equal(unname(unlist(r$prevent_base_30yr_ASCVD)), 11.99614, tolerance = 1e-4)
  expect_equal(unname(unlist(r$prevent_base_10yr_CVD)),   3.37941,  tolerance = 1e-4)
})

test_that("the coding map is right: sex/booleans convert to AHA's 0/1", {
  skip_if_no_aha()
  # A one-row panel in THIS project's coding, run through run_prevent(), must equal calling
  # prevent_base directly with the mapped codes (female->1, TRUE->1).
  panel <- data.frame(person_id = 1L, age = 55, sex = "female", sbp = 140, bp_tx = TRUE,
                      total_c = 210, hdl_c = 45, statin = TRUE, dm = TRUE, smoking = TRUE,
                      egfr = 80, bmi = 30, stringsAsFactors = FALSE)
  got <- run_prevent(panel)
  ref <- AHAprevent::prevent_base(sex = 1, age = 55, tc = 210, hdl = 45, sbp = 140, dm = 1,
                                  smoking = 1, bmi = 30, egfr = 80, bptreat = 1, statin = 1)
  # got is flattened numeric (via run_prevent); unname(unlist()) ref's list-columns to match.
  expect_equal(got$prevent_base_10yr_ASCVD, unname(unlist(ref$prevent_base_10yr_ASCVD)))
  expect_equal(got$prevent_base_30yr_ASCVD, unname(unlist(ref$prevent_base_30yr_ASCVD)))
})

test_that("end-to-end: extract -> run_prevent gives 1000028 its known risk", {
  skip_if_no_aha()
  if (!file.exists(FIXTURE_DB)) skip("fixture not built")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb not installed")
  with_fixture(function(con) {
    panel  <- extract_prevent_panel(con)
    rr     <- panel[panel$person_id == 1000028, ]
    scored <- run_prevent(panel)
    r      <- scored[scored$person_id == 1000028, ]
    # male 57, TC 190, HDL 52, SBP 128, non-smoker, BMI 27.5, eGFR ~99.6, untreated. NOTE: 1000028 is
    # NOT diabetic under the advisor definition (it has an E11.9 ICD code + a diabetes med but no
    # HbA1c), so dm=FALSE. Removing diabetes drops the 10yr ASCVD from ~6.1% to ~3.2%.
    expect_false(rr$dm)
    # Compute the reference straight from the official package with the extractor's own values and
    # dm=0: the end-to-end path must equal a direct prevent_base call. No hardcoded magic number.
    ref <- AHAprevent::prevent_base(sex = 0, age = rr$age, tc = rr$total_c, hdl = rr$hdl_c,
                                    sbp = rr$sbp, dm = 0, smoking = 0, bmi = rr$bmi,
                                    egfr = rr$egfr, bptreat = 0, statin = 0)
    expect_equal(r$prevent_base_10yr_ASCVD, unname(unlist(ref$prevent_base_10yr_ASCVD)), tolerance = 1e-6)
    expect_equal(r$prevent_base_30yr_ASCVD, unname(unlist(ref$prevent_base_30yr_ASCVD)), tolerance = 1e-6)
  })
})

test_that("an incomplete panel gets NA risk, never a bogus number", {
  skip_if_no_aha()
  if (!file.exists(FIXTURE_DB)) skip("fixture not built")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb not installed")
  with_fixture(function(con) {
    scored <- run_prevent(extract_prevent_panel(con))
    # 1000029 has no serum creatinine -> eGFR NA -> risk must be NA, not fabricated.
    r <- scored[scored$person_id == 1000029, ]
    expect_true(is.na(r$prevent_base_10yr_ASCVD))
  })
})
