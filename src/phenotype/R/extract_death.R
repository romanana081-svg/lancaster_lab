# extract_death.R — death as a COMPETING EVENT, and the three ways follow-up can end.
#
# WORKBENCH (you almost certainly want src/workbench/03_mice.R, which calls this for you):
#   source("src/phenotype/R/run_sql.R"); con <- connect_cdr()
#   source("src/phenotype/R/extract_death.R")
#   deaths  <- extract_death(con)
#   at_risk <- apply_competing_death(at_risk, deaths, end_of_followup = as.Date("2022-07-01"))
#   attr(at_risk, "death_counts")
#
# ------------------------------------------------------------------------------------------------
# WHY THIS EXISTS
#
# Until 2026-09-29 every result carried the caveat "death is not wired in". That caveat described
# TWO separate errors, and they pull in different directions:
#
#   1. IMMORTAL FOLLOW-UP. Everyone event-free was censored at the CDR cutoff, the dead included. A
#      person who died in March 2020 contributed 2.4 years of event-free person-time they did not
#      live. Worse, the panel is built "as of" the landmark from the most recent value BEFORE it, so
#      a person who died in 2018 with a complete 2017 panel was in the at-risk set on 1 January 2020.
#   2. COMPETING RISK TREATED AS CENSORING. Kaplan-Meier answers "what would the risk of ASCVD be if
#      nobody could die of anything else first?" -- a hypothetical population. PREVENT's predicted
#      risk is compared against what actually happened, where people do die first, so 1 - KM
#      OVER-states observed risk. The Aalen-Johansen estimator answers the real-world question: the
#      probability of ASCVD by time t, in a population where death removes people from risk.
#
# This file fixes (1) by ending follow-up at death and excluding people already dead at risk start,
# and makes (2) fixable by recording WHICH of three things ended each person's follow-up.
#
# ------------------------------------------------------------------------------------------------
# THE THREE ENDINGS  (column `competing_status`)
#
#   0  right-censored   alive and ASCVD-free at the end of follow-up (the CDR cutoff). This is
#                       ADMINISTRATIVE censoring: the study stopped, the person did not. It is the
#                       only censoring mechanism in this analysis -- we do not observe loss to
#                       follow-up, so everyone is assumed under observation until the cutoff.
#   1  ASCVD            the event of interest.
#   2  death            died before any ASCVD event. NOT censoring: a censored person could still
#                       have the event later, a dead person cannot.
#
# `event` stays the 0/1 ASCVD indicator and `followup_days` now ends at death for status 2. So the
# cause-specific estimators that read only those two columns (Harrell's C, the Nelson-Aalen hazard
# in the imputation model) treat a death as censoring AT THE DATE OF DEATH, which is what
# cause-specific means -- and calibration_table() reads `competing_status` and uses Aalen-Johansen.
#
# ------------------------------------------------------------------------------------------------
# THE TRAPS
#
#   * NO CAUSE OF DEATH. The All of Us `death` table carries a date; cause_concept_id is almost
#     entirely empty. A fatal MI that produced no diagnosis code is therefore counted as a competing
#     death, not as ASCVD. PREVENT's outcome includes CVD death, so this biases observed ASCVD risk
#     DOWNWARD. It cannot be fixed from this table; it has to be stated.
#   * DEATH IS UNDER-ASCERTAINED. Deaths come from EHR records, not from a linked death index. A
#     missed death leaves the person right-censored at the cutoff, i.e. the old behaviour. So this
#     moves the estimate toward the truth without reaching it -- report the death count, because a
#     reader can judge from it how incomplete the ascertainment is.
#   * A PERSON CAN HAVE SEVERAL DEATH ROWS (one per contributing site). The EARLIEST date is taken,
#     in SQL, so the tie-break is deterministic and nothing raw comes over the wire.
#   * AN ASCVD CODE DATED AFTER DEATH happens (billing lag, a death date recorded early). The rule
#     is "whichever came first", so the death wins and the code does not count as an event. Same-day
#     is ASCVD: a fatal event is an event. These are COUNTED (n_event_after_death), not hidden.
# ------------------------------------------------------------------------------------------------

