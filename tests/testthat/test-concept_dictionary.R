# Tests for the concept dictionary — T-014, D-014.
#
# These run against the REAL fixture DuckDB, not a mock. That is the whole point of D-003: mocking a
# data frame tests nothing about whether the concept IDs actually resolve, and "the ID does not
# resolve" is the failure mode that silently empties a phenotype.

source(file.path("..", "..", "src", "phenotype", "R", "concept_dictionary.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")

skip_if_no_fixture <- function() {
  if (!file.exists(FIXTURE_DB)) {
    skip("fixture DuckDB not built -- run: python fixture/build/generate.py")
  }
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb R package not installed")
}

with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("resolves real concept IDs out of the fixture vocabulary", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # 3028288 = LDL cholesterol (LOINC 13457-7); 3022192 = triglycerides (LOINC 2571-8)
    d <- resolve_concepts(c(3028288, 3022192), con)
    expect_equal(nrow(d), 2)
    expect_setequal(d$concept_code, c("13457-7", "2571-8"))
    expect_true(all(d$vocabulary_id == "LOINC"))
    expect_true(all(d$domain_id == "Measurement"))
  })
})

test_that("an UNRESOLVABLE concept ID is a hard error, not a silent empty set", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # This is THE failure mode the dictionary exists to catch. A stale or mistyped concept ID makes
    # the query return zero rows with no error, the phenotype quietly becomes empty, and the number
    # at the end of the pipeline is wrong but plausible.
    expect_error(resolve_concepts(c(3028288, 999999999), con), "did not resolve")

    # ...and it can be downgraded to a warning when you are deliberately exploring.
    expect_warning(d <- resolve_concepts(c(3028288, 999999999), con, strict = FALSE), "did not resolve")
    expect_equal(nrow(d), 1)
  })
})

test_that("classify_ascvd_concept(): acute, chronic, and revascularisation are kept APART", {
  skip_if_no_fixture()
  # Collapsing these into one binary flag -- which is what the old codes_df did -- throws away
  # exactly what the advisor asked us to keep: when the event happened, and what stage it is.
  code_map <- data.frame(
    code_prefix = c("I21", "I25", "929"),
    class       = c("acute_event", "chronic_disease", "revascularisation"),
    stringsAsFactors = FALSE
  )
  dict <- data.frame(
    concept_id   = c(1, 2, 3),
    concept_code = c("I21.0", "I25.1", "92920"),
    stringsAsFactors = FALSE
  )
  out <- classify_ascvd_concept(dict, code_map)
  expect_equal(out$ascvd_class, c("acute_event", "chronic_disease", "revascularisation"))
})

test_that("first match wins, so an acute code is never mislabelled as chronic", {
  # Ordering is load-bearing in configs/ascvd_codes.yaml: acute is listed before chronic.
  code_map <- data.frame(
    code_prefix = c("I21", "I2"),                        # "I2" would also match "I21.0"
    class       = c("acute_event", "chronic_disease"),
    stringsAsFactors = FALSE
  )
  dict <- data.frame(concept_id = 1, concept_code = "I21.0", stringsAsFactors = FALSE)
  expect_equal(classify_ascvd_concept(dict, code_map)$ascvd_class, "acute_event")
})

test_that("codes matching nothing are left UNCLASSIFIED rather than quietly dropped", {
  code_map <- data.frame(code_prefix = "I21", class = "acute_event", stringsAsFactors = FALSE)
  dict <- data.frame(concept_id = c(1, 2), concept_code = c("I21.0", "E11.9"),
                     stringsAsFactors = FALSE)
  out <- classify_ascvd_concept(dict, code_map)
  expect_equal(out$ascvd_class, c("acute_event", NA_character_))
})

test_that("the fixture's ICD10CM and CPT4 vocabularies are actually present and usable", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # If this fails, offline testing of the outcome definition is impossible and T-015 is blocked.
    vocab <- DBI::dbGetQuery(con,
      "SELECT vocabulary_id, COUNT(*) n FROM concept GROUP BY 1")
    expect_true("ICD10CM" %in% vocab$vocabulary_id)
    expect_true("CPT4" %in% vocab$vocabulary_id)
  })
})

test_that("empty input is handled without error", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    d <- resolve_concepts(numeric(0), con)
    expect_equal(nrow(d), 0)
    expect_true("concept_code" %in% names(d))
  })
})
