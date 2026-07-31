# risk_set_sampling.R — the case-anchored cohort. D-019.
#
# THE DESIGN, in one line: every case is anchored at their own event date minus a washout (30 days,
# D-017), and for each case we sample controls who were event-free AT THAT MOMENT and anchor them at
# the SAME date.
#
# WHY THIS SHAPE. The requirement was "30 days before the event, for each person" -- no shared
# calendar landmark. That defines a baseline for cases and for nobody else (Q-S6). Risk-set sampling
# (a.k.a. incidence-density sampling) resolves it without inventing an anchor: each case brings its
# own anchor date, and its controls borrow it. Cases and controls are therefore anchored at the same
# instant BY CONSTRUCTION rather than by assumption, which is exactly the asymmetry A-001 warns about,
# closed rather than argued about.
#
# TWO PROPERTIES THAT LOOK LIKE BUGS AND ARE NOT:
#
#   1. A control may LATER become a case. That is correct and deliberate. A control represents the
#      person-time at risk at that instant, not "a person who never has an event". Excluding future
#      cases would bias the sampled odds ratio away from the rate ratio -- it is the classic error in
#      this design. Their later event is not hidden: it is on the row (`becomes_case_later`).
#   2. The same person can be sampled for more than one risk set. Also correct, same reason.
#
# WEIGHTS, AND WHY THEY MATTER HERE. Each control carries `weight` = (eligible in its risk set) /
# (sampled from it). Discrimination (C-index) and the offset-Cox test on gamma are valid on the
# unweighted sample. **Absolute calibration is not** -- a 10:1 sample has an event rate ~10x the
# cohort's, so "predicted 8% vs observed 8%" is meaningless without weighting back. Since detecting
# PREVENT's miscalibration in All of Us is the whole point of DESIGN stage 5 (and the thing a genetic
# term would otherwise silently absorb), the weights are computed here rather than left to whoever
# remembers.

