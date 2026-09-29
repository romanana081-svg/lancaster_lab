# Tests for death as a competing event: extract_death.R and the Aalen-Johansen path in
# prevent_calibration.R (D-021).
#
# Two kinds of check. The BOOKKEEPING ones use six hand-built people, one per way follow-up can end,
# because every rule here is a rule about dates and a date rule is only testable on a case small
# enough to work out on paper. The ESTIMATOR ones check Aalen-Johansen against quantities that can
# be computed without the survival package at all -- if the only evidence that survfit was called
# correctly is survfit's own output, nothing has been tested.

ROOT <- file.path("..", "..")
source(file.path(ROOT, "src", "phenotype", "R", "extract_death.R"))
source(file.path(ROOT, "src", "figures", "prevent_calibration.R"))

END  <- as.Date("2022-07-01")
RISK <- as.Date("2020-01-31")          # landmark 2020-01-01 + the 30-day window

# person 1  event-free, no death record            -> censored at the cutoff
# person 2  event-free, died 2021-03-01            -> competing death
# person 3  incident 2021-06-01, died 2021-09-01   -> ASCVD; the later death changes nothing
# person 4  incident 2021-06-01, died 2021-02-01   -> the code post-dates death: death counts
# person 5  event-free, died 2019-05-05            -> dead before risk start: excluded
# person 6  event-free, died 2023-01-01            -> after the cutoff: censored, death ignored
# person 7  prevalent, died 2021-01-01             -> not at risk before, not at risk after
# person 8  incident 2021-06-01, died the same day -> a fatal event is an event
six <- function() {
  d <- data.frame(
    person_id    = 1:8,
    ascvd_status = c("event_free", "event_free", "incident", "incident", "event_free",
                     "event_free", "prevalent", "incident"),
    event        = c(0L, 0L, 1L, 1L, 0L, 0L, NA, 1L),
    event_date   = as.Date(c(NA, NA, "2021-06-01", "2021-06-01", NA, NA, NA, "2021-06-01")),
    risk_start_date = RISK,
    stringsAsFactors = FALSE)
  d$followup_days <- ifelse(d$ascvd_status == "incident", as.numeric(d$event_date - RISK),
                     ifelse(d$ascvd_status == "event_free", as.numeric(END - RISK), NA))
  d
}
deaths <- data.frame(
  person_id  = c(2, 3, 4, 5, 6, 7, 8),
  death_date = as.Date(c("2021-03-01", "2021-09-01", "2021-02-01", "2019-05-05", "2023-01-01",
                         "2021-01-01", "2021-06-01")))

# ---- apply_competing_death: the bookkeeping -----------------------------------------------------

test_that("each of the ways follow-up can end gets the right status and the right clock", {
  out <- apply_competing_death(six(), deaths, END)
  expect_equal(out$competing_status, c(0L, 2L, 1L, 2L, NA, 0L, NA, 1L))
  expect_equal(out$event,            c(0L, 0L, 1L, 0L, NA, 0L, NA, 1L))

  full <- as.numeric(END - RISK)
  expect_equal(out$followup_days[1], full)                                        # censored
  expect_equal(out$followup_days[2], as.numeric(as.Date("2021-03-01") - RISK))    # ends at death
  expect_equal(out$followup_days[3], as.numeric(as.Date("2021-06-01") - RISK))    # ends at event
  expect_equal(out$followup_days[4], as.numeric(as.Date("2021-02-01") - RISK))    # death, not code
  expect_true(is.na(out$followup_days[5]))
  expect_equal(out$followup_days[6], full)                                        # death ignored
})

test_that("a person dead at risk start leaves the at-risk set and is counted, not coded 0", {
  out <- apply_competing_death(six(), deaths, END)
  expect_equal(out$ascvd_status[5], "excluded_died_before_risk_start")
  expect_true(is.na(out$event[5]))
  expect_equal(unname(attr(out, "death_counts")["n_died_before_risk_start"]), 1L)
})

test_that("death ON the risk-start date is excluded: zero days of follow-up is not follow-up", {
  d  <- six()[1, ]
  dd <- data.frame(person_id = 1, death_date = RISK)
  expect_equal(apply_competing_death(d, dd, END)$ascvd_status, "excluded_died_before_risk_start")
  dd$death_date <- RISK + 1
  out <- apply_competing_death(d, dd, END)
  expect_equal(out$competing_status, 2L)
  expect_equal(out$followup_days, 1)
})

