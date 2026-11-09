# incidence_overview.R — ASCVD incidence figures for the lab meeting. T-015.
#
# Companion to cohort_overview.R (which does demographics). This one does EVENTS: how many, of what
# type, when, in whom, and how much the outcome definition changes the answer.
#
# WORKBENCH:
#   source("src/phenotype/R/run_sql.R")
#   source("src/phenotype/R/extract_prevent.R")
#   source("src/phenotype/R/extract_ascvd_events.R")
#   source("src/ascvd/prevent/run_prevent.R")
#   source("src/figures/incidence_overview.R")
#   con <- connect_cdr()
#   make_incidence_figures(con, outdir = "figures", landmark = as.Date("2018-01-01"),
#                          end_of_followup = as.Date("2022-07-01"))   # <- SET THE CDR CUTOFF
#
# OFFLINE (fixture, for layout QA only — the numbers are synthetic):
#   Rscript src/figures/incidence_overview.R
#
# ------------------------------------------------------------------------------------------------
# WHICH FIGURES DEPEND ON THE UNRESOLVED BASELINE ANCHOR (Q-S6), AND WHICH DO NOT
#
# This distinction is the whole reason this file is split the way it is. Do not blur it on a slide.
#
#   ANCHOR-FREE (sound today):
#     1. events by class            — a count of codes; no baseline involved
#     2. first acute event by year  — calendar-time distribution of event dates
#     3. age at first acute event   — event date minus birth year
#     4. attrition to the at-risk set — depends on the landmark DATE only, not on covariate timing
#     5. cumulative incidence after the landmark — a survival curve built from event DATES among
#        people event-free at the landmark. Covariate VALUES never enter, so the Q-S6 placeholder
#        cannot bias it.
#
#   ANCHOR-DEPENDENT (provisional — labelled as such ON the figure):
#     6. observed incidence by PREVENT risk group. This one uses the covariate VALUES, which are
#        currently the most-recent measurement (extract_prevent.R, the Q-S6 placeholder). For a person
#        who had an event, the most-recent value can post-date the event — statin started, BP treated
#        — which biases the gradient in an unknown direction. The figure is still worth showing
#        because it is the shape of the eventual result, but its caption says PROVISIONAL and why.
#        See `first_ascvd_event()` / `ascvd_status_at()` for where the anchor enters as an argument.
# ------------------------------------------------------------------------------------------------

suppressPackageStartupMessages({ library(ggplot2); library(dplyr) })

`%||%` <- function(a, b) if (is.null(a)) b else a

.theme_inc <- function() {
  theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title    = element_text(face = "bold", size = 15),
          plot.subtitle = element_text(color = "grey35"),
          plot.caption  = element_text(color = "grey45", size = 9, hjust = 0),
          axis.title    = element_text(color = "grey25"))
}
.CLASS_FILL <- c(acute_event = "#C44E52", chronic_disease = "#8172B3",
                 revascularisation = "#CCB974")
.ONE <- "#4C72B0"
.PROVISIONAL <- paste("PROVISIONAL — covariate values are the most-recent measurement (Q-S6 baseline",
                      "anchor unresolved),\nso for people with an event they may post-date it.",
                      "Shape is indicative; the gradient is not final.")

