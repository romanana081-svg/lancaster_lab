# Tests for the PREVENT panel feasibility queries — T-017.
#
# These run the REAL .sql files against the REAL fixture. If the SQL is malformed, or a column name
# is wrong, or the ICD/CPT linkage trap is fallen into, these fail here rather than in the Workbench
# where a mistake costs a round-trip to controlled-tier data.

source(file.path("..", "..", "src", "phenotype", "R", "run_sql.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
SQL_DIR    <- file.path("..", "..", "sql")

skip_if_no_fixture <- function() {
  if (!file.exists(FIXTURE_DB)) skip("fixture not built — python fixture/build/generate.py")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb R package not installed")
}

with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("the concept-discovery query runs and FLAGS codes that do not resolve", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "01_prevent_concept_discovery.sql"), con)

    # It must actually catch the missing ones. This is the query's entire purpose: an unresolvable
    # code otherwise reads as "0% coverage", i.e. a DATA finding, when it is really a CODE bug. The
    # two are indistinguishable unless you check.
    unresolved <- d$prevent_input[is.na(d$concept_id)]
    expect_true("systolic_bp" %in% unresolved)
    expect_true("serum_creatinine" %in% unresolved)

    # ...and it must confirm the ones that ARE there, so a green result means something.
    resolved <- d$prevent_input[!is.na(d$concept_id)]
    expect_true(all(c("total_cholesterol", "hdl_c", "bmi") %in% resolved))

    expect_true(any(grepl("DOES NOT RESOLVE", d$resolution_status)))
  })
})

test_that("the panel-completeness query runs and applies the 30-79 age gate (Q-S7, D-013)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "02_prevent_panel_completeness.sql"), con)

    expect_equal(nrow(d), 1)
    expect_true(d$n_eligible_srwgs_30_79 > 0)

    # The cohort gate must actually filter. The fixture has 301 people, 192 with srWGS; the eligible
    # count must be strictly smaller than the srWGS count, or the age filter is doing nothing.
    n_wgs <- DBI::dbGetQuery(con,
      "SELECT COUNT(*) n FROM cb_search_person WHERE has_whole_genome_variant = 1")$n
    expect_true(d$n_eligible_srwgs_30_79 < n_wgs)
  })
})

test_that("the fixture cannot yet support a complete PREVENT panel — and the query SAYS so (T-004)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "02_prevent_panel_completeness.sql"), con)

    # This test asserts a GAP, deliberately, so it cannot be forgotten. The fixture has no systolic
    # BP and no serum creatinine, so nobody can have a complete panel. When T-004 seeds those
    # domains, THIS TEST WILL FAIL -- and that failure is the signal that the fixture is finally
    # able to test the thing this week's work is actually about.
    expect_equal(d$n_systolic_bp, 0)
    expect_equal(d$n_serum_creatinine, 0)
    expect_equal(d$n_complete_panel_PARTIAL, 0)
  })
})

test_that("ICD codes are reached via the SOURCE concept column, not the standard one", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # THE LINKAGE TRAP, pinned. condition_concept_id maps to SNOMED; ICD10CM lives on
    # condition_source_concept_id. Query the obvious column for an ICD code and you get ZERO ROWS
    # AND NO ERROR -- which is exactly how a phenotype silently empties (D-014).
    std <- DBI::dbGetQuery(con, "
      SELECT DISTINCT c.vocabulary_id FROM condition_occurrence co
      JOIN concept c ON c.concept_id = co.condition_concept_id")
    src <- DBI::dbGetQuery(con, "
      SELECT DISTINCT c.vocabulary_id FROM condition_occurrence co
      JOIN concept c ON c.concept_id = co.condition_source_concept_id")

    expect_false("ICD10CM" %in% std$vocabulary_id)   # <- the trap
    expect_true("ICD10CM" %in% src$vocabulary_id)    # <- the fix
  })
})
