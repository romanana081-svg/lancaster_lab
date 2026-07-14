# clean_codes.R — the code-based phenotype idiom (CAD, PAD, FH, hypercholesterolemia). T-005.
#
# Conditions (ICD) and procedures (CPT) are handled the same way throughout the notebook: reduce each
# person to their EARLIEST code, keep one row, and treat "has a row" as the binary phenotype. For CAD
# the notebook additionally rbind()s the ICD and CPT frames and then re-reduces to the earliest of the
# two — which is what `combine_codes()` does here.
#
# A-006 governs all of this and cannot be engineered away: **absence of a code is not absence of
# disease.** A 0 here means "we found no code", not "this person is well". The misclassification is
# non-random — it tracks healthcare contact — which is why Q-A2 (a minimum-EHR-density requirement)
# exists.

suppressPackageStartupMessages(library(dplyr))

#' Reduce a raw OMOP condition/procedure table to one row per person: their earliest code.
#'
#' @param df         raw rows (person_id, a date column, and optionally code/name columns)
#' @param date_col   the event date column (e.g. "condition_start_datetime")
#' @param code_col   source concept code column, or NULL if absent
#' @param name_col   source concept name column, or NULL if absent
#' @param out_prefix names the output columns `<prefix>_code` / `_date` / `_name`
#'
#' @section The tie-break here is a DIFFERENT animal to the one in clean_measurement():
#' A-002 bites here too, but far more mildly. Two codes on a person's earliest date leave the *date*
#' unambiguous and the *binary phenotype* unambiguous — only the surviving **label** (which of the two
#' ICD codes we report) is arbitrary under the notebook's `distinct()`. Nothing downstream currently
#' uses that label, so this is cosmetic rather than a threat to reproducibility.
#'
#' It is still made deterministic — earliest date, then lowest code string — because "arbitrary but
#' harmless" has a way of becoming load-bearing later, and determinism costs one `arrange()`.
clean_codes <- function(df,
                        date_col = "condition_start_datetime",
                        code_col = "source_concept_code",
                        name_col = "source_concept_name",
                        out_prefix = "code") {
  stopifnot(is.data.frame(df))
  if (!"person_id" %in% names(df)) stop("clean_codes(): missing column 'person_id'")
  if (!date_col %in% names(df))    stop(sprintf("clean_codes(): missing column '%s'", date_col))

  d <- df
  d$.date <- as.Date(d[[date_col]])
  d$.code <- if (!is.null(code_col) && code_col %in% names(d)) as.character(d[[code_col]]) else NA_character_
  d$.name <- if (!is.null(name_col) && name_col %in% names(d)) as.character(d[[name_col]]) else NA_character_

  d <- d[!is.na(d$person_id) & !is.na(d$.date), , drop = FALSE]

  out <- data.frame(person_id = numeric(0), code = character(0),
                    date = as.Date(character(0)), name = character(0))
  if (nrow(d) > 0) {
    d <- d %>%
      group_by(person_id) %>%
      filter(.date == min(.date)) %>%
      arrange(.code, .by_group = TRUE) %>%   # deterministic label among same-day codes
      slice(1) %>%
      ungroup()
    out <- data.frame(person_id = d$person_id, code = d$.code, date = d$.date, name = d$.name)
  }

  names(out) <- c("person_id",
                  paste0(out_prefix, "_code"),
                  paste0(out_prefix, "_date"),
                  paste0(out_prefix, "_name"))

  if (any(duplicated(out$person_id))) {
    stop("clean_codes(): postcondition violated — more than one row per person_id.")
  }
  out[order(out$person_id), , drop = FALSE]
}

#' Union several code frames and re-reduce to the earliest event per person.
#'
#' This is the notebook's CAD construction: `rbind(icd_df, CPT_df)` then earliest-per-person again.
#' Reducing each source frame FIRST and then re-reducing the union gives the same answer as reducing
#' the union directly (the minimum of per-group minima is the global minimum), so the order is safe —
#' but it is only safe because every input has already been reduced to one row per person.
#'
#' @param ...        frames from clean_codes(), all sharing the same `out_prefix`
#' @param out_prefix the prefix those frames were built with
combine_codes <- function(..., out_prefix = "code") {
  frames <- list(...)
  frames <- frames[!vapply(frames, is.null, logical(1))]
  if (length(frames) == 0) stop("combine_codes(): nothing to combine")

  cols <- c("person_id", paste0(out_prefix, c("_code", "_date", "_name")))
  for (f in frames) {
    if (!identical(names(f), cols)) {
      stop("combine_codes(): frames must come from clean_codes() with the same out_prefix")
    }
  }

  all <- do.call(rbind, frames)
  names(all) <- c("person_id", ".code", ".date", ".name")

  out <- all %>%
    group_by(person_id) %>%
    filter(.date == min(.date)) %>%
    arrange(.code, .by_group = TRUE) %>%
    slice(1) %>%
    ungroup()

  out <- data.frame(person_id = out$person_id, code = out$.code,
                    date = out$.date, name = out$.name)
  names(out) <- cols

  if (any(duplicated(out$person_id))) {
    stop("combine_codes(): postcondition violated — more than one row per person_id.")
  }
  out[order(out$person_id), , drop = FALSE]
}

#' Turn a code frame into the binary phenotype the join expects: 1 if present, 0 if not.
#'
#' A-006: the 0 means "no code found", NOT "confirmed disease-free". Every binary phenotype in this
#' project carries that caveat, and it is the single assumption most likely to bias the study.
#'
#' @param cohort_ids the FULL cohort. People with no code get 0 — which is why this needs the cohort,
#'                   not just the people who happen to have codes.
as_binary_phenotype <- function(code_df, cohort_ids, out_prefix = "code") {
  date_col <- paste0(out_prefix, "_date")
  out <- data.frame(person_id = unique(cohort_ids))
  out[[paste0(out_prefix, "_present")]] <- as.integer(out$person_id %in% code_df$person_id)
  out[[date_col]] <- code_df[[date_col]][match(out$person_id, code_df$person_id)]
  out[order(out$person_id), , drop = FALSE]
}
