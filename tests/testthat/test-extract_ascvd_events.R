# Tests for ASCVD event ascertainment (T-015, D-014).
#
# The theme: the ways this code can be wrong are all SILENT. A prefix that matches nothing, a class
# that gets collapsed, a prevalent case left in the at-risk set, a revascularisation folded into the
# acute outcome -- none of them throw. So the tests pin the distinctions, not just the plumbing.

source(file.path("..", "..", "src", "phenotype", "R", "extract_ascvd_events.R"))

.fixture <- function() {
  fx <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")
  skip_if_not(file.exists(fx), "fixture not built (see docs/environment.md)")
  DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
}
.codes <- file.path("..", "..", "configs", "ascvd_codes.yaml")

# ---------------------------------------------------------------------------- the config loader

test_that("load_ascvd_codes() reads the config and preserves its order", {
  def <- load_ascvd_codes(.codes)
  expect_true(all(c("code_prefix", "class", "vocabulary_id") %in% names(def$codes)))
  expect_true(nrow(def$codes) > 0)

  # ORDER IS LOAD-BEARING: classification is first-match-wins, and acute must precede chronic. If
  # someone reorders the config so chronic comes first, I25 would still be chronic -- but a future
  # overlapping prefix would silently flip class. Pin the invariant that matters.
  first_acute   <- min(which(def$codes$class == "acute_event"))
  first_chronic <- min(which(def$codes$class == "chronic_disease"))
  expect_lt(first_acute, first_chronic)
})

test_that("load_ascvd_codes() infers the vocabulary from the class", {
  def <- load_ascvd_codes(.codes)
  expect_true(all(def$codes$vocabulary_id[def$codes$class == "revascularisation"] == "CPT4"))
  expect_true(all(def$codes$vocabulary_id[def$codes$class == "acute_event"] == "ICD10CM"))
})

test_that("load_ascvd_codes() refuses a config that contradicts itself", {
  tmp <- tempfile(fileext = ".yaml")
  writeLines(c("ascvd:",
               "  - code_prefix: \"I21\"",
               "    class: acute_event",
               "excluded_deliberately:",
               "  - code_prefix: \"I21\"",
               "    reason: contradictory"), tmp)
  # A prefix both included and deliberately excluded is a definition that disagrees with itself.
  # First-match-wins would resolve it silently, which is precisely what must not happen.
  expect_error(load_ascvd_codes(tmp), "BOTH")
})

test_that("load_ascvd_codes() refuses an empty outcome definition", {
  tmp <- tempfile(fileext = ".yaml")
  writeLines("ascvd: []", tmp)
  # An empty definition yields zero events with no error -- the silent-empty-phenotype failure.
  expect_error(load_ascvd_codes(tmp), "empty")
})

# ---------------------------------------------------------------------------- extraction

test_that("extract_ascvd_events() returns one row per person per class", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)

  expect_true(nrow(ev) > 0)
  expect_false(any(duplicated(ev[, c("person_id", "ascvd_class")])))
  expect_true(all(ev$ascvd_class %in% c("acute_event", "chronic_disease", "revascularisation")))
  expect_s3_class(ev$first_date, "Date")
  expect_true(all(ev$n_dates <= ev$n_codes))
})

test_that("extract_ascvd_events() takes the EARLIEST date, not an arbitrary one", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)

  # Cross-check the reduction against the raw rows, independently of the SQL that produced it:
  # recompute each condition-sourced person's earliest ASCVD date in R and demand agreement.
  # Pick a CONDITION-sourced row deliberately -- indexing ev[1] happened to land on a
  # revascularisation, which made this test silently assert nothing.
  cond <- ev[ev$source_table == "condition", , drop = FALSE]
  skip_if(nrow(cond) == 0, "fixture has no condition-sourced ASCVD events")

  p   <- cond$person_id[1]
  raw <- DBI::dbGetQuery(con, sprintf("
    SELECT MIN(CAST(o.condition_start_date AS DATE)) AS d
    FROM condition_occurrence o JOIN concept c ON c.concept_id = o.condition_source_concept_id
    WHERE o.person_id = %s", format(p, scientific = FALSE)))
  expect_false(is.na(raw$d))
  # The extractor's first_date is the earliest date among MATCHING codes, so it can only be >= the
  # earliest condition date overall (that person may also carry non-ASCVD conditions).
  expect_true(cond$first_date[1] >= as.Date(raw$d))
})

