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

test_that("attach_smoking swaps the placeholder for the real value and surfaces the cost", {
  skip_if_no_fixture()
  source(file.path("..", "..", "src", "phenotype", "R", "extract_prevent.R"), local = TRUE)
  with_fixture(function(con) {
    panel <- extract_prevent_panel(con)
    smk   <- extract_smoking(con)
    p2    <- attach_smoking(panel, smk)

    # 1000028 seeded "Current Every Day" -> smoking becomes TRUE (was FALSE placeholder)
    expect_true(p2$smoking[p2$person_id == 1000028])
    expect_true(p2$has_smoking_answer[p2$person_id == 1000028])
    # 1000032 seeded "Never" -> FALSE, but a genuine answer (not a placeholder)
    expect_false(p2$smoking[p2$person_id == 1000032])
    expect_true(p2$has_smoking_answer[p2$person_id == 1000032])
    # someone with no smoking answer -> NA (unknown), not FALSE
    no_ans <- p2[!p2$has_smoking_answer, ]
    expect_true(all(is.na(no_ans$smoking)))
    # the stricter count is <= the measurement-only complete count
    expect_lte(sum(p2$complete_panel_smoking), sum(p2$complete_panel))
    # measurement-only complete count is unchanged by attaching smoking
    expect_equal(sum(p2$complete_panel), sum(panel$complete_panel))
  })
})

test_that("attach_smoking changes the PREVENT score (smoking actually feeds the equation)", {
  skip_if_no_fixture()
  if (!requireNamespace("AHAprevent", quietly = TRUE)) skip("AHAprevent not installed")
  source(file.path("..", "..", "src", "phenotype", "R", "extract_prevent.R"), local = TRUE)
  source(file.path("..", "..", "src", "ascvd", "prevent", "run_prevent.R"), local = TRUE)
  with_fixture(function(con) {
    panel <- extract_prevent_panel(con)
    base  <- run_prevent(panel)                              # smoking = FALSE placeholder
    withs <- run_prevent(attach_smoking(panel, extract_smoking(con)))
    r0 <- base$prevent_base_10yr_ASCVD[base$person_id == 1000028]
    r1 <- withs$prevent_base_10yr_ASCVD[withs$person_id == 1000028]
    # 1000028 is a current smoker -> real risk must exceed the non-smoker placeholder risk
    expect_gt(r1, r0)
  })
})
