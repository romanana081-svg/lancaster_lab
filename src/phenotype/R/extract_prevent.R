# extract_prevent.R — pull + clean the PREVENT input panel, one row per person. T-003.
#
# Produces exactly the columns the PREVENT equation needs (AHA PREVENT / CRAN preventr use the same
# input set):
#   person_id, age, sex, sbp, bp_tx, total_c, hdl_c, statin, dm, smoking, egfr, bmi
#
# WHAT IS CLEAN vs PLACEHOLDER (plan A, 2026-07-20):
#   clean now : age, sex, sbp, total_c, hdl_c, bmi, egfr (from creatinine, CKD-EPI 2021 race-free),
#               dm (ICD10CM E08-E13 on the SOURCE concept column), statin (RxNorm ingredient set)
#   PLACEHOLDER: bp_tx (antihypertensive) and smoking are FALSE for everyone. Both are deliberately
#               undefined in configs/prevent_concepts.yaml (NEEDS_A_CODE_LIST / NEEDS_MAPPING) -- do
#               NOT read a risk score as final until these two are mapped. `placeholder_inputs`
#               marks every row so the approximation can never pass silently.
#
# BASELINE = most-recent value per person (ties within a day averaged, cf. D-009). This is a
# PLACEHOLDER for Q-S6 (the real baseline anchor is the advisor's call); it is applied symmetrically
# to everyone, and no earliest-value anchor is baked in (the A-001 trap the notebook falls into).

`%||%` <- function(a, b) if (is.null(a)) b else a

# Load the eGFR helper regardless of working directory (repo root, or tests/testthat).
if (!exists("egfr_ckd_epi_2021", mode = "function")) {
  .here <- tryCatch(dirname(sys.frame(1)$ofile %||% ""), error = function(e) "")
  for (.p in c("src/phenotype/R/egfr.R",
               file.path("..", "..", "src", "phenotype", "R", "egfr.R"),
               file.path(.here, "egfr.R"))) {
    if (!is.na(.p) && nzchar(.p) && file.exists(.p)) { source(.p); break }
  }
}

# RxNorm statin ingredient concept_ids (atorvastatin, simvastatin, rosuvastatin, pravastatin,
# fluvastatin, lovastatin, cerivastatin, pitavastatin -- confirmed by audit_codes() §8a in v8).
# We match a drug to these INGREDIENTS via concept_ancestor, because a CDR drug row is a clinical
# drug ("atorvastatin 40 mg tablet"), not the ingredient. The audit proved the difference is huge:
# a direct drug_concept_id match found 27,320 statin users, the ancestor expansion found 143,905.
.STATIN_INGREDIENTS <- c(1510813, 1539403, 1545958, 1549686, 1551860, 1592085, 1592180, 40165636)