test_that("revascularisation is sourced from procedures and never folded into acute", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)

  rev <- ev[ev$ascvd_class == "revascularisation", ]
  skip_if(nrow(rev) == 0, "fixture has no revascularisation codes")
  expect_true(all(rev$source_table == "procedure"))

  # Q-A1: a revascularisation is a treatment decision, not purely a disease event. As of D-016 it DOES
  # count toward the outcome (advisor, 2026-07-31) -- but it must remain SEPARABLE, because the
  # acute-only outcome is the one comparable to the published PREVENT rate and the one the
  # sensitivity analysis needs. So the invariant is not "excluded" but "never silently merged".
  acute_only <- first_ascvd_event(ev, "acute_event")
  expect_false(any(acute_only$event_class == "revascularisation"))
})

test_that("the outcome is reportable BOTH with and without revascularisation (Q-A1)", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)

  a  <- first_ascvd_event(ev, "acute_event")
  ar <- first_ascvd_event(ev, c("acute_event", "revascularisation"))
  expect_gte(nrow(ar), nrow(a))
  expect_true(all(a$person_id %in% ar$person_id))

  # And adding revascularisation can only move an event date EARLIER or leave it, never later.
  m <- match(a$person_id, ar$person_id)
  expect_true(all(ar$event_date[m] <= a$event_date))
})

test_that("first_ascvd_event() rejects an unknown class rather than returning nothing", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)
  # A typo'd class silently filtering to zero rows is the failure mode this guards.
  expect_error(first_ascvd_event(ev, "acute"), "unknown class")
})

# ---------------------------------------------------------------------------- the anchor boundary

test_that("ascvd_status_at() will not invent a baseline", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev <- extract_ascvd_events(con, .codes)
  coh <- data.frame(person_id = ev$person_id[1:3])
  # Q-S6 is unresolved (D-015). The one way the deferral goes wrong is a de-facto anchor creeping in,
  # so the function must REFUSE rather than default.
  expect_error(ascvd_status_at(coh, ev, end_of_followup = as.Date("2022-01-01")), "baseline anchor")
})

test_that("ascvd_status_at() requires an end of follow-up", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  coh <- data.frame(person_id = ev$person_id[1:3], baseline_date = as.Date("2015-01-01"))
  expect_error(ascvd_status_at(coh, ev), "end_of_followup")
})

test_that("prevalent / incident / event-free are classified from the anchor", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)

  acute <- first_ascvd_event(ev, "acute_event")
  skip_if(nrow(acute) < 2, "fixture has too few acute events")

  early <- acute[which.min(acute$event_date), ]
  late  <- acute[which.max(acute$event_date), ]
  # Anchor BETWEEN the two events: the earlier person is prevalent, the later one incident.
  t0 <- early$event_date + 1
  coh <- data.frame(person_id = c(early$person_id, late$person_id), baseline_date = t0)
  st  <- ascvd_status_at(coh, ev, end_of_followup = late$event_date + 1)

  expect_equal(st$ascvd_status[st$person_id == early$person_id], "prevalent")
  expect_equal(st$ascvd_status[st$person_id == late$person_id],  "incident")

  # A prevalent person must NOT be coded event = 0: that would quietly add them to the denominator
  # of every incidence rate while they were never at risk.
  expect_true(is.na(st$event[st$person_id == early$person_id]))
  expect_equal(st$event[st$person_id == late$person_id], 1L)
})

test_that("a code ON the baseline date counts as prevalent, not incident", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  acute <- first_ascvd_event(ev, "acute_event")
  skip_if(nrow(acute) < 1, "fixture has no acute events")

  # An event recorded on the baseline date is not something that day's labs could have predicted.
  # The `<=` vs `<` boundary is exactly the kind of off-by-one that changes an event count silently.
  coh <- data.frame(person_id = acute$person_id[1], baseline_date = acute$event_date[1])
  st  <- ascvd_status_at(coh, ev, end_of_followup = acute$event_date[1] + 365)
  expect_equal(st$ascvd_status, "prevalent")
})

