-- 01_prevent_concept_discovery.sql — T-017, step 1. D-014.
--
-- RUN THIS FIRST. It answers: "do the codes we are about to rely on actually exist in this CDR, and
-- what do they map to?"
--
-- Why it is a separate step rather than an afterthought: a concept code that does not resolve
-- produces ZERO ROWS AND NO ERROR downstream. The completeness query would then report 0% coverage
-- for that input and you would conclude the data is missing, when in fact your code was wrong. The
-- two are indistinguishable unless you check first. So: check first.
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench).
-- In BigQuery, prefix the tables with the CDR dataset, e.g. `{WORKSPACE_CDR}.concept`.

-- ---------------------------------------------------------------------------------------------
-- A. Do the PREVENT measurement codes (LOINC) resolve? Any row with concept_id NULL is a problem.
-- ---------------------------------------------------------------------------------------------
WITH wanted AS (
  SELECT '2093-3'  AS code, 'total_cholesterol' AS prevent_input UNION ALL
  SELECT '2085-9',  'hdl_c'             UNION ALL
  SELECT '8480-6',  'systolic_bp'       UNION ALL
  SELECT '2160-0',  'serum_creatinine'  UNION ALL
  SELECT '39156-5', 'bmi'               UNION ALL
  SELECT '4548-4',  'hba1c'             UNION ALL
  SELECT '17856-6', 'hba1c'
)
SELECT
  w.prevent_input,
  w.code,
  c.concept_id,
  c.concept_name,
  c.domain_id,
  c.standard_concept,
  CASE WHEN c.concept_id IS NULL
       THEN 'DOES NOT RESOLVE -- fix before trusting any count for this input'
       ELSE 'ok' END AS resolution_status
FROM wanted w
LEFT JOIN concept c
       ON c.concept_code = w.code
      AND c.vocabulary_id = 'LOINC'
ORDER BY w.prevent_input, w.code;


-- ---------------------------------------------------------------------------------------------
-- B. How much data actually sits behind each code? A code can resolve and still have zero rows.
--    Run this separately (it is a second statement).
-- ---------------------------------------------------------------------------------------------
-- SELECT
--   c.concept_code,
--   c.concept_name,
--   COUNT(m.measurement_id)               AS n_rows,
--   COUNT(DISTINCT m.person_id)           AS n_people,
--   COUNT(m.value_as_number)              AS n_with_numeric_value,
--   MIN(m.value_as_number)                AS min_value,
--   MAX(m.value_as_number)                AS max_value
-- FROM concept c
-- LEFT JOIN measurement m ON m.measurement_concept_id = c.concept_id
-- WHERE c.vocabulary_id = 'LOINC'
--   AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5','4548-4','17856-6')
-- GROUP BY c.concept_code, c.concept_name
-- ORDER BY n_people DESC;
--
-- NOTE `COUNT(m.value_as_number)` vs `COUNT(m.measurement_id)`: rows exist where the measurement is
-- recorded but the NUMERIC value is NULL (a censored lab, e.g. value_source_value = '<10'). Those
-- rows look like data and are useless as data. The fixture reproduces this (defect A2, participant
-- 1000022). If the two counts differ, that gap is the number of people you would wrongly believe you
-- have a value for.


-- ---------------------------------------------------------------------------------------------
-- C. THE LINKAGE TRAP. Verified in the fixture, and true of the real CDR.
--
--    ICD10CM  ->  condition_occurrence.condition_source_concept_id
--    CPT4     ->  procedure_occurrence.procedure_source_concept_id
--    the *_concept_id (standard) columns map to SNOMED, NOT to ICD/CPT.
--
--    Querying condition_concept_id for an ICD code returns NOTHING, silently. This query proves
--    which column to use, rather than asking you to trust a comment.
-- ---------------------------------------------------------------------------------------------
-- SELECT 'condition_concept_id (standard)' AS column_used,
--        c.vocabulary_id, COUNT(*) AS n
-- FROM condition_occurrence co
-- JOIN concept c ON c.concept_id = co.condition_concept_id
-- GROUP BY c.vocabulary_id
-- UNION ALL
-- SELECT 'condition_source_concept_id (source)',
--        c.vocabulary_id, COUNT(*)
-- FROM condition_occurrence co
-- JOIN concept c ON c.concept_id = co.condition_source_concept_id
-- GROUP BY c.vocabulary_id
-- ORDER BY column_used, n DESC;