#' Assemble everything the incidence figures need, from one connection.
#'
#' @param con  open DBI connection.
#' @param landmark  NULL (the default since 2026-11-07) for a PER-PERSON baseline: each participant's
#'   T0 is the date their own first complete PREVENT panel existed (extract_prevent_panel(first_complete
#'   = TRUE)), and follow-up runs from there to the cutoff -- however long or short that is. There is
#'   NO minimum follow-up: the old route picked one calendar landmark with >= 2 years left before the
#'   cutoff, which discarded every panel completed after it and every year of follow-up before it.
#'   Survival methods already handle unequal follow-up; that is what censoring is.
#'   Pass a Date to get the OLD shared-landmark cohort instead (T0 = that date for everyone, panel
#'   as-of that date). Kept, not deleted: it is the design every pre-2026-11-07 number came from.
#'   Why per-person is still free of immortal-time bias: entry is the day the panel becomes complete,
#'   and nothing about the outcome is needed to get there -- events before it make the person
#'   PREVALENT (excluded), never a late entrant who "survived" to be counted.
#' @param earliest_panel_date  per-person mode only. Panels must be built from measurements on or
#'   after this date. NOT a follow-up rule. DEFAULT NULL (no floor) since 2026-11-08, when ICD9CM and
#'   SNOMED were added to the outcome: before that the outcome was ICD10CM-only, a pre-Oct-2015
#'   baseline could not see earlier ASCVD, and the default was 2016-01-01. Set a date to reproduce
#'   that cohort, or as a sensitivity analysis: the prevalence check still only sees as far back as a
#'   person's EHR does, so very early baselines have the least history behind them.
#' @param end_of_followup  the CDR cutoff. Everyone event-free is censored here.
#' @param scorable_only  restrict the at-risk set to the complete/scorable PREVENT panel (D-013).
#' @param attach_smoking_status  attach REAL survey smoking via extract_smoking() instead of leaving
#'   the FALSE placeholder. This is a genuine trade and neither answer is free, so it is an explicit
#'   argument rather than a default someone discovers later:
#'     FALSE (default) — everyone keeps smoking = FALSE. The cohort stays at its full size, and
#'                       predicted risk is biased DOWNWARD for every actual smoker.
#'     TRUE            — real smoking status; people with no survey answer become NA and are dropped
#'                       by run_prevent(). Honest, but the scorable panel collapses (216,167 -> 84,176
#'                       on the 2026-07-21 real run, 39.8% coverage). The answer CODING is still
#'                       provisional (prevent_concepts.yaml: ANSWERS_PROVISIONAL).
#'   Whichever is chosen, the figure captions say which, because "predicted risk" means two different
#'   things under the two settings.
#' @return list(events, cohort, at_risk, ages, counts)
#' @param min_days_panel_to_event  D-017, the advisor's 30-day rule: the complete PREVENT panel must
#'   predate the event by at least this many days. Applied as a symmetric blanking window, so nobody
#'   is at risk until landmark + this many days. Set 0 to measure what the rule costs.
#' @param attach_death  end follow-up at death and record it as a COMPETING event
#'   (apply_competing_death(), extract_death.R; D-021). Both figure routes pass TRUE:
#'   make_incidence_figures() by default since 2026-11-08, and 03_mice.R. It changes who is at risk,
#'   because people already dead at risk start are excluded only under TRUE, and the frame's
#'   `death_source` says which one you are holding.
build_incidence_frame <- function(con, landmark = NULL, end_of_followup, scorable_only = TRUE,
                                 attach_smoking_status = FALSE,
                                 min_days_panel_to_event = 30,
                                 attach_death = FALSE,
                                 earliest_panel_date = NULL) {
  stopifnot(exists("extract_ascvd_events", mode = "function"),
            exists("extract_prevent_panel", mode = "function"))
  per_person      <- is.null(landmark) || all(is.na(landmark))
  end_of_followup <- as.Date(end_of_followup)
  if (per_person) {
    landmark <- as.Date(NA)
    if (!is.null(earliest_panel_date)) earliest_panel_date <- as.Date(earliest_panel_date)
  } else {
    landmark <- as.Date(landmark)
    earliest_panel_date <- NULL          # meaningless with a shared landmark; do not report it
    if (landmark >= end_of_followup)
      stop("build_incidence_frame(): landmark must precede end_of_followup, or nobody has follow-up.",
           call. = FALSE)
  }
  baseline_rule <- if (per_person)
    sprintf("per-person: each participant's first complete PREVENT panel%s",
            if (is.null(earliest_panel_date)) "" else
              sprintf(" (measurements on/after %s)", format(earliest_panel_date)))
    else sprintf("shared landmark %s", format(landmark))

  events <- extract_ascvd_events(con)
  # The panel is the one that could have been in hand on the baseline date -- the shared landmark, or
  # each person's own completion date. Without that the extractor takes each person's most-recent-EVER
  # value, which for anyone who had an event and stayed in care post-dates that event -- so their
  # "baseline" covariates would be measured after the outcome, and the 30-day rule (D-017) could never
  # be satisfied honestly.
  panel  <- if (per_person) extract_prevent_panel(con, first_complete = TRUE,
                                                  earliest = earliest_panel_date)
            else extract_prevent_panel(con, as_of = landmark)

  # Real survey smoking, if asked for. Left OFF by default because it shrinks the cohort by ~61% and
  # that shrink must be a decision, not a surprise -- but leaving it off is NOT the safe option, it
  # just moves the error: every actual smoker is then scored as a non-smoker.
  smoking_source <- "placeholder FALSE for everyone (biases predicted risk DOWNWARD)"
  if (isTRUE(attach_smoking_status)) {
    if (!exists("extract_smoking", mode = "function"))
      stop("build_incidence_frame(): attach_smoking_status = TRUE but extract_smoking.R is not
  sourced. source('src/phenotype/R/extract_smoking.R') first.", call. = FALSE)
    smk   <- extract_smoking(con)
    panel <- attach_smoking(panel, smk)
    smoking_source <- sprintf("real survey smoking (answer coding PROVISIONAL); %s of %s scorable have an answer",
                              format(sum(panel$complete_panel_smoking, na.rm = TRUE), big.mark = ","),
                              format(sum(panel$complete_panel, na.rm = TRUE), big.mark = ","))
  }

  # Score PREVENT if the equation and package are available (figure 6 needs it; the rest do not).
  #
  # RECORD WHY IF IT DOES NOT HAPPEN. This block used to fail silently in three different ways -- the
  # package missing, run_prevent() not sourced, or the call erroring -- all of which left the panel
  # unscored and let the run continue looking healthy. The failure then surfaced hundreds of lines
  # later, in a different file, as "no PREVENT risk column found ... Is AHAprevent installed?" -- a
  # question with the wrong answer, since the usual cause is one of the other two. The reason now
  # travels with the frame and gets printed by run_survival_curves().
  prevent_source <- NULL
  if (!requireNamespace("AHAprevent", quietly = TRUE)) {
    prevent_source <- "NOT SCORED: the AHAprevent package is not installed in this R session"
  } else if (!exists("run_prevent", mode = "function")) {
    prevent_source <- "NOT SCORED: run_prevent() is not defined -- source('src/ascvd/prevent/run_prevent.R')"
  } else {
    scored <- tryCatch(run_prevent(panel),
                       error = function(e) { warning("run_prevent() failed: ", conditionMessage(e),
                                                     call. = FALSE); NULL })
    if (is.null(scored)) {
      prevent_source <- "NOT SCORED: run_prevent() errored -- see the warning above"
    } else {
      added <- setdiff(names(scored), names(panel))
      panel <- scored
      prevent_source <- if (!length(added))
        "NOT SCORED: run_prevent() returned no new columns" else
        sprintf("scored by AHAprevent %s -> %s",
                as.character(utils::packageVersion("AHAprevent")), paste(added, collapse = ", "))
    }
  }
  if (grepl("^NOT SCORED", prevent_source))
    message("PREVENT ", prevent_source, "\n  Figures 16 and every calibration output need it; the ",
            "incidence figures do not.")

  # When smoking is attached it becomes a REQUIRED input (decision 2026-07-30): anyone with no survey
  # answer is dropped from the at-risk set entirely, not merely left NA to fall out of the scored
  # figure. Those are different cohorts -- the second would leave non-answerers in the denominator of
  # every incidence rate while excluding them from the risk-group figure, so the two would silently
  # disagree about who was studied.
  keep <- if (!scorable_only) rep(TRUE, nrow(panel))
          else if (isTRUE(attach_smoking_status) && "complete_panel_smoking" %in% names(panel))
            panel$complete_panel_smoking
          else panel$complete_panel
  cohort <- panel[keep, , drop = FALSE]
  n_too_late <- 0L
  if (per_person) {
    # No panel, no baseline. With scorable_only = TRUE nobody is dropped here; with FALSE (the MICE
    # route) these are the people with an incomplete panel, whom neither arm uses anyway -- both arms
    # require complete_panel -- and who would otherwise reach ascvd_status_at() with T0 = NA.
    cohort <- cohort[!is.na(cohort$panel_date), , drop = FALSE]
    # A panel completed within the blanking window of the cutoff has NO time at risk, so the person
    # cannot contribute. Counted, not hidden: it is the only follow-up-based exclusion left, and it is
    # 30 days, not 2 years.
    too_late   <- cohort$panel_date + min_days_panel_to_event >= end_of_followup
    n_too_late <- sum(too_late)
    cohort     <- cohort[!too_late, , drop = FALSE]
  }
  if (!nrow(cohort) && per_person)
    stop(sprintf("build_incidence_frame(): NOBODY has a complete PREVENT panel with follow-up time
  (%d people had >= 1 PREVENT measurement%s; %d complete panels came too late, within %d days of
  the %s cutoff). Check the measurement date range in the CDR, and earliest_panel_date.",
                 nrow(panel),
                 if (is.null(earliest_panel_date)) "" else
                   sprintf(" on/after %s", format(earliest_panel_date)),
                 n_too_late, min_days_panel_to_event, format(end_of_followup)), call. = FALSE)
  if (!nrow(cohort))
    stop(sprintf("build_incidence_frame(): NOBODY has a complete panel as of the %s landmark
  (%d people had >= 1 PREVENT measurement by then). The landmark is almost certainly too early --
  the panel is built with as_of = landmark, so measurements taken AFTER it do not count, which is
  the point. Move the landmark later, or check the measurement date range in the CDR.",
                 format(landmark), nrow(panel)), call. = FALSE)
  # T0. Per-person: the day the person's own panel became complete, so the 30-day rule (D-017) now
  # measures from the panel itself, exactly as the advisor worded it.
  cohort$baseline_date <- if (per_person) cohort$panel_date else landmark

  # PRIMARY outcome (D-016): all three classes count as incident ASCVD, with the 30-day rule (D-017).
  at_risk <- ascvd_status_at(cohort, events, anchor_col = "baseline_date",
                            end_of_followup = end_of_followup,
                            min_days_panel_to_event = min_days_panel_to_event)

  # SENSITIVITY / literature-comparable outcome: acute events only. Kept alongside rather than as a
  # separate run, because the two must be computed on the SAME at-risk set to be comparable -- and
  # because the published PREVENT rate can only be checked against this one.
  at_risk_acute <- ascvd_status_at(cohort, events, anchor_col = "baseline_date",
                            event_classes = "acute_event", end_of_followup = end_of_followup,
                            min_days_panel_to_event = min_days_panel_to_event)

  # DEATH (D-021). Applied to both outcome frames from ONE extraction, after the ASCVD verdicts, so
  # that the prevalent / 30-day counts below mean what they meant before and the deaths are counted
  # as their own rows rather than absorbed into them.
  death_source <- "NOT attached: event-free people are censored at the CDR cutoff even if they died"
  death_counts <- NULL; death_counts_acute <- NULL; deaths_by_year <- NULL
  if (isTRUE(attach_death)) {
    if (!exists("extract_death", mode = "function"))
      stop("build_incidence_frame(): attach_death = TRUE but extract_death.R is not sourced.
  source('src/phenotype/R/extract_death.R') first.", call. = FALSE)
    deaths        <- extract_death(con)
    at_risk       <- apply_competing_death(at_risk, deaths, end_of_followup)
    at_risk_acute <- apply_competing_death(at_risk_acute, deaths, end_of_followup)
    death_counts       <- attr(at_risk, "death_counts")
    death_counts_acute <- attr(at_risk_acute, "death_counts")
    # Deaths per calendar year among the cohort, for judging ASCERTAINMENT: a death table that
    # thins out toward the cutoff is reporting lag, not falling mortality. Years, never dates --
    # a minimum or maximum date is one participant's date of death.
    dd <- at_risk$death_date[!is.na(at_risk$death_date)]
    deaths_by_year <- if (length(dd)) table(format(dd, "%Y")) else NULL
    death_source <- sprintf(
      "`death` table, earliest date per person; %s of %s cohort members have a death record",
      format(unname(death_counts["n_death_records"]), big.mark = ","),
      format(nrow(cohort), big.mark = ","))
  }

  # Age at first acute event, from year_of_birth (OMOP `person`). Approximate to the year, which is
  # all a histogram needs and all that is safe to show.
  yob <- DBI::dbGetQuery(con, "SELECT person_id, year_of_birth FROM person")
  yob$person_id <- as.numeric(yob$person_id)
  acute <- first_ascvd_event(events, "acute_event")
  acute$year_of_birth <- yob$year_of_birth[match(acute$person_id, yob$person_id)]
  acute$age_at_event  <- as.integer(format(acute$event_date, "%Y")) - acute$year_of_birth

  # The attrition ladder to the at-risk set. Every step is a number someone will ask about -- and the
  # 30-day exclusion is now one of them, reported explicitly rather than absorbed into "not at risk".
  counts <- data.frame(
    step = c("PREVENT panel (>=1 input, EHR, 30-79)",
             if (isTRUE(attach_smoking_status))
               "Scorable panel (complete inputs + smoking answer)"
             else "Scorable panel (complete inputs, sex known)",
             if (per_person) sprintf("Panel completed < %d days before the cutoff (no time at risk)",
                                     min_days_panel_to_event),
             if (per_person) "Prevalent ASCVD at own panel date (excluded)"
             else "Prevalent ASCVD at landmark (excluded)",
             sprintf("Event within %d days of the panel (excluded, D-017)",
                     min_days_panel_to_event),
             if (isTRUE(attach_death)) "Died on or before risk start (excluded, D-021)",
             "At-risk set",
             "Incident ASCVD, all classes (D-016)",
             "  of which acute events (literature-comparable)",
             if (isTRUE(attach_death)) "Died before any ASCVD event (competing event, D-021)"),
    n = c(nrow(panel), nrow(cohort) + n_too_late,
          if (per_person) n_too_late,
          sum(at_risk$ascvd_status == "prevalent"),
          sum(at_risk$ascvd_status == "excluded_short_interval"),
          if (isTRUE(attach_death)) sum(at_risk$ascvd_status == "excluded_died_before_risk_start"),
          sum(at_risk$ascvd_status %in% c("event_free", "incident")),
          sum(at_risk$ascvd_status == "incident"),
          sum(at_risk_acute$ascvd_status == "incident"),
          if (isTRUE(attach_death)) unname(death_counts["n_competing_death"])),
    stringsAsFactors = FALSE)

  list(events = events, cohort = cohort, at_risk = at_risk, at_risk_acute = at_risk_acute,
       acute = acute, counts = counts, landmark = landmark, end_of_followup = end_of_followup,
       per_person = per_person, baseline_rule = baseline_rule,
       earliest_panel_date = earliest_panel_date,
       smoking_source = smoking_source, prevent_source = prevent_source,
       min_days_panel_to_event = min_days_panel_to_event,
       death_source = death_source, death_counts = death_counts,
       death_counts_acute = death_counts_acute, deaths_by_year = deaths_by_year)
}

#' Observed cumulative incidence after the baseline, as a curve (see cumulative_incidence()).
#'
#' Anchor-free in the sense that matters: it uses event DATES and the baseline only. Covariate values
#' never enter, so the Q-S6 placeholder cannot bias it.
.cuminc <- function(at_risk, group = NULL) {
  ci <- cumulative_incidence(at_risk, group = group)
  if (is.null(ci)) return(NULL)
  data.frame(years = ci$time_days / 365.25, cuminc = ci$cuminc_pct, strata = ci$strata,
             n_risk = ci$n_risk, estimator = ci$estimator, stringsAsFactors = FALSE)
}

#' One caption line naming the estimator a curve was drawn with, read from the curve itself.
.estimator_note <- function(ci)
  if (identical(ci$estimator[1], "Aalen-Johansen"))
    "Aalen-Johansen cumulative incidence: death before ASCVD is a competing event." else
    "1 - Kaplan-Meier: death is treated as censoring, which overstates incidence."

#' Write the incidence figures as PNGs.
#'
#' @return invisibly, the frame list from build_incidence_frame().
make_incidence_figures <- function(con, outdir = "figures", landmark = NULL, end_of_followup,
                                  scorable_only = TRUE, attach_smoking_status = FALSE, dpi = 150,
                                  min_days_panel_to_event = 30,
                                  earliest_panel_date = NULL, attach_death = TRUE) {
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
  fr <- build_incidence_frame(con, landmark, end_of_followup, scorable_only, attach_smoking_status,
                              min_days_panel_to_event = min_days_panel_to_event,
                              earliest_panel_date = earliest_panel_date,
                              attach_death = attach_death)
  # Every label below names the clock in use: a per-person baseline is not a landmark, and a figure
  # captioned "years since landmark" under it would describe a design that was not run.
  x_lab     <- if (isTRUE(fr$per_person)) "Years since own panel date" else "Years since landmark"
  t0_phrase <- if (isTRUE(fr$per_person)) "each person's own panel date" else
               sprintf("the %s landmark", format(fr$landmark))
  save <- function(name, p, w = 7, h = 4.5)
    ggsave(file.path(outdir, name), p, width = w, height = h, dpi = dpi, bg = "white")
  fmt <- function(x) format(x, big.mark = ",", trim = TRUE)

  ev      <- fr$events
  at_risk <- fr$at_risk

  # --- 1. events by class -------------------------------------------------------------------------
  # Three classes, three different scientific meanings. Showing them together is the point: it is the
  # figure that stops "CAD" from being one undifferentiated blob.
  bc <- ev %>% count(ascvd_class) %>% arrange(n)
  bc$ascvd_class <- factor(bc$ascvd_class, levels = bc$ascvd_class)
  save("10_events_by_class.png",
    ggplot(bc, aes(n, ascvd_class, fill = as.character(ascvd_class))) +
      geom_col(width = 0.65) +
      geom_text(aes(label = paste0(" ", fmt(n))), hjust = 0, size = 4) +
      scale_fill_manual(values = .CLASS_FILL, guide = "none") +
      scale_x_continuous(expand = expansion(mult = c(0, 0.22))) +
      labs(title = "People with an ASCVD code, by class",
           subtitle = "Acute = the outcome PREVENT predicts · chronic = prevalent disease · revasc = a treatment decision",
           x = "People with >=1 code in this class", y = NULL,
           caption = "Classes are not mutually exclusive: a person can appear in more than one.\nA first CHRONIC code is a diagnosis date, not an event date (configs/ascvd_codes.yaml).") +
      .theme_inc(), w = 8, h = 4.5)

  # --- 2. first acute event by calendar year ------------------------------------------------------
  acute <- fr$acute
  if (nrow(acute)) {
    yr <- acute %>% mutate(year = as.integer(format(.data$event_date, "%Y"))) %>% count(year)
    save("11_acute_by_year.png",
      ggplot(yr, aes(year, n)) +
        geom_col(fill = .CLASS_FILL[["acute_event"]], width = 0.7) +
        labs(title = "First acute ASCVD event, by calendar year",
             subtitle = "Ascertainment over calendar time — a sharp rise or cliff is usually a data artefact, not epidemiology",
             x = "Year of first acute event", y = "People",
             caption = "Codes: ICD-10-CM, ICD-9-CM, SNOMED CT, CPT, ICD-9 procedures. Early years depend on how far\nback each site's EHR goes; unmatched ICD-9 codes are listed by audit_ascvd_codes() Layer 3.") +
        .theme_inc())

    # --- 3. age at first acute event --------------------------------------------------------------
    aa <- acute[!is.na(acute$age_at_event) & acute$age_at_event > 0 & acute$age_at_event < 110, ]
    if (nrow(aa))
      save("12_age_at_first_acute.png",
        ggplot(aa, aes(age_at_event)) +
          geom_histogram(binwidth = 5, fill = .CLASS_FILL[["acute_event"]], color = "white") +
          labs(title = "Age at first acute ASCVD event",
               subtitle = sprintf("Median %.0f years", median(aa$age_at_event)),
               x = "Age at first acute event (years)", y = "People",
               caption = sprintf("N = %s with a computable age. From year_of_birth, so accurate to the year.",
                                 fmt(nrow(aa)))) +
          .theme_inc())
  }

  # --- 4. attrition to the at-risk set -----------------------------------------------------------
  # The lab-meeting figure: it accounts for every person between "has data" and "contributes an event".
  ct <- fr$counts
  ct$step <- factor(ct$step, levels = rev(ct$step))
  ct$pct  <- 100 * ct$n / ct$n[1]
  save("13_attrition_to_at_risk.png",
    ggplot(ct, aes(n, step)) +
      geom_col(fill = .ONE, width = 0.68) +
      geom_text(aes(label = sprintf(" %s (%.1f%% of panel)", fmt(n), pct)), hjust = 0, size = 3.7) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.32))) +
      labs(title = "From data to events: the incidence analysis set",
           subtitle = sprintf("Baseline: %s · follow-up to %s",
                              fr$baseline_rule %||% sprintf("landmark %s", format(fr$landmark)),
                              format(fr$end_of_followup)),
           x = "People", y = NULL,
           caption = paste(sprintf("Prevalent ASCVD at %s (any acute, chronic, or revascularisation code",
                                   t0_phrase),
                           "on/before it) is EXCLUDED, per D-013.\nEntry is the baseline date itself, so it",
                           "does not require surviving long enough to accumulate anything — no immortal time.")) +
      .theme_inc(), w = 8.5, h = 4.2)

  # --- 5. observed cumulative incidence after the landmark ---------------------------------------
  ci <- .cuminc(at_risk)
  if (!is.null(ci) && nrow(ci)) {
    n_at_risk <- sum(at_risk$ascvd_status %in% c("event_free", "incident"))
    n_ev      <- sum(at_risk$ascvd_status == "incident")
    save("14_cumulative_incidence.png",
      ggplot(ci, aes(years, cuminc)) +
        geom_step(color = .CLASS_FILL[["acute_event"]], linewidth = 1.1) +
        scale_y_continuous(labels = function(x) paste0(x, "%")) +
        labs(title = "Observed cumulative incidence of ASCVD",
             subtitle = sprintf("From %s, among those free of ASCVD at that date", t0_phrase),
             x = x_lab, y = "Cumulative incidence",
             caption = sprintf(paste("%s\nAt risk N = %s, events = %s.",
                                     "Censored at %s.\nOUTCOME (D-016): chronic ASCVD diagnosis, acute",
                                     "event, OR revascularisation — all three count.\nFollow-up starts",
                                     "%d days after %s (D-017), so the panel predates any event.",
                                     "\nCovariate VALUES do not enter this figure."),
                               .estimator_note(ci), fmt(n_at_risk), fmt(n_ev),
                               format(fr$end_of_followup), fr$min_days_panel_to_event, t0_phrase)) +
        .theme_inc(), w = 7.5, h = 5.1)

    # 14b. the same curve under the ACUTE-ONLY outcome, overlaid. This is the pair that has to be on
    # the slide together: the broad curve is the study's outcome, the acute one is the only curve
    # comparable to the published PREVENT rate, and the gap between them IS the D-016 decision made
    # visible rather than argued about.
    ci_ac <- .cuminc(fr$at_risk_acute)
    if (!is.null(ci_ac) && nrow(ci_ac)) {
      both <- rbind(cbind(ci,    outcome = "All ASCVD (D-016 primary)"),
                    cbind(ci_ac, outcome = "Acute events only (literature-comparable)"))
      n_ac <- sum(fr$at_risk_acute$ascvd_status == "incident")
      save("17_cumulative_incidence_broad_vs_acute.png",
        ggplot(both, aes(years, cuminc, color = outcome)) +
          geom_step(linewidth = 1.1) +
          scale_color_manual(values = c("#C44E52", "#4C72B0"), name = NULL) +
          scale_y_continuous(labels = function(x) paste0(x, "%")) +
          labs(title = "The outcome definition changes the curve",
               subtitle = "Same at-risk set, same clock — only what counts as an event differs",
               x = x_lab, y = "Cumulative incidence",
               caption = sprintf(paste("Events: %s broad vs %s acute-only, on the same at-risk N =",
                                       "%s.\nOnly the acute-only curve can be checked against Khan et",
                                       "al.'s published ~4.2 per 1000 person-years,\nwhich is a",
                                       "hard-outcome rate (nonfatal MI, nonfatal stroke, CV death).\n%s"),
                                 fmt(n_ev), fmt(n_ac), fmt(n_at_risk), .estimator_note(ci))) +
          .theme_inc() + theme(legend.position = "top"), w = 7.5, h = 5.1)
    }

    # by sex — the stratification the advisor asks for every time, and PREVENT is sex-specific
    if ("sex" %in% names(at_risk)) {
      cis <- .cuminc(at_risk, group = "sex")
      if (!is.null(cis) && nrow(cis))
        save("15_cumulative_incidence_by_sex.png",
          ggplot(cis, aes(years, cuminc, color = strata)) +
            geom_step(linewidth = 1.1) +
            scale_color_manual(values = c(female = "#4C72B0", male = "#DD8452"),
                               name = "Sex at birth") +
            scale_y_continuous(labels = function(x) paste0(x, "%")) +
            labs(title = "Observed cumulative incidence, by sex",
                 subtitle = "PREVENT is sex-specific, so this is the stratification that matters first",
                 x = x_lab, y = "Cumulative incidence",
                 caption = sprintf("Event dates and %s only.\n%s", t0_phrase,
                                   .estimator_note(cis))) +
            .theme_inc(), w = 7.5, h = 4.8)
    }
  }

  # --- 6. observed incidence by PREVENT risk group — PROVISIONAL ---------------------------------
  risk_col <- intersect(c("prevent_base_10yr_ASCVD", "risk10", "prevent_10yr"), names(at_risk))
  if (length(risk_col)) {
    rc <- risk_col[1]
    d  <- at_risk[!is.na(at_risk[[rc]]) & !is.na(at_risk$event), ]
    if (nrow(d) >= 20) {
      # Quintiles rather than deciles: with a modest event count, deciles are noise dressed as detail.
      brk <- unique(stats::quantile(d[[rc]], probs = seq(0, 1, 0.2), na.rm = TRUE))
      if (length(brk) >= 3) {
        d$risk_group <- cut(d[[rc]], breaks = brk, include.lowest = TRUE, labels = FALSE)
        gg <- d %>% group_by(.data$risk_group) %>%
          summarise(n = dplyr::n(), events = sum(.data$event),
                    person_years = sum(.data$followup_days) / 365.25,
                    predicted = mean(.data[[rc]]), .groups = "drop") %>%
          mutate(observed_pct = 100 * .data$events / .data$n,
                 rate_per_1000py = 1000 * .data$events / .data$person_years)
        save("16_observed_by_prevent_risk_PROVISIONAL.png",
          ggplot(gg, aes(factor(risk_group), observed_pct)) +
            geom_col(fill = "#55A868", width = 0.65) +
            geom_point(aes(y = predicted), color = "grey20", size = 2.6) +
            geom_line(aes(y = predicted, group = 1), color = "grey20", linetype = "22") +
            geom_text(aes(label = sprintf("%.1f%%", observed_pct)), vjust = -0.5, size = 3.5) +
            scale_y_continuous(expand = expansion(mult = c(0, 0.18)),
                               labels = function(x) paste0(x, "%")) +
            labs(title = "Observed events vs PREVENT predicted risk, by risk quintile",
                 subtitle = "Bars = observed % with an event · dots = mean PREVENT 10-yr predicted",
                 x = "PREVENT 10-year risk quintile (1 = lowest)", y = "Observed / predicted",
                 caption = paste0(.PROVISIONAL,
                   "\nAlso NOT comparable on the vertical axis yet: observed is over actual follow-up",
                   " (< 10 years), predicted is a 10-year risk.",
                   "\nSmoking: ", fr$smoking_source)) +
            .theme_inc(), w = 8, h = 5)
      }
    } else {
      message("skipping figure 16: fewer than 20 scored people with follow-up.")
    }
  } else {
    message("skipping figure 16: no PREVENT risk column (is run_prevent.R sourced and AHAprevent installed?).")
  }

  # Read the two numbers by MEANING, not by row position. D-017 inserted two rows into `counts`
  # (prevalent, short-interval) and this line kept its old indices, so it had been reporting the
  # prevalent count as "at-risk N" and the short-interval exclusions as "events" -- a wrong summary
  # printed confidently at the end of a run nobody would re-derive by hand.
  n_at_risk <- sum(fr$at_risk$ascvd_status %in% c("event_free", "incident"))
  n_events  <- sum(fr$at_risk$ascvd_status == "incident")
  message(sprintf("incidence figures written to %s/ | at-risk N = %s, incident events = %s",
                  outdir, fmt(n_at_risk), fmt(n_events)))
  invisible(fr)
}

# --- offline entry point: fixture, for layout QA only ---------------------------------------------
if (sys.nframe() == 0) {
  for (p in c("src/phenotype/R/egfr.R", "src/phenotype/R/extract_prevent.R",
              "src/phenotype/R/extract_ascvd_events.R", "src/phenotype/R/extract_death.R",
              "src/ascvd/prevent/run_prevent.R"))
    if (file.exists(p)) source(p)
  fx <- "fixture/db/aou_fixture.duckdb"
  if (!file.exists(fx)) stop("fixture not built: see docs/environment.md")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  # The fixture's condition dates run 2009-2021, so a 2015 landmark leaves usable follow-up.
  make_incidence_figures(con, outdir = "reports/figures_fixture_demo",
                         landmark = as.Date("2015-01-01"),
                         end_of_followup = as.Date("2022-01-01"))
}
