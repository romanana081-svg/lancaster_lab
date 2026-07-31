# Tests for the case-anchored cohort (D-019, risk-set sampling).
#
# sample_risk_sets() is a PURE function on data frames, so it is tested on hand-built input with a
# known answer rather than on the fixture -- which also means these tests pin the SAMPLING LOGIC,
# the part where a subtle error (a control who was not actually at risk, a case leaking into its own
# risk set) would silently bias the result and never throw.

source(test_path("..", "..", "src", "ascvd", "stats", "risk_set_sampling.R"))
source(test_path("..", "..", "src", "phenotype", "R", "extract_ascvd_events.R"))

# Ten people whose panels complete on staggered dates; one has an early ASCVD code.
.eligible <- function() data.frame(
  person_id        = 1:10,
  panel_ready_date = as.Date("2015-01-01") + c(0, 100, 200, 300, 400, 500, 600, 700, 800, 900),
  first_ascvd_date = as.Date(c(NA, NA, "2016-01-01", NA, NA, NA, NA, NA, NA, NA)),
  stringsAsFactors = FALSE)

test_that("a control must have a complete panel BEFORE the anchor and no prior ASCVD code", {
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2016-06-01"))
  rs <- sample_risk_sets(cases, .eligible(), ratio = 10, seed = 1)

  ctrl <- rs$person_id[rs$role == "control"]
  el   <- .eligible()

  # Eligible at 2016-06-01: panel ready by then = ids 1..6 (2015-01-01 .. 2016-05-15). Of those, id 3
  # already had an ASCVD code on 2016-01-01, so it is NOT at risk. Expect exactly 1,2,4,5,6.
  expect_setequal(ctrl, c(1, 2, 4, 5, 6))
  expect_false(3 %in% ctrl)                                  # prior event -> not at risk
  expect_true(all(el$panel_ready_date[match(ctrl, el$person_id)] <= as.Date("2016-06-01")))
})

test_that("a person coded ON the anchor date is not counted as event-free", {
  el <- .eligible()
  el$first_ascvd_date[1] <- as.Date("2016-06-01")            # exactly the anchor
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2016-06-01"))
  rs <- sample_risk_sets(cases, el, ratio = 10, seed = 1)
  # `>` not `>=`: at that instant they are no longer at risk of a FIRST event. This boundary decides
  # whether a person lands in the numerator or the denominator, so it is pinned.
  expect_false(1 %in% rs$person_id[rs$role == "control"])
})

test_that("the case is never sampled as its own control", {
  el <- .eligible()
  cases <- data.frame(person_id = 5, anchor_date = as.Date("2018-01-01"))
  rs <- sample_risk_sets(cases, el, ratio = 10, seed = 1)
  expect_equal(sum(rs$person_id == 5), 1)                    # appears once, as the case
  expect_equal(rs$role[rs$person_id == 5], "case")
})

test_that("a control who LATER becomes a case is kept, and flagged", {
  # This is the property that looks like a bug. A control represents person-time at risk at that
  # instant; excluding people who later have an event is the classic incidence-density-sampling
  # error and biases the estimate. Keep them -- but record it, because someone will ask.
  el <- .eligible()
  el$first_ascvd_date[2] <- as.Date("2019-01-01")            # after the anchor below
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2016-06-01"))
  rs <- sample_risk_sets(cases, el, ratio = 10, seed = 1)

  expect_true(2 %in% rs$person_id[rs$role == "control"])
  expect_true(rs$becomes_case_later[rs$person_id == 2])
  expect_false(any(rs$becomes_case_later[rs$role == "case"]))
})

test_that("the ratio is respected, and weights reflect the sampling fraction", {
  el <- .eligible()
  el$first_ascvd_date <- as.Date(NA)                         # all ten at risk
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2020-01-01"))

  rs <- sample_risk_sets(cases, el, ratio = 4, seed = 7)
  expect_equal(sum(rs$role == "control"), 4)
  expect_equal(sum(rs$role == "case"), 1)

  # 10 eligible, 4 sampled -> each control stands for 2.5 people. Without this weight, absolute
  # calibration is wrong by construction: a 4:1 sample has ~4x the cohort's event rate.
  expect_equal(unique(rs$weight[rs$role == "control"]), 2.5)
  expect_equal(unique(rs$weight[rs$role == "case"]), 1)
})

test_that("a risk set smaller than the ratio takes everyone, and says so in the weight", {
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2015-06-01"))
  rs <- sample_risk_sets(cases, .eligible(), ratio = 10, seed = 1)
  # Only ids 1 and 2 have a panel by 2015-06-01, so we cannot get 10 controls.
  expect_equal(sum(rs$role == "control"), 2)
  expect_equal(unique(rs$weight[rs$role == "control"]), 1)   # took all of them: no up-weighting
})

test_that("sampling is reproducible from the seed, and the seed is REQUIRED", {
  el <- .eligible(); el$first_ascvd_date <- as.Date(NA)
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2020-01-01"))

  a <- sample_risk_sets(cases, el, ratio = 3, seed = 42)
  b <- sample_risk_sets(cases, el, ratio = 3, seed = 42)
  d <- sample_risk_sets(cases, el, ratio = 3, seed = 43)
  expect_equal(a$person_id, b$person_id)                     # same seed -> same cohort, bit for bit
  expect_false(identical(a$person_id, d$person_id))          # different seed -> different sample

  # A cohort that cannot be rebuilt is not a cohort. No silent default.
  expect_error(sample_risk_sets(cases, el, ratio = 3), "seed")
})

