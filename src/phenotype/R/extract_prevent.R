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

# RxNorm statin ingredient concept_ids (the notebook's set). NOTE: this matches drug_concept_id
# DIRECTLY, which is correct against the fixture (where drug_concept_id is the ingredient). In the
# real CDR a drug row is usually a clinical/branded drug, so this should be widened to descendants
# via concept_ancestor before the statin flag is trusted upstream. Flagged, not silently assumed.
.STATIN_INGREDIENTS <- c(1510813, 1539403, 1545958, 1549686, 1551860, 1592085, 1592180, 40165636)


#' Extract the per-person PREVENT input panel from a CDR connection.
#'
#' @param con an open DBI connection (BigQuery in the Workbench, the DuckDB fixture offline).
#' @return a data.frame, one row per person (age 30-79, has EHR, >=1 PREVENT measurement), with the
#'   PREVENT input columns plus `person_id`, a `complete_panel` flag, and `placeholder_inputs`.
extract_prevent_panel <- function(con) {
  suppressPackageStartupMessages({ library(dplyr); library(tidyr) })

  # --- measurements: one query, then clean each input (bounds + most-recent baseline) -------------
  meas <- DBI::dbGetQuery(con, "
    SELECT m.person_id, c.concept_code AS code, m.value_as_number AS value,
           CAST(m.measurement_date AS DATE) AS dt
    FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
    WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
      AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')")

  # code -> (physiologic low, high, output column). Bounds are deliberately wide; they also catch
  # the common unit confusions (e.g. cholesterol in mmol/L is ~5 and falls below the mg/dL floor).
  specs <- list(
    c("2093-3",  50, 500, "total_c"),
    c("2085-9",  10, 150, "hdl_c"),
    c("8480-6",  60, 250, "sbp"),
    c("2160-0", 0.1,  20, "creatinine"),
    c("39156-5", 10,  80, "bmi"))

  clean_one <- function(spec) {
    cd <- spec[1]; lo <- as.numeric(spec[2]); hi <- as.numeric(spec[3]); nm <- spec[4]
    d <- meas[meas$code == cd & meas$value > lo & meas$value < hi, , drop = FALSE]
    if (!nrow(d)) return(setNames(data.frame(person_id = integer(), x = numeric()),
                                  c("person_id", nm)))
    out <- d %>%
      group_by(person_id) %>%
      filter(dt == max(dt)) %>%              # most-recent = baseline (Q-S6 placeholder)
      summarise(x = mean(value), .groups = "drop")  # average same-day ties (D-009)
    setNames(out, c("person_id", nm))
  }
  m_wide <- Reduce(function(acc, s) full_join(acc, clean_one(s), by = "person_id"),
                   specs, init = data.frame(person_id = integer()))

  # --- diabetes by diagnosis code (ICD10CM on the SOURCE concept column -- the linkage trap) -------
  dm_ids <- DBI::dbGetQuery(con, "
    SELECT DISTINCT co.person_id
    FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id
    WHERE c.vocabulary_id = 'ICD10CM'
      AND (c.concept_code LIKE 'E08%' OR c.concept_code LIKE 'E09%' OR c.concept_code LIKE 'E10%'
        OR c.concept_code LIKE 'E11%' OR c.concept_code LIKE 'E13%')")$person_id

  # --- statin (best-effort ingredient match; see .STATIN_INGREDIENTS note) -------------------------
  statin_ids <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT person_id FROM drug_exposure WHERE drug_concept_id IN (%s)",
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
