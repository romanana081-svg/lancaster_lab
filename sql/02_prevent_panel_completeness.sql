-- 02_prevent_panel_completeness.sql — T-017. D-013, A-015, A-016.
--
-- THE QUESTION THIS ANSWERS, AND WHY IT COMES BEFORE EVERYTHING ELSE:
--
-- D-013 excludes anyone missing ANY PREVENT input. So the completeness rate IS the sample size. If
-- only a small fraction of srWGS participants aged 30-79 have the full panel, the study may be
-- underpowered before genetics is even added -- and the response is a DESIGN CHANGE (relaxed panel,
-- imputation, broader outcome), not a shrug. It is far cheaper to learn that from one query now than
-- from a null result in month three.
--
-- It also produces the DEMOGRAPHIC BREAKDOWN needed for the caveat we have agreed to report: the
-- complete-panel requirement selects for sustained healthcare contact, so the included differ
-- systematically from the excluded (A-015). Section D quantifies that difference instead of
-- asserting it.
--
-- Run 01_prevent_concept_discovery.sql FIRST. If a code does not resolve there, its coverage here
-- reads as 0% and you cannot tell "no data" from "wrong code".
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench).
--   BigQuery : prefix tables with the CDR dataset, e.g. `{WORKSPACE_CDR}.measurement`.
--   Age      : computed from `dob` by year arithmetic rather than a date-diff function, because
--              DuckDB and BigQuery spell DATE_DIFF differently. It is approximate to +/- 1 year,
--              which is fine for a feasibility count and NOT fine for the analysis itself.
--
-- EXPECTED OFFLINE RESULT: systolic_bp, serum_creatinine, hba1c, diabetes, smoking and
-- antihypertensive coverage will all be ~0 on the fixture, because THE FIXTURE DOES NOT CONTAIN
-- THOSE DOMAINS YET (T-004). That is a fixture gap, not a data finding. Do not read the offline
-- numbers as if they were the CDR's.