test_that("a fatal event on the day of death is ASCVD, and a code after death is not", {
  out <- apply_competing_death(six(), deaths, END)
  expect_equal(out$competing_status[8], 1L)
  expect_equal(out$competing_status[4], 2L)
  expect_true(is.na(out$event_date[4]))      # the post-mortem code is not this person's outcome
  cnt <- attr(out, "death_counts")
  expect_equal(unname(cnt["n_event_after_death"]), 1L)
  expect_equal(unname(cnt["n_death_after_event"]), 2L)      # persons 3 and 8
  expect_equal(unname(cnt["n_death_after_cutoff"]), 1L)
  expect_equal(unname(cnt["n_competing_death"]), 2L)        # persons 2 and 4
})

test_that("people outside the at-risk set are left exactly as they were", {
  before <- six()
  out    <- apply_competing_death(before, deaths, END)
  expect_equal(out$ascvd_status[7], "prevalent")
  expect_true(is.na(out$event[7]))
  expect_true(is.na(out$competing_status[7]))
})

test_that("the at-risk set is still countable by ascvd_status, as the incidence code counts it", {
  # incidence_overview.R counts the at-risk set as ascvd_status %in% c('event_free','incident').
  # A competing death must stay inside that vocabulary or every such count silently shrinks.
  out <- apply_competing_death(six(), deaths, END)
  expect_equal(sum(out$ascvd_status %in% c("event_free", "incident")), sum(!is.na(out$event)))
})

test_that("with no death records nothing moves except the new columns", {
  before <- six()
  out <- apply_competing_death(before, deaths[0, ], END)
  expect_equal(out$event, before$event)
  expect_equal(out$followup_days, before$followup_days)
  expect_equal(out$competing_status, before$event)
  expect_true(all(attr(out, "death_counts") == 0L))
})

test_that("a raw panel is refused by name rather than failing on a missing column", {
  expect_error(apply_competing_death(data.frame(person_id = 1), deaths, END), "missing column")
})

test_that("followup_endings counts the three endings and who was censored before the horizon", {
  out <- apply_competing_death(six(), deaths, END)
  e <- followup_endings(out, horizon_years = 2)
  expect_equal(e[["n"]], 6L)
  expect_equal(e[["ascvd"]], 2L)
  expect_equal(e[["death"]], 2L)
  expect_equal(e[["censored"]], 2L)
  # Both censored people reach the cutoff, 882 days out -- past a 2-year horizon, short of a 3-year.
  expect_equal(e[["censored_before_horizon"]], 0L)
  expect_equal(followup_endings(out, horizon_years = 3)[["censored_before_horizon"]], 2L)
})

# ---- extract_death: the SQL ---------------------------------------------------------------------

test_that("extract_death takes the EARLIEST date per person and drops undated rows", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE TABLE death(person_id BIGINT, death_date DATE)")
  DBI::dbExecute(con, "INSERT INTO death VALUES
    (1, DATE '2021-05-02'), (1, DATE '2021-04-30'), (2, DATE '2020-12-31'), (3, NULL)")
  out <- extract_death(con)
  out <- out[order(out$person_id), ]
  expect_equal(out$person_id, c(1, 2))
  expect_equal(out$death_date, as.Date(c("2021-04-30", "2020-12-31")))
})

test_that("extract_death on an empty table is a valid empty result, not an error", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE TABLE death(person_id BIGINT, death_date DATE)")
  out <- extract_death(con)
  expect_equal(nrow(out), 0L)
  expect_s3_class(out$death_date, "Date")
})

test_that("a missing death table fails loudly and says not to fall back to Kaplan-Meier", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_error(extract_death(con), "Aalen-Johansen")
})

# ---- the estimator ------------------------------------------------------------------------------

# A cohort where the only censoring is administrative and falls AFTER the horizon -- the shape of
# the real analysis. Then Aalen-Johansen at the horizon has a closed form: events by then / N.
make_cohort <- function(n = 4000, seed = 3) {
  set.seed(seed)
  t_ev <- rexp(n, 0.015); t_dth <- rexp(n, 0.03); t_c <- rep(882 / 365.25, n)
  t_end <- pmin(t_ev, t_dth, t_c)
  d <- data.frame(person_id = seq_len(n),
                  sex = rep(c("female", "male"), length.out = n),
                  prevent_base_10yr_ASCVD = runif(n, 0.5, 20),
                  stringsAsFactors = FALSE)
  d$competing_status <- ifelse(t_ev == t_end, 1L, ifelse(t_dth == t_end, 2L, 0L))
  d$event <- as.integer(d$competing_status == 1L)
  d$followup_days <- t_end * 365.25
  d
}