#' Extract the per-person PREVENT input panel from a CDR connection.
#'
#' @param con an open DBI connection (BigQuery in the Workbench, the DuckDB fixture offline).
#' @return a data.frame, one row per person (age 30-79, has EHR, >=1 PREVENT measurement), with the
#'   PREVENT input columns plus `person_id`, a `complete_panel` flag, and `placeholder_inputs`.
extract_prevent_panel <- function(con) {
  suppressPackageStartupMessages({ library(dplyr); library(tidyr) })

  # --- measurements: bound + reduce to ONE most-recent value per person, IN SQL (CDR-scale) -------
  # The bounding, the most-recent-date pick, and the same-day average all happen in SQL, so only ~one
  # row per person per input comes back -- never the ~62M raw rows. Physiologic bounds (exclusive, to
  # match the earlier in-R cleaning) also absorb the wild unit inconsistency: an in-range value is
  # kept whatever its unit label, an out-of-scale one (cholesterol in mmol/L ~5; creatinine garbage
  # >20) is dropped. Baseline = most recent (Q-S6 placeholder); same-day ties averaged (D-009).
  m_long <- DBI::dbGetQuery(con, "
    WITH bounded AS (
      SELECT m.person_id, c.concept_code AS code, m.value_as_number AS value,
             CAST(m.measurement_date AS DATE) AS dt
      FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
      WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
        AND ( (c.concept_code = '2093-3'  AND m.value_as_number > 50  AND m.value_as_number < 500)
           OR (c.concept_code = '2085-9'  AND m.value_as_number > 10  AND m.value_as_number < 150)
           OR (c.concept_code = '8480-6'  AND m.value_as_number > 60  AND m.value_as_number < 250)
           OR (c.concept_code = '2160-0'  AND m.value_as_number > 0.1 AND m.value_as_number < 20)
           OR (c.concept_code = '39156-5' AND m.value_as_number > 10  AND m.value_as_number < 80) )
    ),
    latest AS (
      SELECT person_id, code, value, dt,
             MAX(dt) OVER (PARTITION BY person_id, code) AS max_dt
      FROM bounded
    )
    SELECT person_id, code, AVG(value) AS value
    FROM latest WHERE dt = max_dt
    GROUP BY person_id, code")

  code_map <- c("2093-3" = "total_c", "2085-9" = "hdl_c", "8480-6" = "sbp",
                "2160-0" = "creatinine", "39156-5" = "bmi")
  m_long$col <- unname(code_map[m_long$code])
  m_wide <- tidyr::pivot_wider(m_long[, c("person_id", "col", "value")],
                               names_from = "col", values_from = "value")
  for (nm in c("total_c", "hdl_c", "sbp", "creatinine", "bmi"))   # ensure all columns exist
    if (!nm %in% names(m_wide)) m_wide[[nm]] <- NA_real_

  # --- diabetes by diagnosis code (ICD10CM on the SOURCE concept column -- the linkage trap) -------
  dm_ids <- DBI::dbGetQuery(con, "
    SELECT DISTINCT co.person_id
    FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
    WHERE c.vocabulary_id = 'ICD10CM'
      AND (c.concept_code LIKE 'E08%' OR c.concept_code LIKE 'E09%' OR c.concept_code LIKE 'E10%'
        OR c.concept_code LIKE 'E11%' OR c.concept_code LIKE 'E13%')")$person_id

  # --- statin: match drugs to statin INGREDIENTS via concept_ancestor (see the note above) --------
  statin_ids <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT de.person_id
     FROM drug_exposure de
     JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
     WHERE ca.ancestor_concept_id IN (%s)",
    paste(.STATIN_INGREDIENTS, collapse = ",")))$person_id

  # --- demographics: age (CDR-computed) + sex, gated to EHR + 30-79 --------------------------------
  demo <- DBI::dbGetQuery(con, "
    SELECT person_id, age_at_cdr AS age, sex_at_birth
    FROM cb_search_person
    WHERE has_ehr_data = 1 AND age_at_cdr BETWEEN 30 AND 79")
  demo$sex <- ifelse(tolower(demo$sex_at_birth) == "female", "female",
              ifelse(tolower(demo$sex_at_birth) == "male",   "male", NA_character_))

  # --- assemble: only people with >=1 PREVENT measurement, in the 30-79 EHR cohort -----------------
  panel <- m_wide %>%
    inner_join(demo[, c("person_id", "age", "sex")], by = "person_id") %>%
    mutate(
      egfr    = egfr_ckd_epi_2021(creatinine, age, sex),
      dm      = person_id %in% dm_ids,
      statin  = person_id %in% statin_ids,
      bp_tx   = FALSE,   # PLACEHOLDER (plan A) -- antihypertensive list undefined
      smoking = FALSE    # PLACEHOLDER (plan A) -- smoking survey mapping undefined
    )

  need <- c("age", "sex", "sbp", "total_c", "hdl_c", "egfr", "bmi")
  panel$complete_panel <- stats::complete.cases(panel[, need])
  panel$placeholder_inputs <- "bp_tx,smoking (plan A); baseline=most_recent (Q-S6)"

  panel[, c("person_id", "age", "sex", "sbp", "bp_tx", "total_c", "hdl_c",
            "statin", "dm", "smoking", "egfr", "bmi",
            "complete_panel", "placeholder_inputs")]
}