WITH
-- ---------------------------------------------------------------------------------------------
-- The eligible cohort: srWGS, aged 30-79 (D-013; upper bound = PREVENT's validated range, Q-S7).
-- ---------------------------------------------------------------------------------------------
cohort AS (
  SELECT
    person_id,
    sex_at_birth,
    race,
    (EXTRACT(YEAR FROM DATE '2022-07-01') - EXTRACT(YEAR FROM dob)) AS age_approx
  FROM cb_search_person
  WHERE has_whole_genome_variant = 1
),
eligible AS (
  SELECT * FROM cohort
  WHERE age_approx BETWEEN 30 AND 79
),

-- ---------------------------------------------------------------------------------------------
-- Who has each PREVENT input at least once, EVER?
--
-- Note "ever", not "at baseline". This is a FEASIBILITY CEILING, not the analysis cohort: it is the
-- most generous possible count, and the real number can only be smaller once a baseline window is
-- imposed. Timing is deliberately deferred (that is the later goal), but the counts below should be
-- read as an upper bound and nothing more.
--
-- `value_as_number IS NOT NULL` matters: a measurement row can exist with a NULL numeric value (a
-- censored lab like '<10'). Such a row looks like data and is useless as data (fixture defect A2).
-- ---------------------------------------------------------------------------------------------
meas AS (
  SELECT m.person_id, c.concept_code
  FROM measurement m
  JOIN concept c ON c.concept_id = m.measurement_concept_id
  WHERE c.vocabulary_id = 'LOINC'
    AND m.value_as_number IS NOT NULL
),
has_tc    AS (SELECT DISTINCT person_id FROM meas WHERE concept_code = '2093-3'),
has_hdl   AS (SELECT DISTINCT person_id FROM meas WHERE concept_code = '2085-9'),
has_sbp   AS (SELECT DISTINCT person_id FROM meas WHERE concept_code = '8480-6'),
has_creat AS (SELECT DISTINCT person_id FROM meas WHERE concept_code = '2160-0'),
has_bmi   AS (SELECT DISTINCT person_id FROM meas WHERE concept_code = '39156-5'),

-- Diabetes by DIAGNOSIS CODE. Note this is only one of three possible definitions (code / HbA1c
-- >= 6.5 / glucose-lowering drug) and they do NOT identify the same people -- see
-- configs/prevent_concepts.yaml. ICD10CM lives on the SOURCE concept column, not the standard one.
has_dm AS (
  SELECT DISTINCT co.person_id
  FROM condition_occurrence co
  JOIN concept c ON c.concept_id = co.condition_source_concept_id
  WHERE c.vocabulary_id = 'ICD10CM'
    AND (c.concept_code LIKE 'E08%' OR c.concept_code LIKE 'E09%'
      OR c.concept_code LIKE 'E10%' OR c.concept_code LIKE 'E11%'
      OR c.concept_code LIKE 'E13%')
),

-- ---------------------------------------------------------------------------------------------
-- Per-person availability flags.
-- ---------------------------------------------------------------------------------------------
flags AS (
  SELECT
    e.person_id,
    e.sex_at_birth,
    e.race,
    e.age_approx,
    CASE WHEN t.person_id  IS NOT NULL THEN 1 ELSE 0 END AS has_total_cholesterol,
    CASE WHEN h.person_id  IS NOT NULL THEN 1 ELSE 0 END AS has_hdl_c,
    CASE WHEN s.person_id  IS NOT NULL THEN 1 ELSE 0 END AS has_systolic_bp,
    CASE WHEN cr.person_id IS NOT NULL THEN 1 ELSE 0 END AS has_serum_creatinine,
    CASE WHEN b.person_id  IS NOT NULL THEN 1 ELSE 0 END AS has_bmi,
    CASE WHEN d.person_id  IS NOT NULL THEN 1 ELSE 0 END AS has_diabetes_dx
  FROM eligible e
  LEFT JOIN has_tc    t  ON t.person_id  = e.person_id
  LEFT JOIN has_hdl   h  ON h.person_id  = e.person_id
  LEFT JOIN has_sbp   s  ON s.person_id  = e.person_id
  LEFT JOIN has_creat cr ON cr.person_id = e.person_id
  LEFT JOIN has_bmi   b  ON b.person_id  = e.person_id
  LEFT JOIN has_dm    d  ON d.person_id  = e.person_id
),

-- The complete-panel flag. NOTE what is NOT in it yet: current smoking and antihypertensive use.
-- Both are real PREVENT inputs. Smoking is SURVEY-derived in All of Us, and antihypertensive use
-- needs an ingredient list pulled from the drug hierarchy rather than improvised from memory
-- (configs/prevent_concepts.yaml). Until those two are added, THE `complete_panel` NUMBER BELOW IS
-- AN OVERESTIMATE -- it is the best case, and the true figure can only be lower.
panel AS (
  SELECT
    f.*,
    CASE WHEN has_total_cholesterol = 1
          AND has_hdl_c             = 1
          AND has_systolic_bp       = 1
          AND has_serum_creatinine  = 1
          AND has_bmi               = 1
         THEN 1 ELSE 0 END AS complete_panel_partial
  FROM flags f
)

-- ---------------------------------------------------------------------------------------------
-- A. Coverage of each input, one row. THE HEADLINE.
-- ---------------------------------------------------------------------------------------------
SELECT
  COUNT(*)                                          AS n_eligible_srwgs_30_79,
  SUM(has_total_cholesterol)                        AS n_total_cholesterol,
  SUM(has_hdl_c)                                    AS n_hdl_c,
  SUM(has_systolic_bp)                              AS n_systolic_bp,
  SUM(has_serum_creatinine)                         AS n_serum_creatinine,
  SUM(has_bmi)                                      AS n_bmi,
  SUM(has_diabetes_dx)                              AS n_diabetes_dx,
  SUM(complete_panel_partial)                       AS n_complete_panel_PARTIAL,
  ROUND(100.0 * SUM(complete_panel_partial) / COUNT(*), 1) AS pct_complete_panel_PARTIAL
FROM panel;


-- ---------------------------------------------------------------------------------------------
-- B. WHICH INPUT IS THE BOTTLENECK? Coverage of the panel is set by its scarcest member, so this is
--    the number that decides whether the design needs to change. Run separately.
-- ---------------------------------------------------------------------------------------------
-- SELECT 'total_cholesterol' AS input, SUM(has_total_cholesterol) AS n_people FROM panel
-- UNION ALL SELECT 'hdl_c',            SUM(has_hdl_c)             FROM panel
-- UNION ALL SELECT 'systolic_bp',      SUM(has_systolic_bp)       FROM panel
-- UNION ALL SELECT 'serum_creatinine', SUM(has_serum_creatinine)  FROM panel
-- UNION ALL SELECT 'bmi',              SUM(has_bmi)               FROM panel
-- ORDER BY n_people ASC;   -- the top row is what limits the study


-- ---------------------------------------------------------------------------------------------
-- C. THE ATTRITION / CAVEAT TABLE (A-015). Included vs excluded, by demographics.
--
--    This is the evidence behind the limitation we have agreed to report. If the included and the
--    excluded look the same, the caveat is cheap. If they do not -- and they will not -- this table
--    is what tells the reader, and us, HOW MUCH the cohort is skewed and in which direction.
--
--    Watch the race/ethnicity rows especially: if panel completeness varies by group, then cohort
--    membership is entangled with ancestry, and that matters directly for the PRS and rare-variant
--    work (A-011). Better to see it now than to discover it inside a genetic association.
-- ---------------------------------------------------------------------------------------------
-- SELECT
--   race,
--   sex_at_birth,
--   COUNT(*)                                                  AS n_eligible,
--   SUM(complete_panel_partial)                               AS n_included,
--   COUNT(*) - SUM(complete_panel_partial)                    AS n_excluded,
--   ROUND(100.0 * SUM(complete_panel_partial) / COUNT(*), 1)  AS pct_included
-- FROM panel
-- GROUP BY race, sex_at_birth
-- ORDER BY n_eligible DESC;
--
-- All of Us policy requires SMALL-CELL SUPPRESSION on any exported aggregate. Suppress before this
-- leaves the Workbench (H-006).


-- ---------------------------------------------------------------------------------------------
-- D. Age distribution of the eligible cohort, as a sanity check on the 30-79 filter (Q-S7).
-- ---------------------------------------------------------------------------------------------
-- SELECT MIN(age_approx) AS min_age, MAX(age_approx) AS max_age,
--        COUNT(*) AS n, SUM(complete_panel_partial) AS n_complete
-- FROM panel;
