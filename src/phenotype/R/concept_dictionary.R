# concept_dictionary.R — resolve OMOP concept_ids to their codes and meanings. T-014, D-014.
#
# WHY THIS EXISTS
#
# The existing notebook hardcodes long lists of concept IDs pasted out of the All of Us Cohort
# Builder, with **no record anywhere of what any of them mean**. That is not a style problem, it is a
# correctness problem with two teeth:
#
#   1. A wrong or stale concept ID returns ZERO ROWS AND NO ERROR. The query succeeds, the phenotype
#      is quietly empty, and the number at the end of the pipeline is wrong but plausible.
#   2. You cannot tell an acute MI from a chronic ischemic-heart-disease code from a
#      revascularisation procedure by staring at `35207691`. The notebook's `codes_df` collapses all
#      three into one binary "CAD_code", which throws away exactly the information the advisor asked
#      us to keep: WHEN the event happened, and WHAT STAGE/TYPE of disease it represents.
#
# So: every concept ID used in an outcome definition gets round-tripped through the vocabulary, and
# anything that does not resolve is a HARD ERROR rather than a silent empty set.
#
# Works against both backends (D-003): the DuckDB fixture offline, and BigQuery in the Workbench.
# The `concept` table has the same shape in both, which is the whole reason the fixture is worth having.

suppressPackageStartupMessages({
  library(dplyr)
})

#' Look up concept IDs in the OMOP vocabulary.
#'
#' @param concept_ids  integer vector of concept IDs to resolve
#' @param con          a DBI connection (DuckDB offline, BigQuery in the Workbench)
#' @param strict       if TRUE (default), any ID that does not resolve is an ERROR. This is the point:
#'                     an unresolvable concept ID is how a phenotype silently becomes empty.
#' @return data.frame(concept_id, concept_code, vocabulary_id, domain_id, concept_name,
#'                    standard_concept)
resolve_concepts <- function(concept_ids, con, strict = TRUE) {
  concept_ids <- unique(as.numeric(concept_ids[!is.na(concept_ids)]))
  if (length(concept_ids) == 0) {
    return(data.frame(concept_id = numeric(0), concept_code = character(0),
                      vocabulary_id = character(0), domain_id = character(0),
                      concept_name = character(0), standard_concept = character(0)))
  }

  sql <- sprintf(
    "SELECT concept_id, concept_code, vocabulary_id, domain_id, concept_name, standard_concept
       FROM concept
      WHERE concept_id IN (%s)",
    paste(format(concept_ids, scientific = FALSE), collapse = ", "))

  out <- DBI::dbGetQuery(con, sql)

  missing <- setdiff(concept_ids, out$concept_id)
  if (length(missing) > 0) {
    msg <- sprintf(
      paste0("resolve_concepts(): %d concept ID(s) did not resolve in the vocabulary: %s\n",
             "  An unresolvable concept ID is not a warning -- it is how a phenotype silently\n",
             "  becomes empty. Check the ID against the CDR version you are querying."),
      length(missing), paste(head(missing, 10), collapse = ", "))
    if (strict) stop(msg, call. = FALSE) else warning(msg, call. = FALSE)
  }

  out[order(out$concept_id), , drop = FALSE]
}

#' Classify a resolved ASCVD concept into what it actually *is*.
#'
#' D-014: the advisor wants event timing AND disease type/stage. Those are different questions and a
#' single binary flag answers neither.
#'
#' The distinction that matters most scientifically:
#'
#'   - `acute_event`     — an MI or acute ischemic event. This is the outcome PREVENT predicts.
#'   - `chronic_disease` — stable/chronic ischemic heart disease, atherosclerosis. A person carrying
#'                         only these codes has ASCVD, but a *first-ever code* here is a diagnosis
#'                         date, NOT necessarily an event date. Treating it as an event date is a real
#'                         way to get the timing wrong.
#'   - `revascularisation` — PCI/CABG (CPT). **This is a TREATMENT DECISION, not purely a disease
#'                         event**, and it is confounded by healthcare access: two people with the same
#'                         disease, different insurance, get different codes. Including it inflates the
#'                         event count; excluding it loses real events. This is precisely why the
#'                         outcome must be reportable BOTH WAYS (Q-A1), and why we keep the label
#'                         rather than collapsing it.
#'
#' The classification is deliberately driven by an explicit, reviewable code map rather than by
#' guessing from concept names — All of Us concept names are not a stable interface.
classify_ascvd_concept <- function(dict, code_map) {
  stopifnot(is.data.frame(dict), all(c("concept_id", "concept_code") %in% names(dict)))
  stopifnot(is.data.frame(code_map), all(c("code_prefix", "class") %in% names(code_map)))

  dict$ascvd_class <- NA_character_
  for (i in seq_len(nrow(code_map))) {
    prefix <- code_map$code_prefix[i]
    hit <- !is.na(dict$concept_code) & startsWith(as.character(dict$concept_code), prefix)
    dict$ascvd_class[hit & is.na(dict$ascvd_class)] <- code_map$class[i]
  }
  dict
}

#' Summarise a dictionary for human review.
#'
#' The output of this is meant to be READ — by the advisor, by a reviewer, by you in six months. An
#' outcome definition you cannot read is an outcome definition you cannot check.
describe_dictionary <- function(dict) {
  dict %>%
    group_by(vocabulary_id, domain_id, ascvd_class = dplyr::coalesce(.data$ascvd_class, "UNCLASSIFIED")) %>%
    summarise(n_concepts = dplyr::n(),
              example_codes = paste(utils::head(sort(.data$concept_code), 5), collapse = ", "),
              .groups = "drop") %>%
    arrange(desc(.data$n_concepts))
}
