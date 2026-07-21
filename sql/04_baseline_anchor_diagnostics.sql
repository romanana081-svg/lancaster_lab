-- 04_baseline_anchor_diagnostics.sql — evidence for the Q-S6 baseline-anchor decision. T-019, D-015.
--
-- THE QUESTION (Q-S6): what is "baseline" for a person who never has an event? The pipeline currently
-- uses a PLACEHOLDER — most-recent value (extract_prevent.R) — and the anchor decision is deferred
-- (config anchor: none, D-015). The deferral is only safe while the choice does not secretly matter.
-- This query MEASURES whether it matters, so the advisor decides on numbers, not vibes.
--
-- The core fact the advisor needs: FOR HOW MANY PEOPLE DOES THE ANCHOR CHOICE EVEN CHANGE THE VALUE?
-- If almost everyone has exactly one measurement per input, "most recent" == "first" == "landmark" and
-- the deferral costs nothing. If many people have several values spread over years, the anchor is a
-- real scientific choice (most-recent vs first-complete-panel vs a landmark time) and must be made
-- before any model is fitted — because anchoring cases and non-cases differently makes every predictor
-- look stronger than it is, with no bug appearing anywhere (config.yaml, A-001).
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench): only COUNT / COUNT(DISTINCT) / AVG / MIN /
-- MAX and CASE bucketing — no dialect-specific date-diff or percentile functions.

WITH per_person_input AS (
  SELECT m.person_id,
         c.concept_code AS code,
         COUNT(DISTINCT CAST(m.measurement_date AS DATE)) AS n_dates
  FROM measurement m
  JOIN concept c ON c.concept_id = m.measurement_concept_id
  WHERE c.vocabulary_id = 'LOINC'
    AND m.value_as_number IS NOT NULL
    AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
  GROUP BY m.person_id, c.concept_code
)
SELECT
  code,
  COUNT(*)                                              AS n_people,
  SUM(CASE WHEN n_dates =  1        THEN 1 ELSE 0 END)  AS n_exactly_1_date,
  SUM(CASE WHEN n_dates =  2        THEN 1 ELSE 0 END)  AS n_2_dates,
  SUM(CASE WHEN n_dates BETWEEN 3 AND 5 THEN 1 ELSE 0 END) AS n_3_to_5_dates,
  SUM(CASE WHEN n_dates >  5        THEN 1 ELSE 0 END)  AS n_over_5_dates,
  SUM(CASE WHEN n_dates >  1        THEN 1 ELSE 0 END)  AS n_multi_date,   -- anchor choice MATTERS here
  AVG(n_dates)                                          AS mean_dates_per_person,
  MAX(n_dates)                                          AS max_dates_per_person
FROM per_person_input
GROUP BY code
ORDER BY code;


-- ---------------------------------------------------------------------------------------------
-- Follow-up A (run separately): the SPAN a multi-date person's values cover. A person with 4 values
-- all within a month is different from one whose values span 8 years — the latter is where "most
-- recent" vs "first complete panel" genuinely diverge. Date arithmetic differs by dialect, so pick
-- the line for your backend.
-- ---------------------------------------------------------------------------------------------
-- WITH spans AS (
--   SELECT m.person_id, c.concept_code AS code,
--          MIN(CAST(m.measurement_date AS DATE)) AS first_dt,
--          MAX(CAST(m.measurement_date AS DATE)) AS last_dt
--   FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
--   WHERE c.vocabulary_id='LOINC' AND m.value_as_number IS NOT NULL
--     AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
--   GROUP BY m.person_id, c.concept_code
-- )
-- SELECT code,
--   -- BigQuery:  AVG(DATE_DIFF(last_dt, first_dt, DAY))   AS mean_span_days,
--   --            MAX(DATE_DIFF(last_dt, first_dt, DAY))   AS max_span_days
--   -- DuckDB:    AVG(DATE_DIFF('day', first_dt, last_dt)) AS mean_span_days,
--   --            MAX(DATE_DIFF('day', first_dt, last_dt)) AS max_span_days
--   COUNT(*) AS n_people
-- FROM spans GROUP BY code ORDER BY code;

-- ---------------------------------------------------------------------------------------------
-- Follow-up B (run separately): does a "first complete panel" date even exist for most people, and
-- when? A first-complete-panel anchor is only usable if people HAVE a date by which all five inputs
-- are simultaneously on record. This counts, per person, how many of the five inputs they have on
-- their SINGLE most-common measurement date vs ever — a cheap proxy for "are the inputs co-measured
-- (one clinic visit) or scattered (separate encounters)?", which is the crux of the anchor choice.
-- ---------------------------------------------------------------------------------------------
-- WITH by_date AS (
--   SELECT m.person_id, CAST(m.measurement_date AS DATE) AS dt,
--          COUNT(DISTINCT c.concept_code) AS inputs_that_day
--   FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
--   WHERE c.vocabulary_id='LOINC' AND m.value_as_number IS NOT NULL
--     AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
--   GROUP BY m.person_id, CAST(m.measurement_date AS DATE)
-- )
-- SELECT MAX(inputs_that_day) AS max_inputs_on_one_day, COUNT(DISTINCT person_id) AS n_people
-- FROM by_date GROUP BY person_id;   -- distribution: how many get all 5 on one day (a clean anchor)
