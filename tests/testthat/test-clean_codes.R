# Tests for clean_codes() / combine_codes() / as_binary_phenotype() — T-005.

source(file.path("..", "..", "src", "phenotype", "R", "clean_codes.R"))

cc <- function(person_id, date, code = "I21", name = "MI") {
  n <- length(person_id)
  data.frame(
    person_id = person_id,
    condition_start_datetime = as.Date(date),
    source_concept_code = rep(code, length.out = n),
    source_concept_name = rep(name, length.out = n),
    stringsAsFactors = FALSE
  )
}

test_that("keeps each person's earliest code, one row per person", {
  df <- rbind(
    cc(1, "2018-06-01", "I25"),
    cc(1, "2015-04-10", "I21"),   # earliest -> wins
    cc(2, "2020-01-01", "I21")
  )
  out <- clean_codes(df, out_prefix = "CAD")
  expect_equal(nrow(out), 2)
  expect_equal(out$CAD_date[out$person_id == 1], as.Date("2015-04-10"))
  expect_equal(out$CAD_code[out$person_id == 1], "I21")
})

test_that("same-day codes: the date and the phenotype are unambiguous; only the LABEL was arbitrary", {
  # A-002 bites here far more mildly than in clean_measurement(): whichever of these two codes wins,
  # the person still HAS CAD and their earliest CAD date is still 2015-04-10. Only the reported label
  # was arbitrary under the notebook's distinct(). We pin it anyway -- determinism costs one arrange().
  df <- rbind(cc(1, "2015-04-10", "I25"), cc(1, "2015-04-10", "I21"))
  out <- clean_codes(df, out_prefix = "CAD")
  expect_equal(nrow(out), 1)
  expect_equal(out$CAD_date, as.Date("2015-04-10"))
  expect_equal(out$CAD_code, "I21")            # lowest code string, deterministically
})

test_that("combine_codes() reproduces the notebook's CAD construction (ICD + CPT, earliest wins)", {
  icd <- clean_codes(rbind(cc(1, "2018-01-01", "I25"), cc(2, "2016-05-05", "I21")), out_prefix = "CAD")
  cpt <- clean_codes(rbind(cc(1, "2015-04-10", "92920"), cc(3, "2019-09-09", "92928")),
                     out_prefix = "CAD")

  out <- combine_codes(icd, cpt, out_prefix = "CAD")
  expect_equal(nrow(out), 3)
  # person 1 has both an ICD (2018) and a CPT (2015) -- the PROCEDURE is earlier and must win.
  expect_equal(out$CAD_date[out$person_id == 1], as.Date("2015-04-10"))
  expect_equal(out$CAD_code[out$person_id == 1], "92920")
  expect_equal(out$CAD_date[out$person_id == 2], as.Date("2016-05-05"))
  expect_equal(out$CAD_date[out$person_id == 3], as.Date("2019-09-09"))
})

test_that("as_binary_phenotype(): people with no code get 0, not NA (A-006)", {
  # The whole cohort must be passed in -- otherwise the people we care about (the ones with NO code)
  # simply would not appear. A 0 here means "no code found", NOT "confirmed disease-free".
  codes <- clean_codes(cc(1, "2015-04-10"), out_prefix = "CAD")
  out <- as_binary_phenotype(codes, cohort_ids = c(1, 2, 3), out_prefix = "CAD")

  expect_equal(nrow(out), 3)
  expect_equal(out$CAD_present, c(1L, 0L, 0L))
  expect_equal(out$CAD_date[out$person_id == 1], as.Date("2015-04-10"))
  expect_true(is.na(out$CAD_date[out$person_id == 2]))   # no code -> no date
})

test_that("rows with no person_id or no date are dropped (fixture defects A5, A6)", {
  df <- rbind(
    cc(NA, "2015-04-10"),        # NULL person_id                        (A5)
    cc(1, NA),                   # a code with no usable date
    cc(2, "2015-04-10")          # keeper
  )
  out <- clean_codes(df, out_prefix = "CAD")
  expect_equal(out$person_id, 2)
})

test_that("an empty input yields an empty, correctly-shaped frame", {
  out <- clean_codes(cc(numeric(0), as.Date(character(0))), out_prefix = "PAD")
  expect_equal(nrow(out), 0)
  expect_named(out, c("person_id", "PAD_code", "PAD_date", "PAD_name"))
})

test_that("combine_codes() rejects frames built with mismatched prefixes", {
  a <- clean_codes(cc(1, "2015-01-01"), out_prefix = "CAD")
  b <- clean_codes(cc(2, "2016-01-01"), out_prefix = "PAD")
  expect_error(combine_codes(a, b, out_prefix = "CAD"), "same out_prefix")
})
