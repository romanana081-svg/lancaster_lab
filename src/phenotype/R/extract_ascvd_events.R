# extract_ascvd_events.R — ASCVD event ascertainment: timing, type, stage. T-015, D-014.
#
# WHAT THIS PRODUCES
#
# One row per (person, ascvd_class) with the FIRST date that class was coded, the code that produced
# it, and how many codes/dates the person has in that class. Deliberately NOT one row per person:
# collapsing to a single binary "had CAD" is exactly what the old notebook's `codes_df` did, and it
# throws away the two things the advisor asked us to keep (D-014) -- WHEN the event happened and WHAT
# TYPE/STAGE of disease it is.
#
# THE THREE CLASSES ARE STILL TRACKED SEPARATELY, BUT ALL THREE NOW COUNT AS THE OUTCOME
# (advisor, 2026-07-31 — D-016; configs/ascvd_codes.yaml is the reviewable definition):
#
#   acute_event       — MI, acute ischemic events, ischemic stroke. A first-ever code here IS an event
#                       date. This is the HARD outcome, and the only one comparable to the published
#                       PREVENT event rate.
#   chronic_disease   — chronic IHD, angina, atherosclerosis, bypass-graft history. A first-ever code
#                       here is a DIAGNOSIS date, not necessarily an event date.
#   revascularisation — PCI/CABG. A TREATMENT DECISION confounded by healthcare access (Q-A1).
#
# All three count both as PREVALENT disease at baseline (D-013, unchanged) and as INCIDENT disease
# during follow-up (D-016, new). The classes are still carried on every row, so every result can be
# reported with the broad definition AND with acute-only — which is not optional: the literature
# benchmark only applies to acute-only, and the two definitions will not produce the same rate.
#
# WHY THE ANCHOR (Q-S6) DOES NOT APPEAR HERE, ON PURPOSE
#
# "When was this person's first ASCVD code?" is a fact about the person, not about our choice of
# baseline T0. So this file computes event dates and NOTHING ELSE; the anchor decides only how those
# dates are USED (prevalent vs incident, and how much follow-up), which is `ascvd_status_at()` below
# and takes T0 as an argument. That separation is what keeps the deferred anchor decision (D-015) from
# leaking a de-facto anchor into the ETL -- the A-001 trap.
#
# CDR SCALE: all the reduction (class assignment, first-date pick, counting) happens in SQL. The real
# condition_occurrence table is ~10^8 rows; nothing raw comes over the wire. Portable constructs only
# (CAST AS DATE, LIKE, MIN/COUNT, UNION ALL), so it runs identically on the DuckDB fixture and on
# BigQuery in the Workbench (D-003).
#
# TWO KNOWN LIMITATIONS, BOTH MEASURED RATHER THAN GUESSED (see check_ascvd_events.R):
#   1. ICD9CM. The config lists ICD10CM prefixes. All of Us EHR records before ~Oct-2015 are coded
#      ICD9CM, so pre-2015 events are MISSED unless ICD9 prefixes are added. `audit_ascvd_codes()`
#      counts how many rows that is, so the gap is sized before anyone decides to accept it.
#   2. The CPT prefix "929" is BROADER than its own comment claims ("92920-92944: PCI"): it also
#      matches 92950 CPR, 92953 pacing, 92960 cardioversion, 92986+ valvuloplasty. `audit_ascvd_codes()`
#      reports every distinct code the definition actually captures, with counts, so the list can be
#      pruned against evidence instead of from memory (the NEEDS_A_CODE_LIST discipline).

suppressPackageStartupMessages({ library(dplyr) })

.ASCVD_CODES_DEFAULT <- "configs/ascvd_codes.yaml"

