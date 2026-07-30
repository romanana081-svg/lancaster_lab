-- 06_antihypertensive_discovery.sql — what do the AHA antihypertensive classes actually resolve to?
--
-- bp_tx is a PREVENT input. It was FALSE for everyone until 2026-07-30, when the AHA's published
-- classes of blood-pressure medication were written into
-- `configs/prevent_concepts.yaml: drugs.antihypertensive` BY INGREDIENT NAME.
--
-- Names rather than concept IDs, because a name is reviewable clinical reference material and is
-- stable across CDR versions; a concept ID is neither, and a stale one returns zero rows with no
-- error. But a name only helps if the CDR agrees with it — hence this file. Run it in the Workbench
-- and paste the output back: it is the evidence that turns
-- `status: PROVISIONAL_AHA_CLASSES` into a confirmed list.
--
-- The output is aggregate-only and safe to bring out, EXCEPT the person counts — apply the <20
-- suppression rule (H-006) before pasting, or use check_prevent_inputs() in R, which suppresses
-- automatically.
--
-- Portable across DuckDB (fixture) and BigQuery (Workbench).

-- ================================================================================================
-- QUERY A — which AHA ingredient names exist as RxNorm INGREDIENT concepts in this CDR?
--
-- A name missing here is a name the CDR spells differently (or does not carry). Those are the ones
-- to fix in the config. Restricting to concept_class_id = 'Ingredient' is load-bearing: without it,
-- clinical drugs ("metoprolol succinate 25 MG tablet") also match, and the concept_ancestor
-- expansion in Query C would then run from the wrong level of the hierarchy.
-- ================================================================================================
SELECT LOWER(c.concept_name) AS ingredient_name,
       c.concept_id,
       c.concept_class_id,
       c.standard_concept
FROM concept c
WHERE c.vocabulary_id = 'RxNorm'
  AND c.concept_class_id = 'Ingredient'
  AND LOWER(c.concept_name) IN (
    -- diuretics (thiazide / loop / potassium-sparing) and aldosterone antagonists
    'hydrochlorothiazide','chlorthalidone','indapamide','metolazone',
    'furosemide','bumetanide','torsemide','amiloride','triamterene',
    'spironolactone','eplerenone',
    -- beta blockers and combined alpha+beta blockers
    'atenolol','metoprolol','propranolol','nadolol','bisoprolol','nebivolol',
    'betaxolol','acebutolol','pindolol','timolol','carvedilol','labetalol',
    -- ACE inhibitors
    'lisinopril','enalapril','ramipril','benazepril','captopril','fosinopril',
    'quinapril','perindopril','moexipril','trandolapril',
    -- ARBs
    'losartan','valsartan','irbesartan','candesartan','olmesartan','telmisartan',
    'eprosartan','azilsartan',
    -- calcium channel blockers
    'amlodipine','nifedipine','felodipine','nicardipine','isradipine','nisoldipine',
    'diltiazem','verapamil',
    -- alpha blockers, central agonists, vasodilators, renin inhibitors
    'doxazosin','prazosin','terazosin','clonidine','methyldopa','guanfacine',
    'hydralazine','minoxidil','aliskiren')
ORDER BY ingredient_name;


-- ================================================================================================
-- QUERY B (run separately) — how many PEOPLE are on each ingredient?
--
-- This is the table that tells you whether the list is doing real work or whether one or two
-- ingredients carry all of it. Suppress counts <20 before bringing it out (H-006).
--
-- Expansion via concept_ancestor is mandatory: a drug_exposure row holds a CLINICAL DRUG, not an
-- ingredient. The statin audit measured the cost of getting this wrong — a direct drug_concept_id
-- match found 27,320 users where the ancestor expansion found 143,905.
-- ================================================================================================
-- SELECT LOWER(anc.concept_name) AS ingredient_name,
--        COUNT(DISTINCT de.person_id) AS n_people,
--        COUNT(*)                     AS n_rows
-- FROM drug_exposure de
-- JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
-- JOIN concept anc         ON anc.concept_id = ca.ancestor_concept_id
-- WHERE anc.vocabulary_id = 'RxNorm'
--   AND anc.concept_class_id = 'Ingredient'
--   AND LOWER(anc.concept_name) IN ( /* same list as Query A */ )
-- GROUP BY ingredient_name
-- ORDER BY n_people DESC;


-- ================================================================================================
-- QUERY C (run separately) — the headline: how many people have ANY antihypertensive?
--
-- This single number is bp_tx's prevalence, and it is the one to sanity-check against expectation.
-- In a US cohort aged 30-79 with EHR data, "on a BP-lowering drug" in the mid-tens of percent is
-- plausible; single digits means the resolution failed somewhere, and >60% means the list is
-- capturing far more than hypertension treatment.
--
-- REMEMBER WHAT THIS MEASURES. Beta blockers are given for arrhythmia and post-MI, loop diuretics
-- for heart failure and oedema, CCBs for angina, spironolactone for cirrhosis. So this is "on a
-- blood-pressure-lowering drug", NOT "treated for hypertension". PREVENT's input is the former, so
-- the over-capture is inherent to the measure — but it is not nothing, and it should be stated
-- wherever bp_tx is used rather than discovered by a reviewer.
-- ================================================================================================
-- SELECT COUNT(DISTINCT de.person_id) AS n_people_any_antihypertensive
-- FROM drug_exposure de
-- JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
-- JOIN concept anc         ON anc.concept_id = ca.ancestor_concept_id
-- WHERE anc.vocabulary_id = 'RxNorm'
--   AND anc.concept_class_id = 'Ingredient'
--   AND LOWER(anc.concept_name) IN ( /* same list as Query A */ );