test_that("a chronic-only person is prevalent before baseline and INCIDENT after it (D-016)", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)

  chronic <- ev[ev$ascvd_class == "chronic_disease", ]
  skip_if(nrow(chronic) == 0, "fixture has no chronic codes")

  p <- chronic$person_id[1]
  expect_false(p %in% first_ascvd_event(ev, "acute_event")$person_id)   # chronic-only, by construction

  # Before baseline: prevalent, excluded (D-013 -- unchanged).
  coh <- data.frame(person_id = p, baseline_date = chronic$first_date[1] + 30)
  st  <- ascvd_status_at(coh, ev, end_of_followup = as.Date("2022-01-01"))
  expect_equal(st$ascvd_status, "prevalent")

  # After baseline: an INCIDENT event. This is the D-016 change (advisor, 2026-07-31) -- a chronic
  # ASCVD diagnosis now counts as incidence. Under the old acute-only default this same person was
  # "event_free" and contributed person-time with no event, so this assertion is the whole decision.
  coh2 <- data.frame(person_id = p, baseline_date = chronic$first_date[1] - 365)
  st2  <- ascvd_status_at(coh2, ev, end_of_followup = as.Date("2030-01-01"))
  expect_equal(st2$ascvd_status, "incident")
  expect_equal(st2$event, 1L)
  expect_equal(st2$event_class, "chronic_disease")

  # ...and the acute-only sensitivity analysis still recovers the old answer, which is what keeps the
  # literature comparison (acute = the published hard outcome) available.
  st3 <- ascvd_status_at(coh2, ev, end_of_followup = as.Date("2030-01-01"),
                         event_classes = "acute_event")
  expect_equal(st3$ascvd_status, "event_free")
})

test_that("follow-up runs from the END of the 30-day blanking window, not from the anchor", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)

  t0  <- as.Date("2010-01-01")
  eof <- as.Date("2020-01-01")
  # A person with no ASCVD codes at all: event-free for the whole window.
  none <- data.frame(person_id = -999, baseline_date = t0)
  st   <- ascvd_status_at(none, ev, end_of_followup = eof)
  expect_equal(st$ascvd_status, "event_free")
  expect_equal(st$event, 0L)

  # D-017: person-time starts at baseline + 30, because events in that window are not counted either.
  # Counting the 30 days as exposure while deleting its events would bias every rate DOWN -- which is
  # precisely the asymmetry the blanking window exists to avoid, so it is pinned here.
  expect_equal(st$risk_start_date, t0 + 30)
  expect_equal(st$followup_days, as.numeric(eof - (t0 + 30)))

  # And with the rule disabled, the old behaviour is recovered exactly.
  st0 <- ascvd_status_at(none, ev, end_of_followup = eof, min_days_panel_to_event = 0)
  expect_equal(st0$followup_days, as.numeric(eof - t0))
})

test_that("an event after the CDR cutoff is not counted", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  acute <- first_ascvd_event(ev, "acute_event")
  skip_if(nrow(acute) < 1, "fixture has no acute events")

  a   <- acute[which.max(acute$event_date), ]
  coh <- data.frame(person_id = a$person_id, baseline_date = a$event_date - 365)
  # Cutoff BEFORE the event: the person is event-free at that cutoff, not a case.
  st  <- ascvd_status_at(coh, ev, end_of_followup = a$event_date - 1)
  expect_equal(st$ascvd_status, "event_free")
  expect_true(is.na(st$event_date))
})

test_that("a baseline after the end of follow-up warns rather than producing negative person-time", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  coh <- data.frame(person_id = -999, baseline_date = as.Date("2021-01-01"))
  expect_warning(ascvd_status_at(coh, ev, end_of_followup = as.Date("2020-01-01")),
                 "NEGATIVE follow-up")
})

# ---------------------------------------------------------------------------- known gaps, pinned

test_that("the CPT 929 prefix over-captures beyond its stated 92920-92944 intent", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)

  # THIS TEST PINS A KNOWN DEFECT SO IT CANNOT BE FIXED BY ACCIDENT OR FORGOTTEN.
  # configs/ascvd_codes.yaml says `code_prefix: "929"  # 92920-92944: PCI`, but "929" also matches
  # 92950 (CPR), 92953 (temporary pacing), 92960 (cardioversion) and 92986+ (valvuloplasty) -- none
  # of which are coronary revascularisation. The fixture contains 92953 and 92957.
  #
  # When the code list is narrowed (with an authoritative source, not from memory), this test SHOULD
  # fail -- and the failure is the signal that the fix landed. Update it then, not before.
  rev_codes <- ev$first_code[ev$ascvd_class == "revascularisation"]
  skip_if(length(rev_codes) == 0, "fixture has no revascularisation codes")
  out_of_range <- rev_codes[as.integer(rev_codes) > 92944]
  expect_true(length(out_of_range) > 0,
              info = "expected the over-capture to still be present; if this fails the list was narrowed")
})

