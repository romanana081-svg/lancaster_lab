# Tests for the incidence-vs-literature smoke alarm (src/ascvd/validation/literature_benchmarks.R).
#
# The point of these tests is that the ALARM ITSELF works. A check that silently returns "PLAUSIBLE"
# for every input is worse than no check, because it manufactures confidence -- so each verdict tier
# is exercised with a rate constructed to land in it.

source(test_path("..", "..", "src", "ascvd", "validation", "literature_benchmarks.R"))

quiet <- function(expr) capture.output(res <- force(expr), file = NULL) -> ignored

test_that("the published PREVENT rates load from config and are internally consistent", {
  lit <- read_literature_config()
  d <- lit$prevent_paper$derivation
  v <- lit$prevent_paper$validation

  # The paper's abstract states 6,612,004 adults and 211,515 total CVD events. If the transcription
  # into config.yaml is right, the parts must add to those totals -- this is the arithmetic check
  # that the numbers were read off the table correctly rather than half-remembered.
  expect_equal(d$n_participants + v$n_participants, 6612004)
  expect_equal(d$events_cvd + v$events_cvd, 211515)

  # Guard the YAML 1.1 trap that bit this file once: a bare `n:` key parses as the boolean FALSE, so
  # `d$n_participants` silently became NULL and the sum above compared length-0 to length-1.
  expect_true(is.numeric(d$n_participants))
  expect_null(d[["FALSE"]])

  # And the derived rate must equal events / (N x mean follow-up) to rounding. Mean follow-up is
  # sex-specific; the pooled rate uses the female/male split, so reproduce it approximately.
  py <- d$n_participants * mean(c(d$mean_followup_years_female, d$mean_followup_years_male))
  expect_equal(1000 * d$events_ascvd / py,
               lit$prevent_paper$ascvd_rate_per_1000py$derivation_pooled, tolerance = 0.15)
})

test_that("a rate inside the band is PLAUSIBLE", {
  quiet(r <- check_incidence_vs_literature(n_events = 1800, person_years = 300000,
                                           n_at_risk = 70000, label = "test"))
  expect_equal(r$rate_per_1000py, 6.0, tolerance = 1e-9)
  expect_equal(r$verdict, "PLAUSIBLE")
})

test_that("an implausibly LOW rate is flagged as under-ascertainment, not passed", {
  # 300 events in 300k person-years = 1.0/1000PY, a quarter of the published rate in an OLDER cohort.
  # This is the shape of the failure where EHR capture gaps eat most of the events.
  quiet(r <- check_incidence_vs_literature(n_events = 300, person_years = 300000, label = "test"))
  expect_equal(r$rate_per_1000py, 1.0, tolerance = 1e-9)
  expect_equal(r$verdict, "STRUCTURAL DEFECT LIKELY")

  quiet(r2 <- check_incidence_vs_literature(n_events = 900, person_years = 300000, label = "test"))
  expect_equal(r2$verdict, "LOW -- probable under-ascertainment")   # 3.0/1000PY: soft flag
})

test_that("an implausibly HIGH rate is flagged as prevalent/chronic contamination", {
  # 4500/300k = 15/1000PY: the shape of chronic IHD codes being counted as incident events.
  quiet(r <- check_incidence_vs_literature(n_events = 4500, person_years = 300000, label = "test"))
  expect_equal(r$verdict, "HIGH -- probable prevalent/chronic contamination")

  quiet(r2 <- check_incidence_vs_literature(n_events = 9000, person_years = 300000, label = "test"))
  expect_equal(r2$verdict, "STRUCTURAL DEFECT LIKELY")              # 30/1000PY
})

test_that("zero person-time is an error, not a divide-by-zero", {
  expect_error(check_incidence_vs_literature(n_events = 10, person_years = 0), "person_years")
})

test_that("check_incidence_from_status() excludes prevalent participants from the denominator", {
  # 100 at-risk people (10 events), plus 900 PREVALENT ones (event = NA). If the prevalent rows leaked
  # into the denominator the rate would fall by ~10x and a broken pipeline would read as "LOW".
  status <- rbind(
    data.frame(person_id = 1:10,    event = 1L,        followup_days = 365.25 * 2),
    data.frame(person_id = 11:100,  event = 0L,        followup_days = 365.25 * 5),
    data.frame(person_id = 101:1000, event = NA_integer_, followup_days = NA_real_))
  quiet(r <- check_incidence_from_status(status, label = "test"))

  expect_equal(r$n_events, 10)
  expect_equal(r$person_years, 10 * 2 + 90 * 5, tolerance = 1e-6)   # 470 PY, prevalent excluded
  expect_equal(r$rate_per_1000py, 1000 * 10 / 470, tolerance = 1e-6)
})

test_that("an at-risk row with NA follow-up fails loudly rather than being dropped", {
  status <- data.frame(person_id = 1:3, event = c(1L, 0L, 0L),
                       followup_days = c(365.25, NA, 365.25))
  expect_error(check_incidence_from_status(status), "NA follow-up")
})

# ------------------------------------------------------------------------------------------------
# D-016 -- the broad outcome must NOT be compared against the published hard-outcome rate.
# ------------------------------------------------------------------------------------------------

test_that("the broad outcome declines the literature comparison instead of failing it", {
  # 4500 events in 300k PY = 15/1000PY. Under the ACUTE-only outcome that is a red flag. Under the
  # D-016 broad outcome (chronic diagnoses + revascularisations count) it is unremarkable -- the
  # published 4.2 counts hard events only. If this ever returns "HIGH", the checker is condemning a
  # correct pipeline for using the outcome the advisor asked for.
  quiet(broad <- check_incidence_vs_literature(n_events = 4500, person_years = 300000,
                                               outcome = "broad", label = "test"))
  expect_equal(broad$verdict, "NOT COMPARABLE -- see note")

  quiet(acute <- check_incidence_vs_literature(n_events = 4500, person_years = 300000,
                                               outcome = "acute_event", label = "test"))
  expect_equal(acute$verdict, "HIGH -- probable prevalent/chronic contamination")

  # Same arithmetic either way -- only the interpretation differs.
  expect_equal(broad$rate_per_1000py, acute$rate_per_1000py)
})

test_that("the config records WHICH outcome the band applies to, so it cannot drift", {
  lit <- read_literature_config()
  # If someone later widens the band to accommodate the broad outcome, this pins that the band was
  # derived for the acute one. The band and the outcome it describes must move together.
  expect_equal(lit$expected_ascvd_incidence$applies_to_outcome, "acute_event")
})

test_that("check_incidence_from_status() defaults to the broad outcome, matching ascvd_status_at()", {
  # The two defaults must agree. If ascvd_status_at() returns broad-outcome events and this checker
  # assumed acute, every Workbench run would get a spurious "HIGH" verdict.
  expect_equal(eval(formals(check_incidence_from_status)$outcome)[1], "broad")

  status <- rbind(
    data.frame(person_id = 1:20,   event = 1L,          followup_days = 365.25 * 2),
    data.frame(person_id = 21:100, event = 0L,          followup_days = 365.25 * 5),
    # excluded by the 30-day rule: event = NA, must not land in the denominator
    data.frame(person_id = 101:200, event = NA_integer_, followup_days = NA_real_))
  quiet(r <- check_incidence_from_status(status, label = "test"))
  expect_equal(r$n_events, 20)
  expect_equal(r$person_years, 20 * 2 + 80 * 5, tolerance = 1e-6)
  expect_equal(r$verdict, "NOT COMPARABLE -- see note")
})
