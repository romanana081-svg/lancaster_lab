# Tests for extract_prevent.R — the PREVENT input extractor, against the real fixture. T-003.

source(file.path("..", "..", "src", "phenotype", "R", "extract_prevent.R"))

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

test_that("the clean baseline participant (1000028) extracts exactly the known inputs", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    r <- p[p$person_id == 1000028, ]
    expect_equal(nrow(r), 1)
    expect_equal(r$age, 57)            # age_at_cdr = 2022 - 1965
    expect_equal(r$sex, "male")
    expect_equal(r$sbp, 128)
    expect_equal(r$total_c, 190)
    expect_equal(r$hdl_c, 52)
    expect_equal(r$bmi, 27.5)
    expect_equal(r$egfr, 99.6, tolerance = 0.1)   # creatinine 0.9, male, 57y
    expect_true(r$dm)                  # E11.9
    expect_false(r$statin)             # no statin exposure
    expect_true(r$complete_panel)
  })
})

test_that("dirty SBP is bounded and same-day duplicates averaged (1000030)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    r <- p[p$person_id == 1000030, ]
    # SBP rows: 900 (out of range -> dropped), 120 (earlier date), 132 & 134 (most recent, same day).
    # So baseline = mean(132, 134) = 133; the 900 must NOT survive.
    expect_equal(r$sbp, 133)
    expect_true(r$complete_panel)
  })
})

test_that("bp_tx and smoking are honest placeholders, flagged on every row", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    expect_true(all(p$bp_tx == FALSE))
    expect_true(all(p$smoking == FALSE))
    expect_true(all(nzchar(p$placeholder_inputs)))
  })
})

test_that("the complete-panel count matches the genomic-free cohort (4)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    # 1000028, 1000030, 1000032, 1000034 have all five inputs, EHR, age 30-79. 1000029 (no
    # creatinine), 1000031 (creatinine NULL), 1000033 (age 84) do not qualify. Same 4 as sql/02.
    expect_equal(sum(p$complete_panel), 4)
    expect_setequal(p$person_id[p$complete_panel], c(1000028, 1000030, 1000032, 1000034))
  })
})

test_that("statin detection uses concept_ancestor (finds clinical-drug descendants, not just ingredients)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # The fixture seeds concept_ancestor (ingredient -> its clinical drug). A person on a statin
    # CLINICAL drug must be found via the ancestor rollup -- the whole point of the fix. Participants
    # 1000001/1000004/1000016/1000017 have statin exposures.
    hit <- DBI::dbGetQuery(con,
      "SELECT DISTINCT de.person_id
       FROM drug_exposure de JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
       WHERE ca.ancestor_concept_id IN (1510813,1539403,1545958,1549686,1551860,1592085,1592180,40165636)")$person_id
    expect_true(1000001 %in% hit)
    expect_true(length(hit) > 0)
  })
})

test_that("the output columns are exactly what the PREVENT equation consumes", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    expect_true(all(c("age", "sex", "sbp", "bp_tx", "total_c", "hdl_c",
                      "statin", "dm", "smoking", "egfr", "bmi") %in% names(p)))
  })
})