test_that("Aalen-Johansen equals events-by-horizon / N when nobody is censored before it", {
  skip_if_not_installed("survival")
  d <- make_cohort()
  aj <- .observed_risk_at(d, 2 * 365.25, competing = TRUE)
  crude <- 100 * mean(d$competing_status == 1L & d$followup_days <= 2 * 365.25)
  expect_equal(aj$observed_pct, crude, tolerance = 1e-10)
  expect_equal(aj$estimator, "Aalen-Johansen")
})

test_that("Kaplan-Meier over-states observed risk when deaths are censored, and AJ does not", {
  skip_if_not_installed("survival")
  d  <- make_cohort()
  aj <- .observed_risk_at(d, 2 * 365.25, competing = TRUE)
  km <- .observed_risk_at(d, 2 * 365.25, competing = FALSE)
  expect_gt(km$observed_pct, aj$observed_pct)
  expect_equal(km$estimator, "Kaplan-Meier")
})

test_that("with no deaths the two estimators give the same observed risk", {
  skip_if_not_installed("survival")
  d <- make_cohort()
  d <- d[d$competing_status != 2L, ]
  aj <- .observed_risk_at(d, 2 * 365.25, competing = TRUE)
  km <- .observed_risk_at(d, 2 * 365.25, competing = FALSE)
  expect_equal(aj$observed_pct, km$observed_pct, tolerance = 1e-8)
})

test_that("a group with no ASCVD events reports 0%, read from the ASCVD column and not death's", {
  skip_if_not_installed("survival")
  d <- make_cohort()
  d <- d[d$competing_status != 1L, ]
  aj <- .observed_risk_at(d, 2 * 365.25, competing = TRUE)
  expect_equal(aj$observed_pct, 0)
  expect_gt(aj$deaths, 0)
})

test_that("the interval brackets the estimate and is on the risk scale", {
  skip_if_not_installed("survival")
  aj <- .observed_risk_at(make_cohort(), 2 * 365.25, competing = TRUE)
  expect_lt(aj$lower_pct, aj$observed_pct)
  expect_gt(aj$upper_pct, aj$observed_pct)
  expect_gte(aj$lower_pct, 0)
})

# ---- calibration_table picks the estimator from the frame, and says which ----------------------

test_that("calibration_table uses Aalen-Johansen when competing_status is present", {
  skip_if_not_installed("survival")
  cal <- calibration_table(make_cohort(), horizon_years = 2, n_groups = 10, by_sex = TRUE)
  expect_true(all(cal$estimator == "Aalen-Johansen"))
  expect_equal(nrow(cal), 20L)
  expect_true(all(cal$deaths >= 0))
  expect_equal(sum(cal$n), 4000L)
})

test_that("calibration_table falls back to Kaplan-Meier on a frame with no death information", {
  skip_if_not_installed("survival")
  d <- make_cohort(); d$competing_status <- NULL
  cal <- calibration_table(d, horizon_years = 2, n_groups = 10, by_sex = FALSE)
  expect_true(all(cal$estimator == "Kaplan-Meier"))
  expect_true(all(is.na(cal$deaths)))
})

test_that("every decile uses the SAME estimator, including one that contains no deaths", {
  skip_if_not_installed("survival")
  d <- make_cohort()
  # Remove every death from the lowest-risk FIFTH -- wider than a decile on purpose, because
  # dropping rows moves the decile boundaries and the new first decile has to stay inside the
  # cleared range. Decided per group, that decile would flip to Kaplan-Meier and the table would
  # mix two estimands under one column header.
  low <- d$prevent_base_10yr_ASCVD < stats::quantile(d$prevent_base_10yr_ASCVD, 0.2)
  d <- d[!(low & d$competing_status == 2L), ]
  cal <- calibration_table(d, horizon_years = 2, n_groups = 10, by_sex = FALSE)
  expect_equal(cal$deaths[1], 0L)
  expect_true(all(cal$estimator == "Aalen-Johansen"))
})

test_that("a half-attached competing_status is refused rather than estimated around", {
  skip_if_not_installed("survival")
  d <- make_cohort(); d$competing_status[1:5] <- NA
  expect_error(calibration_table(d, horizon_years = 2), "competing_status")
})

test_that("the calibration table still feeds calibration_slope unchanged", {
  skip_if_not_installed("survival")
  source(file.path(ROOT, "src", "ascvd", "validation", "paper_tables.R"))
  cal <- calibration_table(make_cohort(), horizon_years = 2, n_groups = 10, by_sex = TRUE)
  s <- calibration_slope(cal)
  expect_equal(sort(s$stratum), c("female", "male"))
  expect_true(all(is.finite(s$slope)))
})
