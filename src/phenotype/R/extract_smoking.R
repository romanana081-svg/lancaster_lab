# extract_smoking.R — derive current_smoking (a PREVENT input) from the survey. T-003.
#
# STATUS: PROVISIONAL MAPPING. prevent_concepts.yaml marks current_smoking NEEDS_MAPPING and forbids
# improvising the answer set from memory. The authoritative mapping must come from
# sql/03_smoking_survey_discovery.sql run against the real CDR. Until then this uses a transparent,
# reviewable default classifier and stamps every row `smoking_mapping = "PROVISIONAL"`, so a risk score
# built on it can never be mistaken for final. This mirrors the bp_tx/smoking placeholders in
# extract_prevent.R — here smoking becomes *derivable* rather than hard-FALSE, but still provisional.
#
# BASELINE: most-recent survey answer per person (the same Q-S6 placeholder anchor the measurement
# extractor uses; see extract_prevent.R). Applied symmetrically to everyone. No earliest-value anchor.

#' Default provisional classifier: does a raw survey answer indicate CURRENT smoking?
#'
#' PREVENT's input is *current* smoking (former and never both map to FALSE). The default rule is
#' deliberately simple and legible so a reviewer can see exactly what it does: an answer counts as
#' current smoking if it mentions "current" (or an every-day / some-days frequency) and does NOT say
#' former / never / not-at-all. It classifies the fixture answers correctly ("Current Every Day" ->
#' TRUE, "Never" -> FALSE) and is a plausible first cut at the real answers — but it is NOT the
#' authority; sql/03 is. Replace this with the confirmed answer_concept_id set once discovered.
#'
#' @param answer character vector of raw survey answer strings.
#' @return logical vector; NA where the answer is missing/uninformative (skip, prefer-not-to-answer).
is_current_smoker_default <- function(answer) {
  a <- tolower(trimws(answer %||% NA_character_))
  negative <- grepl("former|never|not at all|no smok|non[- ]?smok", a)
  positive <- grepl("current|every day|some day|daily", a)
  out <- ifelse(is.na(a) | a %in% c("", "pmi: skip", "pmi: prefer not to answer",
                                    "prefer not to answer", "skip", "dont know", "don't know"),
                NA, positive & !negative)
  as.logical(out)
}

`%||%` <- if (exists("%||%", mode = "function")) `%||%` else function(a, b) if (is.null(a)) b else a

#' Extract current_smoking per person from the survey table.
#'
#' @param con an open DBI connection (BigQuery in the Workbench, the DuckDB fixture offline).
#' @param question_concept_ids optional integer vector to restrict to specific smoking questions
#'   (the ones sql/03 confirms). NULL (default) = any survey question whose text matches smoking.
#' @param classifier function(answer) -> logical, the raw-answer -> current-smoker rule. Defaults to
#'   is_current_smoker_default(); pass your own once the discovery step nails the answer set.
#' @return data.frame(person_id, smoking, smoking_answer, smoking_date, smoking_mapping), one row per
#'   person, from that person's MOST-RECENT informative smoking answer.
extract_smoking <- function(con, question_concept_ids = NULL, classifier = is_current_smoker_default) {
  suppressPackageStartupMessages(library(dplyr))

  where_q <- if (is.null(question_concept_ids)) {
    "LOWER(s.question) LIKE '%smok%'"
  } else {
    sprintf("s.question_concept_id IN (%s)", paste(as.integer(question_concept_ids), collapse = ","))
  }
  raw <- DBI::dbGetQuery(con, sprintf("
    SELECT s.person_id, s.answer AS smoking_answer,
           CAST(s.survey_datetime AS DATE) AS smoking_date
    FROM ds_survey s
    WHERE %s AND s.answer IS NOT NULL", where_q))

  if (!nrow(raw)) {
    return(data.frame(person_id = integer(), smoking = logical(),
                      smoking_answer = character(), smoking_date = as.Date(character()),
                      smoking_mapping = character(), stringsAsFactors = FALSE))
  }

  raw$is_current <- classifier(raw$smoking_answer)
  # Keep only informative answers (a non-NA classification), then take each person's MOST RECENT one.
  # Ties on the same date: an informative answer wins, then current (TRUE) is kept conservatively.
  inf <- raw[!is.na(raw$is_current), , drop = FALSE]
  if (!nrow(inf)) {
    return(data.frame(person_id = integer(), smoking = logical(),
                      smoking_answer = character(), smoking_date = as.Date(character()),
                      smoking_mapping = character(), stringsAsFactors = FALSE))
  }
  out <- inf %>%
    group_by(person_id) %>%
    filter(smoking_date == max(smoking_date)) %>%
    summarise(smoking        = any(is_current),          # same-day: any current answer -> current
              smoking_answer = smoking_answer[which.max(is_current)],
              smoking_date   = max(smoking_date),
              .groups = "drop") %>%
    as.data.frame()
  out$smoking_mapping <- "PROVISIONAL"   # cleared only when sql/03 confirms the real answer set
  out
}

#' Attach a derived smoking status onto a PREVENT panel, replacing the FALSE placeholder.
#'
#' extract_prevent_panel() sets smoking = FALSE for everyone (a placeholder). This swaps in the real
#' per-person value from extract_smoking(). A person with NO smoking answer becomes NA -- honest
#' "unknown", not "non-smoker" -- so run_prevent() returns NA for them rather than a risk that assumes
#' they don't smoke. Because smoking (survey-derived) may be the single biggest driver of exclusion
#' (prevent_concepts.yaml), the cost of requiring it is surfaced explicitly, not hidden:
#'   * has_smoking_answer      -- does this person have a usable smoking answer at all?
#'   * complete_panel          -- unchanged (the 5 measurements + demographics; smoking NOT required)
#'   * complete_panel_smoking  -- complete_panel AND smoking known: the count if smoking is REQUIRED.
#' Both counts are kept so switching smoking from placeholder to required is transparent, not a silent
#' shrink of the cohort. Whether missing smoking should exclude (NA) or default to non-smoker is an
#' advisor question.
#'
#' @param panel output of extract_prevent_panel().
#' @param smk   output of extract_smoking() (person_id, smoking, ...).
#' @return panel with smoking replaced, plus has_smoking_answer and complete_panel_smoking.
attach_smoking <- function(panel, smk) {
  suppressPackageStartupMessages(library(dplyr))
  panel$smoking <- NULL                                   # drop the placeholder column
  panel <- left_join(panel, smk[, c("person_id", "smoking")], by = "person_id")
  panel$has_smoking_answer     <- !is.na(panel$smoking)
  panel$complete_panel_smoking <- panel$complete_panel & panel$has_smoking_answer
  panel$placeholder_inputs     <- "bp_tx (plan A); smoking=survey(provisional); baseline=most_recent (Q-S6)"
  # keep smoking next to the other inputs; new flags at the end
  front <- c("person_id","age","sex","sbp","bp_tx","total_c","hdl_c","statin","dm","smoking","egfr","bmi")
  panel[, c(front, setdiff(names(panel), front))]
}
