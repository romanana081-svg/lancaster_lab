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

test_that("the concept-discovery query resolves EVERY PREVENT code now that T-004 seeded them", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "01_prevent_concept_discovery.sql"), con)

    # Before T-004, systolic_bp / serum_creatinine / hba1c did not resolve, and this test asserted
    # that gap. T-004 seeded those concepts, so the whole panel must now resolve. A code that fails
    # to resolve reads downstream as "0% coverage" -- a DATA finding -- when it is really a CODE bug;
    # the two are indistinguishable unless the discovery query is clean, so it must be clean.
    expect_true(all(!is.na(d$concept_id)))
    expect_true(all(d$resolution_status == "ok"))
    expect_false(any(grepl("DOES NOT RESOLVE", d$resolution_status)))

    resolved <- d$prevent_input[!is.na(d$concept_id)]
    expect_true(all(c("total_cholesterol", "hdl_c", "bmi",
                      "systolic_bp", "serum_creatinine", "hba1c") %in% resolved))
  })
})

test_that("the panel-completeness query runs and applies the 30-79 age gate (Q-S7, D-013)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "02_prevent_panel_completeness.sql"), con)

    expect_equal(nrow(d), 1)
    expect_true(d$n_eligible_srwgs_30_79 > 0)

    # The cohort gate must actually filter. The fixture has 308 people, 198 with srWGS; the eligible
    # count must be strictly smaller than the srWGS count, or the age filter is doing nothing. In
    # particular participant 1000033 is srWGS with a complete panel but is age 84, so the 30-79 gate
    # is what keeps it out.
    n_wgs <- DBI::dbGetQuery(con,
      "SELECT COUNT(*) n FROM cb_search_person WHERE has_whole_genome_variant = 1")$n
    expect_true(d$n_eligible_srwgs_30_79 < n_wgs)
  })
})

test_that("with the PREVENT domains seeded (T-004), the query counts a complete panel", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- run_sql_file(file.path(SQL_DIR, "02_prevent_panel_completeness.sql"), con)

    # This test is the flipped version of the old "fixture cannot yet support a complete panel" gap
    # assertion. T-004 seeded systolic BP and serum creatinine, so a complete panel is now countable
    # offline -- which is the whole point: the fixture can finally test the thing this week is about.
    #
    # The counts are DETERMINISTIC, not random: only the hand-authored PREVENT scenario participants
    # (1000028-1000034) carry SBP or creatinine, so nothing in the randomised filler can perturb
    # these. Complete panels: 1000028 (clean), 1000030 (dirty SBP but a valid reading survives),
    # 1000032 (HbA1c, no dx). 1000029 (no creatinine) and 1000031 (creatinine NULL-value only) are
    # incomplete by design; 1000033 (age 84) and 1000034 (not srWGS) are gated out entirely.
    expect_equal(d$n_systolic_bp, 5)         # 1000028,29,30,31,32
    expect_equal(d$n_serum_creatinine, 3)    # 1000028,30,32  (31's creatinine is NULL-valued)
    expect_equal(d$n_complete_panel_PARTIAL, 3)

    # The NULL-value guard is load-bearing: 1000031 has a creatinine ROW but no numeric value, and
    # it must not be counted (cf. defect A2). If this rises to 4, the `value_as_number IS NOT NULL`
    # filter has been dropped.
    expect_true(d$n_serum_creatinine < 4)

    # Diabetes-by-code counts only 1000028 (E11.9). 1000032's diabetic-range HbA1c is deliberately
    # NOT a diagnosis code -- the two definitions diverge (prevent_concepts.yaml).
    expect_equal(d$n_diabetes_dx, 1)
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
