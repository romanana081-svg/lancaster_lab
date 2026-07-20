# audit_codes.R — provenance audit for every code the pipeline relies on. T-014 / T-017.
#
# PURPOSE: prove the extractor is pulling what it CLAIMS to. For each domain (measurements,
# diagnoses, procedures, medications) it resolves the codes we match on to their concept_id +
# concept_name and counts the rows/people behind them, plus value/unit sanity for labs. You read the
# output and confirm by eye that "2093-3" really is total cholesterol with mg/dL values, that the
# ICD codes we call diabetes/ASCVD really are, that the CPT codes really are revascularisation, and
# that the statin match actually finds statin users.
#
# Matching is BY CODE (vocabulary + code/prefix), never by bare concept_id -- concept IDs drift
# between CDR versions (we already saw the genomic flags do), codes do not. Where the extractor DOES
# rely on concept_ids (the statin list), this audit checks whether that assumption still holds.
#
# HOW TO RUN (RStudio, All of Us):
#   setwd("~/lancaster_lab")
#   source("src/phenotype/R/run_sql.R"); source("src/phenotype/R/audit_codes.R")
#   con <- connect_cdr(); audit_codes(con); DBI::dbDisconnect(con)
# Offline it runs against the DuckDB fixture (concept_ancestor is empty there, so the statin
# "via ancestor" count is 0 offline -- that is a fixture limitation, not a finding).
#
# H-006: the resolved code/name tables are metadata and safe to share. The COUNTS need small-cell
# suppression before any formal export; for pasting back here to debug they are fine.

.STATIN_INGREDIENTS <- c(1510813, 1539403, 1545958, 1549686, 1551860, 1592085, 1592180, 40165636)

.like_any <- function(col, prefixes) {
  paste(sprintf("%s LIKE '%s%%'", col, prefixes), collapse = " OR ")
}

.section <- function(con, label, sql, limit_note = NULL) {
  cat("\n========================================================================\n")
  cat("== ", label, "\n", sep = "")
  if (!is.null(limit_note)) cat("   (", limit_note, ")\n", sep = "")
  cat("------------------------------------------------------------------------\n")
  r <- tryCatch(DBI::dbGetQuery(con, sql),
                error = function(e) { cat("  QUERY ERROR: ", conditionMessage(e), "\n"); NULL })
  if (!is.null(r)) {
    if (nrow(r) == 0) cat("  (no rows -- nothing matched)\n") else print(r, row.names = FALSE)
  }
  invisible(r)
}