#' Sample risk sets: pure function, no database. This is the part worth unit-testing.
#'
#' @param cases    data.frame(person_id, anchor_date) -- one row per case, already washed out.
#' @param eligible data.frame(person_id, panel_ready_date, first_ascvd_date). `panel_ready_date` is
#'   the date that person's PREVENT panel became complete (NA = never); `first_ascvd_date` is their
#'   first ASCVD code of any class (NA = none ever).
#' @param ratio    controls per case. 10 unless there is a reason.
#' @param seed     REQUIRED. Sampling without a recorded seed is not reproducible, and a cohort you
#'   cannot rebuild is not a cohort.
#' @return data.frame(risk_set_id, person_id, role, anchor_date, weight, becomes_case_later)
sample_risk_sets <- function(cases, eligible, ratio = 10, seed = NULL) {
  stopifnot(is.data.frame(cases), is.data.frame(eligible),
            all(c("person_id", "anchor_date") %in% names(cases)),
            all(c("person_id", "panel_ready_date", "first_ascvd_date") %in% names(eligible)))
  if (is.null(seed))
    stop("sample_risk_sets(): `seed` is required. A sampled cohort that cannot be rebuilt bit-for-bit
  is not reproducible, and every downstream number inherits that.", call. = FALSE)
  if (!nrow(cases)) stop("sample_risk_sets(): no cases.", call. = FALSE)
  set.seed(seed)

  el_id    <- eligible$person_id
  el_ready <- as.Date(eligible$panel_ready_date)
  el_event <- as.Date(eligible$first_ascvd_date)
  anchors  <- as.Date(cases$anchor_date)

  out <- vector("list", nrow(cases))
  for (i in seq_len(nrow(cases))) {
    a <- anchors[i]
    # AT RISK AT `a` means: the panel was already complete by then (we can score them), and they had
    # not yet had any ASCVD code (they were still at risk of a first event). `>` not `>=` on the event
    # date: someone coded on the anchor date itself is no longer event-free at that instant.
    ok <- !is.na(el_ready) & el_ready <= a &
          (is.na(el_event) | el_event > a) &
          el_id != cases$person_id[i]
    n_elig <- sum(ok)
    if (n_elig == 0) next

    pick <- if (n_elig <= ratio) which(ok) else sample(which(ok), ratio)
    # weight = how many people in the cohort each sampled control stands for. Cases are weight 1:
    # they are all taken, none are sampled.
    w <- n_elig / length(pick)

    out[[i]] <- data.frame(
      risk_set_id = i,
      person_id   = c(cases$person_id[i], el_id[pick]),
      role        = c("case", rep("control", length(pick))),
      anchor_date = a,
      weight      = c(1, rep(w, length(pick))),
      # A control whose own first ASCVD code comes later. Not an error (see the header) -- but it is
      # recorded, because someone will ask, and "we checked" is a different answer from "we didn't".
      becomes_case_later = c(FALSE, !is.na(el_event[pick])),
      n_eligible_in_set  = n_elig,
      stringsAsFactors = FALSE)
  }

  res <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  if (is.null(res) || !nrow(res))
    stop("sample_risk_sets(): every risk set was empty -- no one had a complete panel before any
  case's anchor date. Check panel_ready_date, not the sampler.", call. = FALSE)
  attr(res, "seed")  <- seed
  attr(res, "ratio") <- ratio
  res
}

#' Build the case-anchored cohort from a CDR connection.
#'
#' @param con       open DBI connection.
#' @param events    output of extract_ascvd_events().
#' @param washout_days  D-017: the panel must predate the event by at least this many days, so the
#'   case's anchor is event_date - washout_days.
#' @param ratio,seed  passed to sample_risk_sets().
#' @param event_classes  which classes count as the event (D-016 default: all three).
#' @return list(cohort = the sampled frame, cases = all cases before sampling, dropped = attrition)
build_case_anchored_cohort <- function(con, events, washout_days = 30, ratio = 10, seed = 20260731,
                                       event_classes = c("acute_event", "chronic_disease",
                                                         "revascularisation")) {
  stopifnot(exists("first_ascvd_event", mode = "function"))

  # --- when did each person's panel FIRST become complete? -----------------------------------------
  # EARLIEST here, not latest: we need the first date from which a person could be scored at all, so
  # that they are eligible as a control from that day on. (Contrast extract_prevent_panel()'s
  # panel_date, which is the latest of a most-recent panel -- a different question.)
  ready <- DBI::dbGetQuery(con, "
    WITH firsts AS (
      SELECT m.person_id, c.concept_code AS code,
             MIN(CAST(m.measurement_date AS DATE)) AS first_dt
      FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
      WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
        AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
      GROUP BY m.person_id, c.concept_code
    )
    SELECT person_id, MAX(first_dt) AS panel_ready_date, COUNT(*) AS n_inputs
    FROM firsts GROUP BY person_id")
  # MAX over the five firsts = the day the LAST missing input arrived = the day the panel completed.
  # n_inputs < 5 means it never completed; such a person can never be scored, so they are not
  # eligible as a control either.
  ready$panel_ready_date <- as.Date(ready$panel_ready_date)
  ready$panel_ready_date[ready$n_inputs < 5] <- as.Date(NA)

  # --- first ASCVD code of any class, for the at-risk test ------------------------------------------
  any_ascvd <- first_ascvd_event(events, c("acute_event", "chronic_disease", "revascularisation"))
  ready$first_ascvd_date <- any_ascvd$event_date[match(ready$person_id, any_ascvd$person_id)]

  # --- cases, anchored at event - washout ----------------------------------------------------------
  ev <- first_ascvd_event(events, event_classes)
  ev$anchor_date <- ev$event_date - washout_days
  ev$panel_ready_date <- ready$panel_ready_date[match(ev$person_id, ready$person_id)]

  n_events_total <- nrow(ev)
  # THE ADVISOR'S RULE, applied: the panel must be complete on or before the anchor, i.e. at least
  # `washout_days` before the event. A case whose panel completes later is EXCLUDED -- their inputs
  # would have been measured too close to (or after) the event to be a prediction.
  keep <- !is.na(ev$panel_ready_date) & ev$panel_ready_date <= ev$anchor_date
  cases <- ev[keep, c("person_id", "event_date", "event_class", "anchor_date"), drop = FALSE]

  dropped <- data.frame(
    step = c("first ASCVD event (any class in event_classes)",
             sprintf("...with a complete panel >= %d days before it (D-017)", washout_days),
             "...excluded: panel completed too late or never"),
    n = c(n_events_total, nrow(cases), n_events_total - nrow(cases)),
    stringsAsFactors = FALSE)

  if (!nrow(cases))
    stop(sprintf("build_case_anchored_cohort(): %d events, but NONE has a complete PREVENT panel at
  least %d days beforehand. That is a finding about coverage, not a bug -- check panel_ready_date
  against event dates before changing anything.", n_events_total, washout_days), call. = FALSE)

  cohort <- sample_risk_sets(cases, ready[, c("person_id", "panel_ready_date", "first_ascvd_date")],
                             ratio = ratio, seed = seed)
  # carry the case's own event info onto its row
  m <- match(cohort$person_id, cases$person_id)
  cohort$event_date  <- as.Date(ifelse(cohort$role == "case", cases$event_date[m], NA),
                                origin = "1970-01-01")
  cohort$event_class <- ifelse(cohort$role == "case", cases$event_class[m], NA_character_)
  cohort$event <- as.integer(cohort$role == "case")

  list(cohort = cohort, cases = cases, dropped = dropped, ready = ready,
       params = list(washout_days = washout_days, ratio = ratio, seed = seed,
                     event_classes = event_classes))
}

#' Attach PREVENT inputs measured AS OF each person's own anchor date.
#'
#' One query, not one per person: the (person_id, anchor_date) pairs are joined in as an inline table
#' and the measurement filter is `dt <= anchor`. Chunked because an inline anchor list of 100k rows
#' is not something to send to BigQuery in one statement.
#'
#' PORTABILITY, THE HARD-WON BIT: the anchor table is built as `SELECT ... UNION ALL SELECT ...`,
#' NOT as `WITH anchor(person_id, anchor_date) AS (VALUES ...)`. The VALUES form works in DuckDB and
#' is a **syntax error in BigQuery** -- which would have passed every offline test and then failed on
#' the first Workbench run, i.e. the exact failure mode D-003 exists to prevent. UNION ALL and
#' `DATE 'YYYY-MM-DD'` literals are valid in both.
#'
#' @param con     open DBI connection.
#' @param cohort  the `cohort` frame from build_case_anchored_cohort().
#' @param chunk   rows per query. Kept modest: BigQuery caps query text at ~1 MB, and each anchor row
#'   costs ~55 characters of SQL.
#' @return `cohort` with sbp, total_c, hdl_c, creatinine, bmi, a1c attached (most recent value on or
#'   before that row's anchor_date; same-day ties averaged, D-009).
attach_panel_at_anchor <- function(con, cohort, chunk = 2000L) {
  stopifnot(all(c("person_id", "anchor_date") %in% names(cohort)))
  key <- unique(cohort[, c("person_id", "anchor_date")])
  parts <- split(key, ceiling(seq_len(nrow(key)) / chunk))

  got <- lapply(parts, function(k) {
    vals <- paste(sprintf("SELECT %s AS person_id, DATE '%s' AS anchor_date",
                          format(k$person_id, scientific = FALSE),
                          format(as.Date(k$anchor_date), "%Y-%m-%d")), collapse = " UNION ALL ")
    DBI::dbGetQuery(con, sprintf("
      WITH anchor AS (%s),
      bounded AS (
        SELECT m.person_id, c.concept_code AS code, m.value_as_number AS value,
               CAST(m.measurement_date AS DATE) AS dt
        FROM measurement m
        JOIN concept c ON c.concept_id = m.measurement_concept_id
        JOIN anchor a  ON a.person_id  = m.person_id
        WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
          AND CAST(m.measurement_date AS DATE) <= a.anchor_date
          AND ( (c.concept_code = '2093-3'  AND m.value_as_number > 50  AND m.value_as_number < 500)
             OR (c.concept_code = '2085-9'  AND m.value_as_number > 10  AND m.value_as_number < 150)
             OR (c.concept_code = '8480-6'  AND m.value_as_number > 60  AND m.value_as_number < 250)
             OR (c.concept_code = '2160-0'  AND m.value_as_number > 0.1 AND m.value_as_number < 20)
             OR (c.concept_code = '39156-5' AND m.value_as_number > 10  AND m.value_as_number < 80)
             OR (c.concept_code IN ('4548-4','17856-6') AND m.value_as_number > 3
                 AND m.value_as_number < 20) )
      ),
      latest AS (
        SELECT person_id, code, value, dt, MAX(dt) OVER (PARTITION BY person_id, code) AS max_dt
        FROM bounded
      )
      SELECT person_id, code, AVG(value) AS value
      FROM latest WHERE dt = max_dt GROUP BY person_id, code", vals))
  })

  long <- do.call(rbind, got)
  cols <- c("total_c", "hdl_c", "sbp", "creatinine", "bmi", "a1c")

  # No measurements at or before the anchor is a legitimate answer -- it means nobody in this set was
  # scorable that early. Return the cohort with NA inputs rather than erroring: the caller's
  # complete-case filter is what should drop them, and it can only do that if the rows come back.
  if (is.null(long) || !nrow(long)) {
    for (nm in cols) cohort[[nm]] <- NA_real_
    return(cohort)
  }

  code_map <- c("2093-3" = "total_c", "2085-9" = "hdl_c", "8480-6" = "sbp",
                "2160-0" = "creatinine", "39156-5" = "bmi", "4548-4" = "a1c", "17856-6" = "a1c")
  long$col <- unname(code_map[long$code])
  long <- stats::aggregate(value ~ person_id + col, data = long, FUN = mean)
  wide <- stats::reshape(long, idvar = "person_id", timevar = "col", direction = "wide")
  names(wide) <- sub("^value\\.", "", names(wide))
  for (nm in cols)
    if (!nm %in% names(wide)) wide[[nm]] <- NA_real_

  merge(cohort, wide, by = "person_id", all.x = TRUE, sort = FALSE)
}