test_that("the outcome definition is ICD10CM-only, so ICD9 events are not ascertained", {
  def <- load_ascvd_codes(.codes)
  # Pins the known left-truncation: All of Us records before ~Oct-2015 are ICD9CM. This is not a bug
  # to fix silently -- adding ICD9 prefixes changes who is PREVALENT, which changes the cohort. The
  # decision needs the numbers from audit_ascvd_codes() Layer 3.
  expect_false("ICD9CM" %in% def$codes$vocabulary_id)
})

# ------------------------------------------------------------------------------------------------
# D-017 -- the 30-day rule: the complete PREVENT panel must predate the event by >= 30 days.
# ------------------------------------------------------------------------------------------------
# Implemented as a SYMMETRIC blanking window (see ascvd_status_at()): nobody is at risk until
# baseline + 30 days, so the events removed and the person-time removed are the same 30 days. These
# tests pin both halves, because getting only the numerator right is the failure mode that biases
# every incidence rate downward without producing a visible bug.

test_that("an event INSIDE the 30-day window is excluded, and is not silently called event-free", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  first <- first_ascvd_event(ev, c("acute_event", "chronic_disease", "revascularisation"))
  skip_if(nrow(first) < 1, "fixture has no ASCVD events")

  a <- first[1, ]
  # Baseline 10 days before the event: the panel does NOT predate it by 30 days.
  coh <- data.frame(person_id = a$person_id, baseline_date = a$event_date - 10)
  st  <- ascvd_status_at(coh, ev, end_of_followup = a$event_date + 3650)

  expect_equal(st$ascvd_status, "excluded_short_interval")
  # NOT event = 0. Coding them event-free would keep their person-time in the denominator while
  # deleting a real event from the numerator -- the exact bias this construction avoids.
  expect_true(is.na(st$event))
  expect_true(is.na(st$followup_days))
  # And not "prevalent" either: the disease came AFTER baseline, it was just too soon to use.
  expect_false(st$ascvd_status == "prevalent")
})

test_that("an event JUST OUTSIDE the window counts, and the boundary is exactly 30 days", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  first <- first_ascvd_event(ev, c("acute_event", "chronic_disease", "revascularisation"))
  skip_if(nrow(first) < 1, "fixture has no ASCVD events")
  a   <- first[1, ]
  eof <- a$event_date + 3650

  # Exactly 30 days: risk_start == event_date, and the rule is `> risk_start`, so this is STILL
  # excluded -- a panel drawn exactly 30 days before is not "at least 30 days before" the person
  # being at risk. Off-by-one here silently moves events between arms, so it is pinned.
  at30 <- ascvd_status_at(data.frame(person_id = a$person_id, baseline_date = a$event_date - 30),
                          ev, end_of_followup = eof)
  expect_equal(at30$ascvd_status, "excluded_short_interval")

  # 31 days: incident, with follow-up measured from risk_start (1 day), not from baseline (31 days).
  at31 <- ascvd_status_at(data.frame(person_id = a$person_id, baseline_date = a$event_date - 31),
                          ev, end_of_followup = eof)
  expect_equal(at31$ascvd_status, "incident")
  expect_equal(at31$event, 1L)
  expect_equal(at31$followup_days, 1)
})

test_that("min_days_panel_to_event = 0 reproduces the pre-D-017 behaviour exactly", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  first <- first_ascvd_event(ev, c("acute_event", "chronic_disease", "revascularisation"))
  skip_if(nrow(first) < 1, "fixture has no ASCVD events")
  a <- first[1, ]

  coh <- data.frame(person_id = a$person_id, baseline_date = a$event_date - 10)
  st  <- ascvd_status_at(coh, ev, end_of_followup = a$event_date + 365,
                         min_days_panel_to_event = 0)
  expect_equal(st$ascvd_status, "incident")     # excluded under the rule, incident without it
  expect_equal(st$followup_days, 10)
  # The sensitivity analysis "what did the 30-day rule cost us?" is therefore a one-argument change.
})

test_that("a negative min_days_panel_to_event is refused rather than silently reversing the window", {
  con <- .fixture(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ev  <- extract_ascvd_events(con, .codes)
  expect_error(ascvd_status_at(data.frame(person_id = -999, baseline_date = as.Date("2015-01-01")),
                               ev, end_of_followup = as.Date("2020-01-01"),
                               min_days_panel_to_event = -30))
})