test_that("the same person may serve as a control in more than one risk set", {
  el <- .eligible(); el$first_ascvd_date <- as.Date(NA)
  cases <- data.frame(person_id = c(98, 99),
                      anchor_date = as.Date(c("2020-01-01", "2020-06-01")))
  rs <- sample_risk_sets(cases, el, ratio = 10, seed = 3)
  # Both risk sets draw from the same ten people, so reuse is expected -- and correct, for the same
  # reason future cases are kept: each row is person-time, not a person.
  expect_equal(length(unique(rs$risk_set_id)), 2)
  expect_true(any(duplicated(rs$person_id[rs$role == "control"])))
})

test_that("every risk set being empty is an error, not an empty cohort", {
  el <- .eligible()
  cases <- data.frame(person_id = 99, anchor_date = as.Date("2010-01-01"))  # before any panel
  expect_error(sample_risk_sets(cases, el, ratio = 10, seed = 1), "every risk set was empty")
})

# ------------------------------------------------------------------------------------------------
# The DATABASE half. The fixture's ASCVD-event participants and its PREVENT-panel participants are
# DISJOINT sets, so build_case_anchored_cohort() cannot produce a cohort here -- it correctly errors.
# That leaves the two SQL statements untested by the sampler tests above, and SQL is exactly where a
# DuckDB-vs-BigQuery difference hides. So they are exercised directly.

.fx <- function() {
  fx <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
  skip_if_not(file.exists(fx), "fixture not built")
  skip_if_not(requireNamespace("duckdb", quietly = TRUE), "duckdb not installed")
  DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
}

test_that("no cases with a qualifying panel is an ERROR naming coverage, not an empty cohort", {
  con <- .fx(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  ev <- extract_ascvd_events(con, test_path("..", "..", "configs", "ascvd_codes.yaml"))
  # This is a FIXTURE FACT, not a data finding: its event participants and its PREVENT-panel
  # participants were seeded as separate scenarios. Silently returning zero rows here would look
  # exactly like "no one qualifies" in the real CDR, which is why it throws instead.
  expect_error(build_case_anchored_cohort(con, ev, seed = 1), "complete PREVENT panel")
})

test_that("attach_panel_at_anchor() runs, and never returns a value measured after the anchor", {
  con <- .fx(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Fixture participant 1000030's SBP history, by date:
  #   2019-01-01  900          <- out of physiologic range, dropped by the bounds
  #   2019-02-02  120
  #   2019-03-03  132 and 134  <- same day, averaged to 133 (D-009)
  # So the anchor decides the value: 2019-02-02 -> 120, 2019-03-03 -> 133. A value the person only
  # had LATER must never leak backwards into an earlier baseline, which is the whole point of as-of.
  mid  <- attach_panel_at_anchor(con, data.frame(person_id = 1000030,
                                                 anchor_date = as.Date("2019-02-02"), role = "case"))
  late <- attach_panel_at_anchor(con, data.frame(person_id = 1000030,
                                                 anchor_date = as.Date("2019-03-03"), role = "case"))
  expect_equal(mid$sbp, 120)
  expect_equal(late$sbp, 133)

  # Anchoring on the 900-only date returns NO usable measurement -- the bounds drop it and nothing
  # earlier exists. That must come back as an NA row (so the caller's complete-case filter can drop
  # the person), never as a dropped row or an error.
  none <- attach_panel_at_anchor(con, data.frame(person_id = 1000030,
                                                 anchor_date = as.Date("2019-01-01"), role = "case"))
  expect_equal(nrow(none), 1)
  expect_true(is.na(none$sbp))
})

test_that("the anchor CTE avoids the VALUES form that BigQuery rejects", {
  # A source-level assertion, because the failure it guards cannot be reproduced offline: DuckDB
  # accepts `WITH t(a,b) AS (VALUES ...)`, BigQuery does not. Every offline test would pass and the
  # first Workbench run would fail. Pin the portable form so it cannot be "simplified" back.
  src <- readLines(test_path("..", "..", "src", "ascvd", "stats", "risk_set_sampling.R"))
  code <- src[!grepl("^\\s*#", src)]          # comments explain the trap; only CODE must avoid it
  expect_true(any(grepl("UNION ALL", code, fixed = TRUE)))
  expect_false(any(grepl("AS (VALUES", code, fixed = TRUE)))
})

test_that("multi-chunk anchoring returns the same rows as a single chunk", {
  con <- .fx(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # The PREVENT scenario participants -- the ones that actually carry the five panel measurements.
  ids <- c(1000028, 1000029, 1000030, 1000031, 1000032, 1000033, 1000034)
  coh <- data.frame(person_id = ids, anchor_date = as.Date("2021-01-01"), role = "control")
  one  <- attach_panel_at_anchor(con, coh, chunk = 1000L)
  many <- attach_panel_at_anchor(con, coh, chunk = 3L)       # forces several queries
  # Chunking is a transport detail; if it changed the answer it would do so invisibly at CDR scale.
  one  <- one[order(one$person_id), ]
  many <- many[order(many$person_id), ]
  expect_equal(one$person_id, many$person_id)
  expect_equal(one$sbp, many$sbp)
})
