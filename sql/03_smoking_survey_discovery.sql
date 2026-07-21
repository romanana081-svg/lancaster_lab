-- 03_smoking_survey_discovery.sql — resolve the current-smoking survey mapping. T-003.
--
-- prevent_concepts.yaml marks current_smoking NEEDS_MAPPING, and says explicitly: do NOT improvise the
-- mapping from memory. This query is how you AVOID improvising it. Smoking in All of Us is SURVEY-
-- derived (Lifestyle / The Basics), not EHR-derived, so `current smoking` — a PREVENT input — has to be
-- read off survey answers whose exact question_concept_id and answer text you must SEE, not guess.
--
-- RUN THIS IN THE WORKBENCH before trusting extract_smoking.R's provisional map. It lists every
-- smoking-related survey question, each answer option, and how many people gave it, so the current-vs-
-- former-vs-never distinction can be DEFINED FROM EVIDENCE. Copy the resulting question_concept_id(s)
-- and the "current smoker" answer_concept_id(s) back into extract_smoking.R / prevent_concepts.yaml.
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench). In BigQuery prefix ds_survey with the CDR
-- dataset if a bare name does not resolve, e.g. `{WORKSPACE_CDR}.ds_survey`.

SELECT
  s.question_concept_id,
  s.question,
  s.answer_concept_id,
  s.answer,
  COUNT(DISTINCT s.person_id) AS n_people
FROM ds_survey s
WHERE LOWER(s.question) LIKE '%smok%'
GROUP BY s.question_concept_id, s.question, s.answer_concept_id, s.answer
ORDER BY s.question_concept_id, n_people DESC;


-- ---------------------------------------------------------------------------------------------
-- Follow-up (run separately): the same for observation, in case the smoking module lands there
-- instead of ds_survey in this CDR version. All of Us has moved survey data between these before.
-- ---------------------------------------------------------------------------------------------
-- SELECT
--   o.observation_concept_id  AS question_concept_id,
--   qc.concept_name           AS question,
--   o.value_as_concept_id     AS answer_concept_id,
--   ac.concept_name           AS answer,
--   COUNT(DISTINCT o.person_id) AS n_people
-- FROM observation o
-- LEFT JOIN concept qc ON qc.concept_id = o.observation_concept_id
-- LEFT JOIN concept ac ON ac.concept_id = o.value_as_concept_id
-- WHERE LOWER(qc.concept_name) LIKE '%smok%'
-- GROUP BY o.observation_concept_id, qc.concept_name, o.value_as_concept_id, ac.concept_name
-- ORDER BY question_concept_id, n_people DESC;
