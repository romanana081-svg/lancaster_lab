# Tests for extract_smoking.R — the provisional current-smoking derivation. T-003.

source(file.path("..", "..", "src", "phenotype", "R", "extract_smoking.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
skip_if_no_fixture <- function() {
  if (!file.exists(FIXTURE_DB)) skip("fixture not built — python fixture/build/generate.py")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb R package not installed")
}
with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("the default classifier separates current from former/never/uninformative", {
  expect_true(is_current_smoker_default("Current Every Day"))
  expect_true(is_current_smoker_default("Current Some Days"))
  expect_false(is_current_smoker_default("Never"))
  expect_false(is_current_smoker_default("Former"))
  expect_false(is_current_smoker_default("Not At All"))
  expect_true(is.na(is_current_smoker_default("PMI: Skip")))
  expect_true(is.na(is_current_smoker_default(NA_character_)))
})

test_that("extract_smoking reads the fixture's seeded answers into current_smoking", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    sm <- extract_smoking(con)
    # Fixture seeds smoking on 1000028 ("Current Every Day") and 1000032 ("Never").
    expect_true(all(c("person_id","smoking","smoking_answer","smoking_date","smoking_mapping")
                    %in% names(sm)))
    expect_true(sm$smoking[sm$person_id == 1000028])
    expect_false(sm$smoking[sm$person_id == 1000032])
    expect_equal(nrow(sm), 2)                       # exactly the two seeded people, one row each
  })
})

test_that("every derived row is flagged PROVISIONAL until sql/03 confirms the real mapping", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    sm <- extract_smoking(con)
    expect_true(all(sm$smoking_mapping == "PROVISIONAL"))
  })
})

test_that("restricting to a non-smoking question_concept_id yields no rows (the filter works)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    sm <- extract_smoking(con, question_concept_ids = 999999999)
    expect_equal(nrow(sm), 0)
  })
})
