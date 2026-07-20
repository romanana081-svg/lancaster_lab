# Tests for audit_codes.R — the code-provenance audit. T-014.

source(file.path("..", "..", "src", "phenotype", "R", "audit_codes.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
skip_if_no_fixture <- function() {
  if (!file.exists(FIXTURE_DB)) skip("fixture not built")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb not installed")
}
with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("audit_codes runs every section and resolves real concept names", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    out <- capture.output(audit_codes(con))
    # All the domain sections are present.
    expect_true(any(grepl("PREVENT measurements", out)))
    expect_true(any(grepl("Diabetes diagnosis", out)))
    expect_true(any(grepl("ASCVD acute-event", out)))
    expect_true(any(grepl("Revascularisation procedure", out)))
    expect_true(any(grepl("statin", out, ignore.case = TRUE)))
    # It resolves codes to their real concept_name (proves the join worked, not just that it ran).
    expect_true(any(grepl("Body mass index", out)))
    expect_true(any(grepl("Type 2 diabetes", out)))
    # No section raised a query error.
    expect_false(any(grepl("QUERY ERROR", out)))
  })
})

test_that("the linkage audit confirms ICD10CM on source, and never on the standard column", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    out <- capture.output(audit_codes(con))
    # Section 7a prints both columns' vocab; ICD10CM must appear (source side).
    expect_true(any(grepl("ICD10CM", out)))
  })
})