#' Load the ASCVD outcome definition from its config.
#'
#' The config IS the outcome definition (D-014) -- it is read at runtime rather than transcribed into
#' R, so that editing the reviewable YAML actually changes behaviour. A definition that lives in two
#' places drifts.
#'
#' @param path  path to ascvd_codes.yaml. Searched relative to the working directory and then two
#'   levels up, so this works from the repo root and from tests/testthat.
#' @return list(codes = data.frame(code_prefix, class, vocabulary_id, note),
#'              excluded = data.frame(code_prefix, reason))
#'   `codes` preserves the config's ORDER, which is load-bearing: classification is first-match-wins,
#'   acute before chronic.
load_ascvd_codes <- function(path = .ASCVD_CODES_DEFAULT) {
  if (!file.exists(path)) {
    alt <- file.path("..", "..", path)
    if (file.exists(alt)) path <- alt else
      stop(sprintf("load_ascvd_codes(): cannot find %s from %s", path, getwd()), call. = FALSE)
  }
  y <- yaml::read_yaml(path)
  if (is.null(y$ascvd) || length(y$ascvd) == 0)
    stop("load_ascvd_codes(): the `ascvd:` block is empty -- that would silently produce zero events.",
         call. = FALSE)

  codes <- do.call(rbind, lapply(y$ascvd, function(e) {
    if (is.null(e$code_prefix) || is.null(e$class))
      stop("load_ascvd_codes(): every ascvd entry needs both `code_prefix` and `class`.", call. = FALSE)
    data.frame(code_prefix = as.character(e$code_prefix),
               class       = as.character(e$class),
               # Vocabulary is inferred from the class unless stated: revascularisation is CPT4
               # (procedures), everything else ICD10CM (conditions). Stating it explicitly in the
               # config overrides this -- which is how ICD9CM prefixes get added if we decide to.
               vocabulary_id = as.character(e$vocabulary %||%
                                 if (identical(e$class, "revascularisation")) "CPT4" else "ICD10CM"),
               note = as.character(e$note %||% NA_character_),
               stringsAsFactors = FALSE)
  }))

  excluded <- if (length(y$excluded_deliberately %||% list())) {
    do.call(rbind, lapply(y$excluded_deliberately, function(e)
      data.frame(code_prefix = as.character(e$code_prefix),
                 reason = as.character(e$reason %||% NA_character_), stringsAsFactors = FALSE)))
  } else data.frame(code_prefix = character(0), reason = character(0))

  # A prefix that is BOTH included and deliberately excluded is a contradiction in the definition,
  # and first-match-wins would resolve it silently. Refuse.
  clash <- intersect(codes$code_prefix, excluded$code_prefix)
  if (length(clash))
    stop(sprintf(paste0("load_ascvd_codes(): %s appears in BOTH `ascvd` and `excluded_deliberately`.\n",
                        "  The outcome definition contradicts itself; fix the config."),
                 paste(clash, collapse = ", ")), call. = FALSE)

  list(codes = codes, excluded = excluded)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Build the first-match-wins CASE expression that assigns an ascvd_class in SQL.
#'
#' Mirrors classify_ascvd_concept()'s semantics (first matching prefix wins, config order) but pushes
#' it into the database so the class is assigned without pulling rows out. Keeping the two in step
#' matters: if they ever disagree, the audit and the extractor describe different outcomes.
#'
#' @param codes  the `codes` frame from load_ascvd_codes(), already filtered to one vocabulary.
#' @param col    the SQL expression holding the concept code.
.ascvd_class_case_sql <- function(codes, col = "c.concept_code") {
  if (nrow(codes) == 0) return("NULL")
  whens <- sprintf("      WHEN %s LIKE '%s%%' THEN '%s'", col, codes$code_prefix, codes$class)
  paste0("CASE\n", paste(whens, collapse = "\n"), "\n    END")
}

.ascvd_prefix_filter_sql <- function(codes, col = "c.concept_code") {
  if (nrow(codes) == 0) return("FALSE")
  paste(sprintf("%s LIKE '%s%%'", col, codes$code_prefix), collapse = " OR ")
}

#' Extract per-person, per-class first ASCVD event dates.
#'
#' @param con    an open DBI connection (BigQuery in the Workbench, the DuckDB fixture offline).
#' @param codes_path  path to the outcome definition config.
#' @return data.frame(person_id, ascvd_class, first_date, first_code, n_codes, n_dates, source_table)
#'   -- one row per person per class present. A person with no ASCVD codes at all does not appear;
#'   that is deliberate (see `ascvd_status_at()`, which takes the cohort as its left side).
extract_ascvd_events <- function(con, codes_path = .ASCVD_CODES_DEFAULT) {
  def   <- load_ascvd_codes(codes_path)
  codes <- def$codes

  cond_codes <- codes[codes$vocabulary_id %in% c("ICD10CM", "ICD9CM"), , drop = FALSE]
  proc_codes <- codes[codes$vocabulary_id %in% c("CPT4", "ICD10PCS"), , drop = FALSE]

  parts <- character(0)

  # CONDITIONS. ICD10CM lives on condition_source_concept_id, NOT the standard column -- the standard
  # column is SNOMED, and matching ICD prefixes against it returns zero rows with no error. That
  # linkage was confirmed against the real CDR (113M ICD10CM rows on the source column).
  if (nrow(cond_codes)) {
    parts <- c(parts, sprintf("
    SELECT o.person_id,
           CAST(o.condition_start_date AS DATE) AS dt,
           c.concept_code                       AS code,
           %s AS ascvd_class,
           'condition' AS source_table
    FROM condition_occurrence o
    JOIN concept c ON c.concept_id = o.condition_source_concept_id
    WHERE c.vocabulary_id IN (%s)
      AND o.condition_start_date IS NOT NULL
      AND (%s)",
      .ascvd_class_case_sql(cond_codes),
      paste(sprintf("'%s'", unique(cond_codes$vocabulary_id)), collapse = ", "),
      .ascvd_prefix_filter_sql(cond_codes)))
  }

  # PROCEDURES. CPT4 lives on procedure_source_concept_id, same reasoning as above.
  if (nrow(proc_codes)) {
    parts <- c(parts, sprintf("
    SELECT p.person_id,
           CAST(p.procedure_date AS DATE) AS dt,
           c.concept_code                 AS code,
           %s AS ascvd_class,
           'procedure' AS source_table
    FROM procedure_occurrence p
    JOIN concept c ON c.concept_id = p.procedure_source_concept_id
    WHERE c.vocabulary_id IN (%s)
      AND p.procedure_date IS NOT NULL
      AND (%s)",
      .ascvd_class_case_sql(proc_codes),
      paste(sprintf("'%s'", unique(proc_codes$vocabulary_id)), collapse = ", "),
      .ascvd_prefix_filter_sql(proc_codes)))
  }

  if (!length(parts))
    stop("extract_ascvd_events(): the config produced no queryable codes.", call. = FALSE)

  # The first-date pick and the counting happen server-side. `first_code` is MIN(code) among the codes
  # on the first date -- an explicit, deterministic tie-break, in the spirit of D-009: an arbitrary
  # surviving row is how results stop being reproducible.
  sql <- sprintf("
  WITH ev AS (%s
  ),
  agg AS (
    SELECT person_id, ascvd_class,
           MIN(dt)             AS first_date,
           COUNT(*)            AS n_codes,
           COUNT(DISTINCT dt)  AS n_dates
    FROM ev
    WHERE ascvd_class IS NOT NULL
    GROUP BY person_id, ascvd_class
  )
  SELECT a.person_id, a.ascvd_class, a.first_date,
         MIN(e.code)          AS first_code,
         MIN(e.source_table)  AS source_table,
         a.n_codes, a.n_dates
  FROM agg a
  JOIN ev  e ON e.person_id = a.person_id
            AND e.ascvd_class = a.ascvd_class
            AND e.dt = a.first_date
  GROUP BY a.person_id, a.ascvd_class, a.first_date, a.n_codes, a.n_dates
  ORDER BY a.person_id, a.ascvd_class",
    paste(parts, collapse = "\n    UNION ALL"))

  out <- DBI::dbGetQuery(con, sql)
  out$person_id  <- as.numeric(out$person_id)   # bigrquery returns integer64; normalise for joins
  out$first_date <- as.Date(out$first_date)
  out
}

#' Reduce per-class events to ONE first-event date per person, for a chosen outcome definition.
#'
#' @param events  the frame from extract_ascvd_events().
#' @param classes which classes count as "the outcome". The default is `acute_event` ONLY, because
#'   that is what PREVENT predicts. Pass c("acute_event","revascularisation") to produce the
#'   with-revascularisation version -- Q-A1 requires the outcome be reportable BOTH ways, so this is
#'   an argument and not a hardcoded choice.
#' @return data.frame(person_id, event_date, event_class, event_code)
first_ascvd_event <- function(events, classes = "acute_event") {
  stopifnot(is.data.frame(events))
  unknown <- setdiff(classes, c("acute_event", "chronic_disease", "revascularisation"))
  if (length(unknown))
    stop(sprintf("first_ascvd_event(): unknown class(es): %s", paste(unknown, collapse = ", ")),
         call. = FALSE)

  e <- events[events$ascvd_class %in% classes, , drop = FALSE]
  if (nrow(e) == 0)
    return(data.frame(person_id = numeric(0), event_date = as.Date(character(0)),
                      event_class = character(0), event_code = character(0)))

  e %>%
    arrange(.data$person_id, .data$first_date, .data$ascvd_class) %>%
    group_by(.data$person_id) %>%
    slice(1L) %>%
    ungroup() %>%
    transmute(person_id  = .data$person_id,
              event_date = .data$first_date,
              event_class = .data$ascvd_class,
              event_code  = .data$first_code) %>%
    as.data.frame()
}

#' Classify each cohort member as PREVALENT / INCIDENT / EVENT-FREE relative to a baseline date.
#'
#' THIS is where the Q-S6 anchor enters, and it enters as an ARGUMENT. Nothing upstream of here has
#' assumed a baseline.
#'
#' The prevalence test deliberately uses a BROADER code set than the incident-event test: someone
#' whose only ASCVD code is chronic IHD still HAS atherosclerotic disease and must be excluded at
#' baseline (D-013), even though a chronic code would not be counted as an incident event. Using the
#' same narrow set for both is a real error -- it leaves prevalent cases in the at-risk set, where
#' their subsequent codes get counted as incident events.
#'
#' @param cohort   data.frame with `person_id` and a baseline date column.
#' @param events   the frame from extract_ascvd_events().
#' @param anchor_col      name of the baseline (T0) date column in `cohort`.
#' @param event_classes   classes that count as an incident EVENT. ADVISOR DECISION 2026-07-31
#'   (D-016): **all three**. A chronic ASCVD diagnosis, an acute event, and a revascularisation all
#'   count as incidence of ASCVD. Pass `"acute_event"` explicitly for the hard-outcome sensitivity
#'   analysis -- that is the one comparable to the published PREVENT rate.
#' @param prevalent_classes classes that make someone PREVALENT at baseline (all three --
#'   a revascularisation before baseline is unambiguous evidence of established disease).
#' @param end_of_followup  the administrative censoring date (CDR cutoff). Required: without it,
#'   event-free people have no follow-up time and no survival model is possible.
#' @param min_days_panel_to_event  ADVISOR DECISION 2026-07-31 (D-017): a participant counts only if
#'   their complete PREVENT panel predates the event by at least this many days. Default 30. See the
#'   note below on why this is implemented as a symmetric blanking window rather than a filter on
#'   cases; set to 0 to disable.
#' @return `cohort` plus: ascvd_status ("prevalent"/"excluded_short_interval"/"incident"/
#'   "event_free"), event_date, event_class, event_code, risk_start_date, followup_days,
#'   event (1/0 for the at-risk set, NA for everyone excluded).
ascvd_status_at <- function(cohort, events, anchor_col = "baseline_date",
                           event_classes = c("acute_event", "chronic_disease",
                                             "revascularisation"),
                           prevalent_classes = c("acute_event", "chronic_disease",
                                                 "revascularisation"),
                           end_of_followup = NULL,
                           min_days_panel_to_event = 30) {
  stopifnot(is.data.frame(cohort), "person_id" %in% names(cohort))
  if (!anchor_col %in% names(cohort))
    stop(sprintf("ascvd_status_at(): cohort has no column `%s`. The baseline anchor (Q-S6) must be
  computed and passed in explicitly -- this function will not invent one.", anchor_col),
         call. = FALSE)
  if (is.null(end_of_followup))
    stop("ascvd_status_at(): `end_of_followup` is required (the CDR cutoff date). Without it,
  event-free participants get no follow-up time, and person-time is what an incidence rate is
  divided by.", call. = FALSE)

  end_of_followup <- as.Date(end_of_followup)
  t0 <- as.Date(cohort[[anchor_col]])

  ev_first  <- first_ascvd_event(events, classes = event_classes)
  prev_any  <- first_ascvd_event(events, classes = prevalent_classes)
  names(prev_any)[names(prev_any) == "event_date"] <- "any_ascvd_first_date"

  out <- cohort
  out$baseline_date <- t0
  out$any_ascvd_first_date <-
    prev_any$any_ascvd_first_date[match(out$person_id, prev_any$person_id)]
  m <- match(out$person_id, ev_first$person_id)
  out$event_date  <- ev_first$event_date[m]
  out$event_class <- ev_first$event_class[m]
  out$event_code  <- ev_first$event_code[m]

  # PREVALENT: any qualifying ASCVD code on or before baseline. `<=` and not `<`: a code recorded on
  # the baseline date itself is not an event we could have predicted from that day's labs.
  prevalent <- !is.na(out$any_ascvd_first_date) & out$any_ascvd_first_date <= out$baseline_date

  # --- the 30-day rule (D-017) ---------------------------------------------------------------------
  # The advisor's rule: a person counts only if their complete PREVENT panel predates the event by at
  # least 30 days. Its purpose is to stop the panel being measured BY the event -- lipids and a BP
  # drawn during an MI admission are a consequence of the disease, not a prediction of it.
  #
  # WHY A BLANKING WINDOW AND NOT A FILTER ON CASES. Read literally, the rule removes cases whose
  # panel is too close to their event and touches nobody else. But the person-time those cases
  # contributed in that first 30 days would still sit in the denominator, so events would be deleted
  # while their exposure time was kept -- every incidence rate biased DOWN, with no bug visible
  # anywhere. The fix is to move the clock rather than only the numerator: NOBODY is at risk until
  # baseline + 30 days, so the removed events and the removed person-time are the same 30 days. That
  # is the symmetric reading, it reduces to the advisor's rule exactly for cases, and it is well
  # defined for the non-cases the literal reading says nothing about (the Q-S6 asymmetry trap, A-001).
  stopifnot(is.numeric(min_days_panel_to_event), length(min_days_panel_to_event) == 1,
            min_days_panel_to_event >= 0)
  risk_start <- out$baseline_date + min_days_panel_to_event

  # Excluded: an event inside the blanking window. NOT prevalent (the disease came after baseline) and
  # NOT at risk (we cannot claim the panel predates it by the required margin) -- so it is its own
  # status, and it is COUNTED rather than quietly dropped, because it is an attrition number the
  # advisor will ask for.
  short <- !prevalent & !is.na(out$event_date) &
           out$event_date > out$baseline_date & out$event_date <= risk_start

  # INCIDENT: a qualifying event strictly after the blanking window, within follow-up.
  incident <- !prevalent & !short & !is.na(out$event_date) &
              out$event_date > risk_start & out$event_date <= end_of_followup

  out$risk_start_date <- risk_start
  out$ascvd_status <- ifelse(prevalent, "prevalent",
                      ifelse(short, "excluded_short_interval",
                      ifelse(incident, "incident", "event_free")))

  # An incident case's own event date is not the outcome date if it precedes baseline -- already
  # handled above -- but an event AFTER the CDR cutoff must not be counted either, so blank it.
  out$event_date[!incident]  <- as.Date(NA)
  out$event_class[!incident] <- NA_character_
  out$event_code[!incident]  <- NA_character_

  # Follow-up is measured from risk_start, not from baseline: the blanking window is time nobody was
  # observed at risk, so counting it as exposure would dilute every rate by exactly the amount the
  # rule was supposed to leave untouched.
  out$followup_days <- ifelse(
    out$ascvd_status == "incident", as.numeric(out$event_date - risk_start),
    ifelse(out$ascvd_status == "event_free", as.numeric(end_of_followup - risk_start), NA))
  # Prevalent and short-interval people are not in the at-risk set at all, so `event` is NA rather
  # than 0: coding them 0 would silently add them to the denominator of every incidence rate.
  out$event <- ifelse(out$ascvd_status == "incident", 1L,
                      ifelse(out$ascvd_status == "event_free", 0L, NA_integer_))

  # A negative follow-up time means the risk-start date is after the CDR cutoff -- a data or config
  # error, not something to average over. Note risk_start = baseline + min_days_panel_to_event, so a
  # baseline within 30 days of the cutoff now trips this where it previously would not have.
  bad <- !is.na(out$followup_days) & out$followup_days < 0
  if (any(bad))
    warning(sprintf(paste0("ascvd_status_at(): %d participant(s) have NEGATIVE follow-up (risk start
  = baseline + %d days is after end_of_followup = %s). Check the anchor, not the events."),
                    sum(bad), min_days_panel_to_event, end_of_followup), call. = FALSE)

  out
}