#' Run the full code-provenance audit and print it, section by section.
#' @param con an open DBI connection (BigQuery in the Workbench, the DuckDB fixture offline).
audit_codes <- function(con) {

  # --- 1. PREVENT measurements (LOINC): do the codes resolve, and are the VALUES sane? ------------
  .section(con, "1. PREVENT measurements (LOINC) -- value sanity",
    "SELECT c.concept_code, c.concept_name,
            COUNT(*) AS n_rows, COUNT(DISTINCT m.person_id) AS n_people,
            ROUND(AVG(m.value_as_number), 1) AS mean_val,
            ROUND(MIN(m.value_as_number), 1) AS min_val,
            ROUND(MAX(m.value_as_number), 1) AS max_val
     FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
     WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
       AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5','4548-4','17856-6')
     GROUP BY c.concept_code, c.concept_name
     ORDER BY n_people DESC")

  # --- 2. ...and what UNITS are those values recorded in? (mg/dL vs mmol/L is a real trap) ---------
  .section(con, "2. PREVENT measurement units (top of each code)",
    "SELECT c.concept_code, m.unit_source_value AS unit, COUNT(*) AS n_rows
     FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
     WHERE c.vocabulary_id = 'LOINC'
       AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5','4548-4','17856-6')
     GROUP BY c.concept_code, m.unit_source_value
     ORDER BY c.concept_code, n_rows DESC")

  # --- 3. Diabetes diagnoses (ICD10CM on the SOURCE column). Are these really diabetes? -----------
  .section(con, "3. Diabetes diagnosis codes (ICD10CM E08-E13, on condition_source_concept_id)",
    sprintf(
    "SELECT c.concept_code, c.concept_name,
            COUNT(*) AS n_rows, COUNT(DISTINCT co.person_id) AS n_people
     FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
     WHERE c.vocabulary_id = 'ICD10CM' AND (%s)
     GROUP BY c.concept_code, c.concept_name
     ORDER BY n_people DESC LIMIT 60",
    .like_any("c.concept_code", c("E08", "E09", "E10", "E11", "E13"))),
    "up to 60 distinct codes; every one should read as diabetes")

  # --- 4. ASCVD ACUTE events (ICD10CM). The hard endpoint PREVENT predicts. -----------------------
  .section(con, "4. ASCVD acute-event codes (ICD10CM I21-I24, I63)",
    sprintf(
    "SELECT c.concept_code, c.concept_name,
            COUNT(*) AS n_rows, COUNT(DISTINCT co.person_id) AS n_people
     FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
     WHERE c.vocabulary_id = 'ICD10CM' AND (%s)
     GROUP BY c.concept_code, c.concept_name
     ORDER BY n_people DESC LIMIT 60",
    .like_any("c.concept_code", c("I21", "I22", "I23", "I24", "I63"))))

  # --- 5. ASCVD CHRONIC disease (ICD10CM). Prevalent disease, not necessarily an event. -----------
  .section(con, "5. ASCVD chronic-disease codes (ICD10CM I25,I20,I70,I73,Z95.1,Z95.5)",
    sprintf(
    "SELECT c.concept_code, c.concept_name,
            COUNT(*) AS n_rows, COUNT(DISTINCT co.person_id) AS n_people
     FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
     WHERE c.vocabulary_id = 'ICD10CM' AND (%s)
     GROUP BY c.concept_code, c.concept_name
     ORDER BY n_people DESC LIMIT 60",
    .like_any("c.concept_code", c("I25", "I20", "I70", "I73", "Z95.1", "Z95.5"))))

  # --- 6. REVASCULARISATION procedures (CPT4 on the SOURCE column). ------------------------------
  .section(con, "6. Revascularisation procedure codes (CPT4 929xx, 33510, 33533, on procedure_source_concept_id)",
    sprintf(
    "SELECT c.concept_code, c.concept_name,
            COUNT(*) AS n_rows, COUNT(DISTINCT p.person_id) AS n_people
     FROM procedure_occurrence p JOIN concept c ON c.concept_id = p.procedure_source_concept_id
     WHERE c.vocabulary_id = 'CPT4' AND (%s)
     GROUP BY c.concept_code, c.concept_name
     ORDER BY n_people DESC LIMIT 60",
    .like_any("c.concept_code", c("929", "33510", "33533"))))

  # --- 7. THE LINKAGE CHECK for both conditions AND procedures. -----------------------------------
  # ICD10CM must live on condition_source_concept_id and CPT4 on procedure_source_concept_id; the
  # standard columns are SNOMED. If these come back wrong, sections 3-6 were querying the wrong column.
  .section(con, "7a. Condition vocab by column (ICD10CM must be on SOURCE, not standard)",
    "SELECT 'condition_concept_id (standard)' AS col, c.vocabulary_id AS vocab, COUNT(*) AS n
     FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_concept_id
     GROUP BY c.vocabulary_id
     UNION ALL
     SELECT 'condition_source_concept_id (source)', c.vocabulary_id, COUNT(*)
     FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
     GROUP BY c.vocabulary_id
     ORDER BY col, n DESC")
  .section(con, "7b. Procedure vocab by column (CPT4 must be on SOURCE)",
    "SELECT 'procedure_concept_id (standard)' AS col, c.vocabulary_id AS vocab, COUNT(*) AS n
     FROM procedure_occurrence p JOIN concept c ON c.concept_id = p.procedure_concept_id
     GROUP BY c.vocabulary_id
     UNION ALL
     SELECT 'procedure_source_concept_id (source)', c.vocabulary_id, COUNT(*)
     FROM procedure_occurrence p JOIN concept c ON c.concept_id = p.procedure_source_concept_id
     GROUP BY c.vocabulary_id
     ORDER BY col, n DESC")

  # --- 8. STATINS: does the extractor's concept_id list still resolve, and does it find users? ----
  # The extractor matches drug_concept_id DIRECTLY to these ingredient IDs. This is the ID-fragility
  # risk. 8a shows what the IDs resolve to (empty rows = they no longer exist in this CDR). 8b/8c
  # compare users found by the direct match vs the CORRECT concept_ancestor expansion. If 8c >> 8b,
  # the extractor is under-counting statins in the real CDR and must switch to the ancestor join.
  ids <- paste(.STATIN_INGREDIENTS, collapse = ",")
  .section(con, "8a. What do the extractor's statin ingredient IDs resolve to?",
    sprintf("SELECT concept_id, concept_code, vocabulary_id, concept_name
             FROM concept WHERE concept_id IN (%s)", ids))
  .section(con, "8b. Statin users via DIRECT drug_concept_id match (what the extractor does now)",
    sprintf("SELECT COUNT(DISTINCT person_id) AS n_people_direct
             FROM drug_exposure WHERE drug_concept_id IN (%s)", ids))
  .section(con, "8c. Statin users via concept_ancestor expansion (the CORRECT way)",
    sprintf("SELECT COUNT(DISTINCT de.person_id) AS n_people_via_ancestor
             FROM drug_exposure de
             JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
             WHERE ca.ancestor_concept_id IN (%s)", ids))

  cat("\n========================================================================\n")
  cat("Audit done. Paste the sections back. H-006: code/name tables are safe to\n")
  cat("share; the COUNTS need small-cell suppression before any formal export.\n")
  invisible(NULL)
}
