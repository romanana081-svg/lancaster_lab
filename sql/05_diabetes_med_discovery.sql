-- 05_diabetes_med_discovery.sql — resolve the glucose-lowering ingredient set for the diabetes
-- definition. T-003 (advisor diabetes definition, 2026-07-21).
--
-- The advisor definition is: diabetes := most-recent HbA1c >= 6.8% AND >= 1 glucose-lowering
-- medication. The HbA1c limb is a measurement (already handled in extract_prevent.R); THIS query is
-- for the MEDICATION limb. prevent_concepts.yaml marks drugs.diabetes_medication PROVISIONAL and says:
-- do NOT trust the hardcoded ingredient set (.DM_MED_INGREDIENTS in extract_prevent.R, anchored on
-- metformin 1503297) until it is confirmed against THIS CDR's drug hierarchy. This query is how you
-- confirm it, the same way the statins were audited.
--
-- RUN THIS IN THE WORKBENCH. It has two parts:
--   (A) starts from the RxNorm ingredient NAMES of every glucose-lowering class and shows which
--       ingredient concept_ids actually exist in this CDR, with how many people are exposed. Copy the
--       resolved ingredient concept_ids back into extract_prevent.R's .DM_MED_INGREDIENTS.
--   (B) sanity-counts how many people the definition would flag, and how the two limbs (HbA1c>=6.8 and
--       >=1 med) overlap -- because metformin is also used for PCOS/prediabetes, the med limb alone
--       OVER-calls, which is exactly why the definition requires BOTH.
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench). In BigQuery, prefix tables with the CDR
-- dataset if a bare name does not resolve, e.g. `{WORKSPACE_CDR}.concept`. The `concept_ancestor`
-- rollup (ingredient -> clinical drugs) is what lets a person on "metformin 500 mg tablet" be matched
-- to the metformin INGREDIENT -- a direct drug_concept_id match misses almost everyone (cf. statins).

-- (A) Which glucose-lowering INGREDIENTS resolve in this CDR, and how many people are exposed.
--     Match RxNorm ingredients by name across the standard classes. Confirm the concept_ids this
--     returns before hardcoding them; a name that returns 0 rows is a code that does not resolve here.
SELECT
  c.concept_id      AS ingredient_concept_id,
  c.concept_name    AS ingredient,
  c.concept_code    AS rxnorm_code,
  COUNT(DISTINCT de.person_id) AS n_people_exposed
FROM concept c
LEFT JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id
LEFT JOIN drug_exposure   de ON de.drug_concept_id      = ca.descendant_concept_id
WHERE c.vocabulary_id = 'RxNorm'
  AND c.concept_class_id = 'Ingredient'
  AND LOWER(c.concept_name) IN (
    -- biguanide
    'metformin',
    -- sulfonylureas
    'glimepiride', 'glipizide', 'glyburide', 'gliclazide', 'chlorpropamide', 'tolbutamide',
    -- meglitinides
    'repaglinide', 'nateglinide',
    -- thiazolidinediones
    'pioglitazone', 'rosiglitazone',
    -- DPP-4 inhibitors
    'sitagliptin', 'saxagliptin', 'linagliptin', 'alogliptin',
    -- SGLT2 inhibitors
    'canagliflozin', 'dapagliflozin', 'empagliflozin', 'ertugliflozin',
    -- GLP-1 receptor agonists
    'exenatide', 'liraglutide', 'dulaglutide', 'semaglutide', 'lixisenatide',
    -- alpha-glucosidase inhibitors
    'acarbose', 'miglitol',
    -- insulins (ingredient names vary; the LIKE below catches the rest)
    'insulin', 'insulin glargine', 'insulin lispro', 'insulin aspart', 'insulin detemir',
    'insulin degludec', 'insulin human', 'insulin isophane'
  )
GROUP BY c.concept_id, c.concept_name, c.concept_code
ORDER BY n_people_exposed DESC;


-- ---------------------------------------------------------------------------------------------
-- (B) Follow-up (run separately, after you have the confirmed ingredient set from (A)):
--     how many people does the definition flag, and how do the two limbs overlap? Paste the
--     confirmed ingredient concept_ids into the IN (...) list below. The overlap is the point:
--     "med only" is the over-call the HbA1c limb removes; "A1c only" is untreated/diet-controlled.
-- ---------------------------------------------------------------------------------------------
-- WITH a1c AS (   -- most-recent HbA1c per person (LOINC 4548-4 / 17856-6), bounded
--   SELECT m.person_id, m.value_as_number AS a1c,
--          ROW_NUMBER() OVER (PARTITION BY m.person_id ORDER BY m.measurement_date DESC) AS rn
--   FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
--   WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN ('4548-4','17856-6')
--     AND m.value_as_number > 3 AND m.value_as_number < 20
-- ),
-- a1c_hi AS (SELECT person_id FROM a1c WHERE rn = 1 AND a1c >= 6.8),
-- on_med AS (
--   SELECT DISTINCT de.person_id
--   FROM drug_exposure de
--   JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
--   WHERE ca.ancestor_concept_id IN ( /* paste confirmed ingredient concept_ids from (A) */ )
-- )
-- SELECT
--   (SELECT COUNT(*) FROM a1c_hi)                                             AS n_a1c_ge_6_8,
--   (SELECT COUNT(*) FROM on_med)                                            AS n_on_med,
--   (SELECT COUNT(*) FROM a1c_hi WHERE person_id IN (SELECT person_id FROM on_med)) AS n_both_DEFINITION,
--   (SELECT COUNT(*) FROM a1c_hi WHERE person_id NOT IN (SELECT person_id FROM on_med)) AS n_a1c_only,
--   (SELECT COUNT(*) FROM on_med WHERE person_id NOT IN (SELECT person_id FROM a1c_hi)) AS n_med_only;