#' One death date per person: the earliest recorded.
#'
#' Portable SQL (MIN, CAST, GROUP BY), so it runs identically on the DuckDB fixture and on BigQuery
#' (D-003). The fixture's `death` table is an empty stub -- zero rows back is a valid result there.
#'
#' @param con  an open DBI connection.
#' @return data.frame(person_id, death_date) -- one row per person with a dated death record.
extract_death <- function(con) {
  sql <- "
  SELECT person_id, MIN(CAST(death_date AS DATE)) AS death_date
  FROM death
  WHERE death_date IS NOT NULL
  GROUP BY person_id"
  out <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e)
    stop("extract_death(): the `death` table could not be queried, so death cannot be treated as a
  competing event and the Aalen-Johansen estimate cannot be computed. The error was:
    ", conditionMessage(e), "
  Do NOT work around this by dropping back to Kaplan-Meier silently -- the methods section says
  Aalen-Johansen. If this CDR really has no `death` table, that is a finding to report.",
         call. = FALSE))
  out$person_id  <- as.numeric(out$person_id)   # bigrquery returns integer64; normalise for joins
  out$death_date <- as.Date(out$death_date)
  out[!is.na(out$death_date), , drop = FALSE]
}

#' End follow-up at death, and record which of the three endings each person had.
#'
#' @param at_risk  the frame from ascvd_status_at(): needs person_id, ascvd_status, event,
#'   followup_days, risk_start_date, and event_date.
#' @param deaths   the frame from extract_death().
#' @param end_of_followup  the administrative censoring date -- the SAME one ascvd_status_at() used.
#' @return `at_risk` with `death_date` and `competing_status` (0/1/2, NA outside the at-risk set)
#'   added; `event`, `followup_days` and `event_date` updated for people whose follow-up ended in
#'   death; `ascvd_status` changed only where the ASCVD verdict itself changed (a post-mortem code
#'   becomes "event_free", a person dead at risk start becomes
#'   "excluded_died_before_risk_start"); and attr(, "death_counts"), a named integer vector:
#'     n_death_records          people in the cohort frame with any death record
#'     n_died_before_risk_start removed from the at-risk set (new status
#'                              "excluded_died_before_risk_start")
#'     n_competing_death        died during follow-up before any ASCVD event
#'     n_event_after_death      ASCVD code dated after death; the death was counted
#'     n_death_after_event      died after their ASCVD event; the event stands, nothing changes
#'     n_death_after_cutoff     died after end_of_followup; ignored, the person is censored
apply_competing_death <- function(at_risk, deaths, end_of_followup) {
  need <- c("person_id", "ascvd_status", "event", "followup_days", "risk_start_date", "event_date")
  miss <- setdiff(need, names(at_risk))
  if (length(miss))
    stop(sprintf("apply_competing_death(): at_risk is missing column(s) %s. Pass the frame from
  ascvd_status_at(), not the raw panel.", paste(miss, collapse = ", ")), call. = FALSE)
  stopifnot(is.data.frame(deaths), all(c("person_id", "death_date") %in% names(deaths)))
  end_of_followup <- as.Date(end_of_followup)

  out <- at_risk
  out$death_date <- as.Date(deaths$death_date[match(out$person_id, deaths$person_id)])
  risk_start <- as.Date(out$risk_start_date)
  in_set     <- out$ascvd_status %in% c("incident", "event_free")
  has_death  <- !is.na(out$death_date)

  # Dead on or before the day risk starts: never at risk. `<=` and not `<`, for the same reason
  # ascvd_status_at() uses it for prevalence -- zero days of follow-up is not follow-up.
  dead_at_start <- in_set & has_death & out$death_date <= risk_start
  after_cutoff  <- in_set & has_death & out$death_date > end_of_followup
  in_window     <- in_set & has_death & !dead_at_start & !after_cutoff

  incident         <- out$ascvd_status == "incident"
  death_after_ev   <- in_window & incident & out$event_date <= out$death_date   # event stands
  event_after_dth  <- in_window & incident & out$event_date >  out$death_date   # death came first
  competing        <- (in_window & !incident) | event_after_dth

  out$competing_status <- ifelse(in_set, as.integer(out$event), NA_integer_)
  out$competing_status[competing] <- 2L
  out$event[competing]            <- 0L
  out$followup_days[competing]    <- as.numeric(out$death_date[competing] - risk_start[competing])
  # `ascvd_status` stays within its existing vocabulary: a competing death is "event_free" (free of
  # ASCVD, which is true), so every downstream count of the at-risk set as
  # `ascvd_status %in% c("event_free", "incident")` still counts the right people. HOW follow-up
  # ended lives in `competing_status`, and only there.
  out$ascvd_status[competing]     <- "event_free"
  # The post-mortem code is not this person's outcome; leaving its date on the row would let a later
  # reader mistake it for one.
  out$event_date[event_after_dth] <- as.Date(NA)
  if ("event_class" %in% names(out)) out$event_class[event_after_dth] <- NA_character_
  if ("event_code"  %in% names(out)) out$event_code[event_after_dth]  <- NA_character_

  # Excluded people get NA, not 0, exactly as prevalent cases do: coding them 0 would put them back
  # in the denominator of every rate.
  out$ascvd_status[dead_at_start]     <- "excluded_died_before_risk_start"
  out$event[dead_at_start]            <- NA_integer_
  out$followup_days[dead_at_start]    <- NA_real_
  out$competing_status[dead_at_start] <- NA_integer_
  out$event_date[dead_at_start]       <- as.Date(NA)

  attr(out, "death_counts") <- c(
    n_death_records          = sum(has_death),
    n_died_before_risk_start = sum(dead_at_start),
    n_competing_death        = sum(competing),
    n_event_after_death      = sum(event_after_dth),
    n_death_after_event      = sum(death_after_ev),
    n_death_after_cutoff     = sum(after_cutoff))
  out
}

#' TRUE when a frame carries usable competing-event information.
#'
#' The single place that decides "Aalen-Johansen or Kaplan-Meier", so the estimator and the label
#' printed beside it can never disagree. A frame that has never been through
#' apply_competing_death() has no `competing_status` column and gets Kaplan-Meier, labelled as such.
has_competing_status <- function(d)
  "competing_status" %in% names(d) && any(!is.na(d$competing_status))

#' How each person's follow-up ended, as counts -- the numbers behind the censoring sentence.
#'
#' @param d  an at-risk frame (rows outside the at-risk set are ignored).
#' @param horizon_years  the evaluation horizon; NULL skips the before-horizon count.
#' @return named integer vector: n, ascvd, death, censored, censored_before_horizon.
#'   `censored_before_horizon` is the one to read. The estimators only differ from a crude
#'   proportion through people censored BEFORE the horizon; when it is 0, Aalen-Johansen at the
#'   horizon equals events-by-horizon / N exactly, and that is worth saying on a poster.
followup_endings <- function(d, horizon_years = NULL) {
  d <- d[!is.na(d$event) & !is.na(d$followup_days) & d$followup_days >= 0, , drop = FALSE]
  st <- if (has_competing_status(d)) d$competing_status else as.integer(d$event)
  cens <- st == 0L
  c(n = nrow(d), ascvd = sum(st == 1L), death = sum(st == 2L), censored = sum(cens),
    censored_before_horizon = if (is.null(horizon_years)) NA_integer_
                              else sum(cens & d$followup_days < horizon_years * 365.25))
}
