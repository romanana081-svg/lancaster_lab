# clean_measurement.R — the per-domain cleaning idiom, lifted out of the notebook (T-005, D-002).
#
# Nearly every "Format" section of `LDLR Get phenotypes.ipynb` repeats the same six-step pipeline.
# This is that pipeline, once, with its choices made into ARGUMENTS instead of literals — because
# every one of those literals is a scientific choice, and a choice buried in code is a choice nobody
# can review (loop.md, rule 2).
#
# Behaviour is bit-compatible with the notebook by DEFAULT. Nothing here silently improves on it.
# Where the notebook is wrong, the fix is available but must be opted into, and the open decision is
# named. See A-001, A-002, A-003, A-004.

suppressPackageStartupMessages(library(dplyr))

#' Normalise an All of Us unit string.
#'
#' A-003: the notebook filters `unit_source_value == 'mg/dL'` — case-sensitive and exact. So
#' `mg/dl`, `MG/DL`, and `'mg/dL '` (trailing space) are silently dropped, and a person whose ONLY
#' lipid panel is recorded in lowercase vanishes from the analysis with no warning. The fixture
#' reproduces this (participant 1000021, defect A1): their LDL of 135 is simply lost.
#'
#' This is off by default, because turning it on CHANGES THE COHORT — which is a decision, not a
#' cleanup.
normalise_unit <- function(x) {
  x <- trimws(as.character(x))
  tolower(x)
}

#' Reduce a raw OMOP measurement table to exactly one row per person.
#'
#' @param df            raw measurement rows (person_id, value, date, unit columns)
#' @param value_col     name of the value column (e.g. "value_as_number")
#' @param date_col      name of the datetime column (e.g. "measurement_datetime")
#' @param unit_col      name of the unit column (e.g. "unit_source_value")
#' @param units         accepted unit strings. Compared exactly, unless `normalise_units = TRUE`.
#' @param bounds        list(min=, max=) — non-physiologic values are dropped. A-004.
#' @param anchor        which record per person to keep: "earliest" (the notebook's choice) or
#'                      "latest". A-001 — for a PREDICTION study "earliest" is probably WRONG; the
#'                      correct anchor is the value at the index date, which is still open (Q-S1).
#' @param tiebreak      how to resolve MULTIPLE records on the anchor date. See below. A-002.
#' @param normalise_units  A-003. FALSE reproduces the notebook (and its silent data loss).
#' @param out_names     names for the returned (person_id, value, date) columns.
#'
#' @section The tiebreak, and why it is not a detail:
#' A-002 is **REFUTED as safe**. The notebook ends every domain with
#' `distinct(person_id, .keep_all = TRUE)`, which keeps whichever row happens to come first — and
#' the generated SQL has **no `ORDER BY`**, so "first" is arbitrary and can differ between runs.
#' The fixture proves it: participant 1000006 has same-day LDL values of 130, 131 and 132, and the
#' answer key can only assert membership (`one_of:130|131|132`), not a value. **Results are not
#' bit-reproducible today.**
#'
#' `tiebreak = "first"` reproduces that (and warns). The deterministic options are "mean", "min",
#' "max", and "median". **Which one we adopt is an open decision** — it is a real choice with
#' scientific consequences (a mean smooths measurement error; a min is conservative for a risk
#' factor), and it must be settled before anything is published. Tracked in `configs/config.yaml`
#' as `record_selection.same_day_tiebreak: UNRESOLVED`.
clean_measurement <- function(df,
                              value_col = "value_as_number",
                              date_col  = "measurement_datetime",
                              unit_col  = "unit_source_value",
                              units,
                              bounds,
                              anchor = c("earliest", "latest"),
                              tiebreak = c("first", "mean", "min", "max", "median"),
                              normalise_units = FALSE,
                              out_names = c("person_id", "value", "date")) {
  anchor   <- match.arg(anchor)
  tiebreak <- match.arg(tiebreak)

  stopifnot(is.data.frame(df))
  for (col in c("person_id", value_col, date_col, unit_col)) {
    if (!col %in% names(df)) stop(sprintf("clean_measurement(): missing column '%s'", col))
  }

  d <- df
  d$.value <- suppressWarnings(as.numeric(d[[value_col]]))
  d$.date  <- as.Date(d[[date_col]])
  d$.unit  <- d[[unit_col]]

  # 1. keep one consistent unit. A-003.
  accept <- units
  if (normalise_units) {
    d$.unit <- normalise_unit(d$.unit)
    accept  <- normalise_unit(units)
  }
  d <- d[!is.na(d$.unit) & d$.unit %in% accept, , drop = FALSE]

  # 2. drop non-physiologic values. A-004.
  #    NOTE the notebook's LDL cap of <400 is NOT hardcoded here: it would delete untreated familial
  #    hypercholesterolemia carriers — exactly the people a rare-variant study exists to find. Pass
  #    it via `bounds` only if you have decided to. See configs/config.yaml.
  d <- d[!is.na(d$.value) & d$.value > bounds$min & d$.value < bounds$max, , drop = FALSE]

  # 3. drop rows we cannot anchor in time
  d <- d[!is.na(d$.date) & !is.na(d$person_id), , drop = FALSE]

  if (nrow(d) == 0) {
    out <- data.frame(person_id = numeric(0), value = numeric(0), date = as.Date(character(0)))
    names(out) <- out_names
    return(out)
  }

  # 4. keep each person's anchor record. A-001.
  d <- d %>%
    group_by(person_id) %>%
    filter(if (anchor == "earliest") .date == min(.date) else .date == max(.date)) %>%
    ungroup()

  # 5. break remaining ties -> exactly one row per person. A-002.
  #    Step 4 ALONE DOES NOT GUARANTEE one row per person: same-day duplicates survive it. This is
  #    why the notebook always follows it with distinct(), and why that distinct() is the bug.
  d <- switch(tiebreak,
    first = {
      dupes <- sum(duplicated(d$person_id))
      if (dupes > 0) {
        warning(sprintf(
          paste0("clean_measurement(): tiebreak='first' resolved %d same-day duplicate(s) ",
                 "ARBITRARILY. Results are not reproducible between runs (A-002). ",
                 "Use a deterministic tiebreak before publishing."), dupes), call. = FALSE)
      }
      distinct(d, person_id, .keep_all = TRUE)
    },
    mean   = d %>% group_by(person_id) %>%
               summarise(.value = mean(.value), .date = first(.date), .groups = "drop"),
    median = d %>% group_by(person_id) %>%
               summarise(.value = stats::median(.value), .date = first(.date), .groups = "drop"),
    min    = d %>% group_by(person_id) %>%
               summarise(.value = min(.value), .date = first(.date), .groups = "drop"),
    max    = d %>% group_by(person_id) %>%
               summarise(.value = max(.value), .date = first(.date), .groups = "drop")
  )

  # 6. slim + rename
  out <- data.frame(person_id = d$person_id, value = d$.value, date = d$.date)
  names(out) <- out_names

  # The invariant the whole contract rests on (D-005): exactly one row per person.
  if (any(duplicated(out$person_id))) {
    stop("clean_measurement(): postcondition violated — more than one row per person_id.")
  }
  out[order(out$person_id), , drop = FALSE]
}
