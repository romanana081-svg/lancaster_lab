# FORMAT.md — Specification for a Synthetic All of Us CDR (Test Fixture)

Status: **specification only.** No generator code and no data files exist yet. This document is the
blueprint from which they should be built.

---

## 1. Purpose and non-goals

### The problem

`LDLR Get phenotypes.ipynb` runs only inside the All of Us Researcher Workbench. It reads BigQuery
tables from `WORKSPACE_CDR` and round-trips CSVs through a GCS bucket via `gsutil`. Consequently:

- Neither the auto-generated SQL nor the R cleaning pipeline can be executed, debugged, or
  regression-tested outside the Workbench.
- Every change to the cleaning logic must be validated by hand, against real controlled-tier data,
  inside a session that costs BigQuery time.
- The notebook does not run cleanly top-to-bottom (see `CLAUDE.md`), so there is no way to tell
  whether an edit broke something downstream.

### The goal

A **synthetic stand-in for the CDR**: a small database with the same table names, column names, and
OMOP semantics as the real thing, deliberately seeded with *unclean and missing* data, so that:

1. The "Do once" Dataset-Builder SQL can be run locally against it, and
2. The "Format ..." R cleaning cells can be run against its CSV exports, and
3. The final `pheno_df3` can be **asserted against a known-correct answer key**.

### Non-goals — read this before generating anything

- **This is not, and must never contain, real participant data.** Every value is invented. Nothing in
  this fixture may be derived from, copied out of, or reverse-engineered from the controlled-tier
  CDR. Generating it requires no Workbench access and no data-use agreement.
- It is **not a faithful statistical replica** of All of Us. It reproduces *structure* and *defect
  classes*, not real distributions, prevalences, or effect sizes. Never use it to estimate anything.
- It is not a performance benchmark. It is deliberately tiny.

Because it contains no real data, the fixture is safe to commit to this repository.

---

## 2. How the real pipeline works (what the fixture must imitate)

### Workbench environment

The notebook depends on four environment variables injected by the Workbench:

| Variable | Meaning | Fixture substitute |
|---|---|---|
| `WORKSPACE_CDR` | BigQuery dataset holding the CDR | Local DuckDB/SQLite database file |
| `WORKSPACE_BUCKET` | `gs://` bucket for the workspace | Local directory, e.g. `fixture/bucket/` |
| `GOOGLE_PROJECT` | BigQuery billing project | Unused offline |
| `OWNER_EMAIL` | Used to build export paths | Any string, e.g. `test@example.org` |

### The two-phase notebook shape

Every section of the notebook is:

1. **"Do once (done)"** — a Dataset-Builder-generated SQL string, executed with
   `bq_table_save(bq_dataset_query(...), <path>, destination_format = "CSV")`, which writes **sharded**
   CSVs to:

   ```
   gs://<WORKSPACE_BUCKET>/bq_exports/<OWNER_EMAIL>/<YYYYMMDD>/<name>/<name>_*.csv
   ```

2. **"Format ..."** — hardcodes a `gs://` path to a *previously produced* export and reads it with
   `read_bq_export_from_workspace_bucket()`, defined in `# Setup`:

   ```r
   read_bq_export_from_workspace_bucket <- function(export_path) {
     col_types <- cols(standard_concept_name = col_character(), ...)
     bind_rows(
       map(system2('gsutil', args = c('ls', export_path), stdout = TRUE, stderr = TRUE),
           function(csv) {
             chunk <- read_csv(pipe(str_glue('gsutil cat {csv}')), col_types = col_types, ...)
             chunk
           }))
   }
   ```

**Two consequences the fixture must honor:**

- The reader `bind_rows()` a *list* of shards discovered by `gsutil ls`. **The fixture must emit at
  least 2 shards per export** (e.g. `condition_99802609_000000000000.csv`,
  `..._000000000001.csv`), otherwise the sharding path is never exercised — and sharding is where
  column-type inference drift between shards would show up.
- Because export paths are pinned to dates (`20240321`, `20240324`, `20241101`, `20241104`), the
  fixture should either reuse those exact date strings or the "Format" cells must be re-pointed. The
  simplest option is to **mirror the real directory names verbatim** so the notebook needs no edits
  beyond `WORKSPACE_BUCKET`.

---

## 3. Layer A — BigQuery source tables

### 3.1 Conventions

- All of Us CDR v7 is **OMOP CDM v5.3.1**.
- **All of Us uses `TIMESTAMP`, not `DATETIME`,** for every `*_datetime` column. Replicate this; it
  changes how R's `readr` parses the exported CSVs.
- Tables are referenced **unqualified and backtick-quoted** in the generated SQL
  (`` FROM `condition_occurrence` ``) because `bq_dataset_query()` supplies the default dataset.
- `has_*` flags are **`INT64` 0/1**, not booleans.

Legend: **[OMOP]** standard OMOP 5.3 · **[AoU]** All of Us extension · **[CB]** Cohort Builder helper
· **[DS]** Dataset Builder view.

### 3.2 Tables the notebook actually touches (the required 12)

These twelve are the minimum needed to run every cell:

`person`, `condition_occurrence`, `procedure_occurrence`, `observation`, `measurement`,
`drug_exposure`, `visit_occurrence`, `concept`, `cb_search_person`, `cb_criteria`,
`cb_criteria_ancestor`, `ds_survey`.

Everything else in this section is specified for completeness / future reuse and may be created empty.

---

### `person` **[OMOP + AoU]**

| Column | Type | Null | Notes |
|---|---|---|---|
| person_id | INT64 | N | PK |
| gender_concept_id | INT64 | N | |
| year_of_birth | INT64 | Y | |
| month_of_birth | INT64 | Y | Non-informative in AoU |
| day_of_birth | INT64 | Y | Non-informative in AoU |
| birth_datetime | TIMESTAMP | Y | **Notebook reads this as `date_of_birth`** |
| race_concept_id | INT64 | N | `0` when `None Indicated` |
| ethnicity_concept_id | INT64 | N | |
| location_id | INT64 | Y | |
| provider_id | INT64 | Y | |
| care_site_id | INT64 | Y | |
| person_source_value | STRING | Y | Scrubbed |
| gender_source_value | STRING | Y | PPI code, e.g. `GenderIdentity_Man` |
| gender_source_concept_id | INT64 | Y | |
| race_source_value | STRING | Y | PPI code, e.g. `WhatRaceEthnicity_White` |
| race_source_concept_id | INT64 | Y | |
| ethnicity_source_value | STRING | Y | |
| ethnicity_source_concept_id | INT64 | Y | |
| **sex_at_birth_concept_id** | INT64 | Y | **[AoU]** — see note below |
| sex_at_birth_source_concept_id | INT64 | Y | **[AoU]** |
| sex_at_birth_source_value | STRING | Y | **[AoU]**, e.g. `SexAtBirth_Male` |

> **Discrepancy worth knowing.** The All of Us *curation* repo defines `sex_at_birth_*` on a separate
> `person_ext` table, not on `person`. But the notebook's generated SQL does
> `` LEFT JOIN `concept` p_sex_at_birth_concept ON person.sex_at_birth_concept_id = ... `` **from
> `person` directly** — so in the CDR as actually exposed to researchers, `person` carries these
> columns. **The fixture must put `sex_at_birth_concept_id` on `person`**, or the demographics query
> fails. Optionally also create `person_ext` for fidelity.

**Value conventions** — `race` and `sex_at_birth` in the notebook are `concept.concept_name` strings
resolved by the joins. Seed the fixture with the full realistic domain, not just the tidy values:

- Race: `White`, `Black or African American`, `Asian`, `Middle Eastern or North African`,
  `Native Hawaiian or Other Pacific Islander`, `More than one population`, `None of these`,
  `Hispanic or Latino`, **`PMI: Skip`**, **`I prefer not to answer`**, **`None Indicated`**.
- Sex at birth: `Male` (8507), `Female` (8532), `Intersex`, `No matching concept` (0), `PMI: Skip`,
  `I prefer not to answer`, `None Indicated`.

---

### `visit_occurrence` **[OMOP]** — required for censoring

| Column | Type | Null |
|---|---|---|
| visit_occurrence_id | INT64 | N |
| person_id | INT64 | N |
| visit_concept_id | INT64 | N |
| visit_start_date | DATE | N |
| **visit_start_datetime** | TIMESTAMP | Y |
| visit_end_date | DATE | N |
| visit_end_datetime | TIMESTAMP | Y |
| visit_type_concept_id | INT64 | N |
| provider_id | INT64 | Y |
| care_site_id | INT64 | Y |
| visit_source_value | STRING | Y |
| visit_source_concept_id | INT64 | Y |
| admitting_source_concept_id | INT64 | Y |
| admitting_source_value | STRING | Y |
| discharge_to_concept_id | INT64 | Y |
| discharge_to_source_value | STRING | Y |
| preceding_visit_occurrence_id | INT64 | Y |

`visit_concept_id`: 9201 Inpatient, 9202 Outpatient, 9203 Emergency Room, 581477 Office Visit, and
**`0` (unmapped — common in AoU; include some)**.

---

### `condition_occurrence` **[OMOP]**

| Column | Type | Null |
|---|---|---|
| condition_occurrence_id | INT64 | N |
| person_id | INT64 | N |
| condition_concept_id | INT64 | N |
| condition_start_date | DATE | N |
| **condition_start_datetime** | TIMESTAMP | Y |
| condition_end_date | DATE | Y |
| condition_end_datetime | TIMESTAMP | Y |
| condition_type_concept_id | INT64 | N |
| condition_status_concept_id | INT64 | Y |
| stop_reason | STRING | Y |
| provider_id | INT64 | Y |
| visit_occurrence_id | INT64 | Y |
| visit_detail_id | INT64 | Y |
| condition_source_value | STRING | Y |
| **condition_source_concept_id** | INT64 | Y | ← what the CAD/PAD/HC queries filter on |
| condition_status_source_value | STRING | Y |

`condition_concept_id` = SNOMED standard; `condition_source_concept_id` = ICD9CM/ICD10CM;
`condition_source_value` = raw ICD string (`I21.4`, `414.01`). `condition_type_concept_id` ≈ 32817 (EHR).

---

### `procedure_occurrence` **[OMOP]**

| Column | Type | Null |
|---|---|---|
| procedure_occurrence_id | INT64 | N |
| person_id | INT64 | N |
| procedure_concept_id | INT64 | N |
| procedure_date | DATE | N |
| **procedure_datetime** | TIMESTAMP | Y |
| procedure_type_concept_id | INT64 | N |
| modifier_concept_id | INT64 | Y |
| quantity | INT64 | Y |
| provider_id | INT64 | Y |
| visit_occurrence_id | INT64 | Y |
| visit_detail_id | INT64 | Y |
| procedure_source_value | STRING | Y |
| **procedure_source_concept_id** | INT64 | Y | ← what the CPT query filters on |
| modifier_source_value | STRING | Y |

`procedure_source_concept_id` = CPT4/HCPCS; `procedure_source_value` = raw CPT (`92941`, `33533`).

---

### `drug_exposure` **[OMOP]**

| Column | Type | Null |
|---|---|---|
| drug_exposure_id | INT64 | N |
| person_id | INT64 | N |
| **drug_concept_id** | INT64 | N | ← what the statin queries filter on |
| drug_exposure_start_date | DATE | N |
| **drug_exposure_start_datetime** | TIMESTAMP | Y |
| drug_exposure_end_date | DATE | N |
| drug_exposure_end_datetime | TIMESTAMP | Y |
| verbatim_end_date | DATE | Y |
| drug_type_concept_id | INT64 | N |
| stop_reason | STRING | Y |
| refills | INT64 | Y |
| quantity | FLOAT64 | Y |
| days_supply | INT64 | Y |
| sig | STRING | Y | Usually NULL in AoU |
| route_concept_id | INT64 | Y |
| lot_number | STRING | Y |
| provider_id | INT64 | Y |
| visit_occurrence_id | INT64 | Y |
| visit_detail_id | INT64 | Y |
| drug_source_value | STRING | Y |
| drug_source_concept_id | INT64 | Y |
| route_source_value | STRING | Y |
| dose_unit_source_value | STRING | Y |

Note the drug queries filter on **`drug_concept_id`** (standard), expanded through
`cb_criteria_ancestor` — unlike conditions/procedures, which filter on `*_source_concept_id`.

---

### `measurement` **[OMOP]**

| Column | Type | Null |
|---|---|---|
| measurement_id | INT64 | N |
| person_id | INT64 | N |
| **measurement_concept_id** | INT64 | N | ← LDL/Trig/BMI filter |
| measurement_date | DATE | N |
| **measurement_datetime** | TIMESTAMP | Y |
| measurement_time | STRING | Y |
| measurement_type_concept_id | INT64 | N |
| operator_concept_id | INT64 | Y | 4171756 `<`, 4172704 `>` |
| **value_as_number** | FLOAT64 | Y | |
| value_as_concept_id | INT64 | Y |
| unit_concept_id | INT64 | Y | Often `0` even when `unit_source_value` is set |
| range_low | FLOAT64 | Y |
| range_high | FLOAT64 | Y |
| provider_id | INT64 | Y |
| visit_occurrence_id | INT64 | Y |
| visit_detail_id | INT64 | Y |
| measurement_source_value | STRING | Y |
| measurement_source_concept_id | INT64 | Y |
| **unit_source_value** | STRING | Y | ← **the messy one**; see §7 |
| value_source_value | STRING | Y | Sometimes populated when `value_as_number` is NULL |

---

### `observation` **[OMOP + 3 AoU columns]** — all survey/PPI data lives here

| Column | Type | Null |
|---|---|---|
| observation_id | INT64 | N |
| person_id | INT64 | N |
| observation_concept_id | INT64 | N | ← CAD-family-history query filters on this (`4047566`) |
| observation_date | DATE | N |
| **observation_datetime** | TIMESTAMP | Y |
| observation_type_concept_id | INT64 | N | 45905771 = "recorded from a Survey" |
| value_as_number | FLOAT64 | Y |
| value_as_string | STRING | Y |
| value_as_concept_id | INT64 | Y |
| qualifier_concept_id | INT64 | Y |
| unit_concept_id | INT64 | Y |
| provider_id | INT64 | Y |
| visit_occurrence_id | INT64 | Y |
| visit_detail_id | INT64 | Y |
| observation_source_value | STRING | Y | PPI question code |
| **observation_source_concept_id** | INT64 | Y | ← FH query filters on this (`37202301`) |
| unit_source_value | STRING | Y |
| qualifier_source_value | STRING | Y |
| **value_source_concept_id** | INT64 | Y | **[AoU]** |
| **value_source_value** | STRING | Y | **[AoU]** PPI answer code |
| **questionnaire_response_id** | INT64 | Y | **[AoU]** groups one survey submission |

Non-answer concepts to seed: `PMI: Skip` = **903096**, `I prefer not to answer` = **1177221**,
`PMI: Dont Know` = **903087**.

> Note the notebook filters FH on `observation_source_concept_id` but CAD family history on
> `observation_concept_id`. Both paths must work.

---

### `concept` **[OMOP]**

| Column | Type | Null |
|---|---|---|
| concept_id | INT64 | N |
| concept_name | STRING | N |
| domain_id | STRING | N |
| vocabulary_id | STRING | N |
| concept_class_id | STRING | N |
| standard_concept | STRING | Y | `S`, `C`, or NULL |
| concept_code | STRING | N |
| valid_start_date | DATE | N |
| valid_end_date | DATE | N |
| invalid_reason | STRING | Y |

`vocabulary_id` values needed: `SNOMED`, `ICD9CM`, `ICD10CM`, `CPT4`, `RxNorm`, `ATC`, `LOINC`,
`UCUM`, `PPI`, `Race`, `Gender`, `Visit`, `Meas Value`.

The `concept` table is joined **seven times** in some generated queries (standard, type, visit,
source, status, unit, value). Every `*_concept_id` the fixture emits should resolve, or the CSV export
will carry NULL names where real data has strings.

---

### `concept_ancestor`, `concept_relationship` **[OMOP]** (not used by this notebook; seed empty or minimal)

- `concept_ancestor`: `ancestor_concept_id INT64`, `descendant_concept_id INT64`,
  `min_levels_of_separation INT64`, `max_levels_of_separation INT64` (all NOT NULL).
- `concept_relationship`: `concept_id_1 INT64`, `concept_id_2 INT64`, `relationship_id STRING`,
  `valid_start_date DATE`, `valid_end_date DATE`, `invalid_reason STRING`.

---

### `cb_search_person` **[CB]** — the cohort gate

Every generated query in the notebook filters:

```sql
person_id IN (SELECT person_id FROM `cb_search_person` p WHERE has_whole_genome_variant = 1)
```

All columns NULLABLE. The ones that matter:

| Column | Type | Notes |
|---|---|---|
| person_id | INT64 | |
| gender / sex_at_birth / race / ethnicity | STRING | **Denormalized concept_name strings** |
| dob | DATE | |
| age_at_consent / age_at_cdr | INT64 | Precomputed |
| has_ehr_data | INT64 | 0/1 |
| has_ppi_survey_data | INT64 | 0/1 |
| has_physical_measurement_data | INT64 | 0/1 |
| is_deceased | INT64 | 0/1 |
| **has_whole_genome_variant** | INT64 | **0/1 — the cohort gate** |
| has_array_data | INT64 | 0/1 |
| has_lr_whole_genome_variant | INT64 | 0/1 |
| has_structural_variant_data | INT64 | 0/1 |
| state_of_residence | STRING | |
| has_fitbit* (many) | INT64 | May be omitted from the fixture |

**Critical:** the fixture must include participants with `has_whole_genome_variant = 0` so that the
cohort gate is genuinely exercised (i.e. a bug that drops the filter would change row counts).

---

### `cb_criteria` **[CB]** — the concept hierarchy. **The easiest table to get silently wrong.**

The condition / procedure / measurement queries expand concepts through this table:

```sql
SELECT DISTINCT c.concept_id
FROM `cb_criteria` c
JOIN (SELECT CAST(cr.id AS string) AS id
      FROM `cb_criteria` cr
      WHERE concept_id IN (<hardcoded ids>)
        AND full_text LIKE '%_rank1]%') a
  ON (c.path LIKE CONCAT('%.', a.id, '.%')
      OR c.path LIKE CONCAT('%.', a.id)
      OR c.path LIKE CONCAT(a.id, '.%')
      OR c.path = a.id)
WHERE is_standard = 0 AND is_selectable = 1
```

| Column | Type | Notes |
|---|---|---|
| **id** | INT64 | Surrogate PK; appears inside `path` |
| parent_id | INT64 | `0` for roots |
| domain_id | STRING | `CONDITION`, `DRUG`, `MEASUREMENT`, `OBSERVATION`, `PROCEDURE`, ... |
| **is_standard** | INT64 | **Must be `0`** for the source-concept rows these queries select |
| type | STRING | `ICD9CM`, `ICD10CM`, `CPT4`, `SNOMED`, `RXNORM`, `ATC`, `LOINC`, `PPI` |
| subtype | STRING | `CLIN`, `LAB`, `ATC`, `BRAND`, `QUESTION`, `ANSWER` |
| **concept_id** | INT64 | The OMOP concept |
| code | STRING | e.g. `I21.4` |
| name | STRING | |
| value | STRING | |
| est_count | INT64 | |
| is_group | INT64 | 0/1 |
| **is_selectable** | INT64 | **Must be `1`** |
| has_attribute | INT64 | 0/1 |
| has_hierarchy | INT64 | 0/1 |
| has_ancestor_data | INT64 | 0/1 — `1` for drugs (routes expansion to `cb_criteria_ancestor`) |
| **path** | STRING | Dot-delimited chain of `id`s, e.g. `"1.24.512.9987"` |
| synonyms | STRING | |
| rollup_count / item_count | INT64 | |
| **full_text** | STRING | **Must contain a `[<domain>_rank1]` token** |
| display_synonyms | STRING | |

**The four invariants the fixture MUST satisfy** (violating any of them yields *zero rows and no
error* — the failure mode is silent):

1. Every seeded concept has a `cb_criteria` row with `is_standard = 0` and `is_selectable = 1`.
2. That row's `full_text` matches `LIKE '%_rank1]%'` — e.g. `"Acute myocardial infarction|I21.4|[condition_rank1]"`.
3. `path` is a real dot-delimited ancestry of `cb_criteria.id` values, and a node's own `id` appears
   in its `path` (so the `c.path = a.id` / `LIKE CONCAT(a.id, '.%')` branches match).
4. `id` and `concept_id` are **different number spaces**. Do not conflate them; the join casts
   `id` to string and pattern-matches it inside `path`.

A minimal working shape for one CAD leaf:

| id | parent_id | concept_id | is_standard | is_selectable | path | full_text |
|---|---|---|---|---|---|---|
| 512 | 24 | 44827783 | 0 | 1 | `1.24.512` | `Acute MI\|I21.4\|[condition_rank1]` |

---

### `cb_criteria_ancestor` **[CB]** — drug rollup

```sql
SELECT DISTINCT ca.descendant_id
FROM `cb_criteria_ancestor` ca
WHERE ca.ancestor_id IN (<statin ingredient concept_ids>)
```

| Column | Type |
|---|---|
| ancestor_id | INT64 |
| descendant_id | INT64 |

Both are **concept_ids** (not `cb_criteria.id`). Seed one row per (ingredient → clinical drug) pair,
and include the ingredient as its own descendant so a `drug_exposure` row carrying the ingredient
concept still matches.

*Confidence note: this two-column shape is inferred from the generated SQL, not from a published
schema. Confirm in-Workbench with `INFORMATION_SCHEMA.COLUMNS` before relying on extra columns.*

---

### `ds_survey` **[DS]** — the flattened survey view

The only `ds_*` view the notebook uses. Queried directly (no `cb_criteria` expansion):

| Column | Type |
|---|---|
| person_id | INT64 |
| survey_datetime | TIMESTAMP |
| survey | STRING |
| question_concept_id | INT64 |
| question | STRING |
| answer_concept_id | INT64 |
| answer | STRING |
| survey_version_concept_id | INT64 |
| survey_version_name | STRING |

Model it as a **view over `observation`** (PPI rows), not as an independent table — and make it
**lossy**, since the real `ds_survey` is known to drop some skip/non-response rows that *are* present
in `observation`.

---

### Tables to create but leave empty (for schema completeness)

`observation_period`, `death`, `device_exposure`, `visit_detail`, `condition_era`, `drug_era`,
`dose_era`, `note`, `note_nlp`, `provider`, `care_site`, `location`, `cdm_source`,
`fact_relationship`, `payer_plan_period`, `cost`, `survey_conduct`, `person_ext` and the other
`*_ext` provenance tables (`<domain>_id`, `src_id`), `cb_search_all_events`, `cb_criteria_attribute`,
`cb_survey_version`, `cb_person`, `vocabulary`, `domain`, `concept_class`, `concept_synonym`,
`relationship`, `drug_strength`, and the remaining `ds_*` views.

Two AoU quirks worth replicating if you create them: `cb_criteria_attribute.est_count` is a **STRING**
(not INT64), and `ds_observation` has three **lowercase** column names among otherwise uppercase ones.

---

## 4. Layer B — the CSV export shapes

These are the exact ordered columns produced by each "Do once" query. They are what
`read_bq_export_from_workspace_bucket()` returns, and therefore the contract the "Format" cells code
against. **The fixture can be built at this layer alone** (skipping SQL entirely) by writing these
CSVs directly.

Note every export **denormalizes** concept names/codes/vocabularies via repeated `LEFT JOIN concept`,
so `standard_concept_name`, `source_concept_code`, etc. are *columns in the CSV*, not joins the R code
performs.

### Condition export (MI/IHD, PAD, FH-condition, hypercholesterolemia)

```
person_id, condition_concept_id, standard_concept_name, standard_concept_code, standard_vocabulary,
condition_start_datetime, condition_end_datetime, condition_type_concept_id,
condition_type_concept_name, stop_reason, visit_occurrence_id, visit_occurrence_concept_name,
condition_source_value, condition_source_concept_id, source_concept_name, source_concept_code,
source_vocabulary, condition_status_source_value, condition_status_concept_id,
condition_status_concept_name
```

### Procedure export (coronary athero CPT)

```
person_id, procedure_concept_id, standard_concept_name, standard_concept_code, standard_vocabulary,
procedure_datetime, procedure_type_concept_id, procedure_type_concept_name, modifier_concept_id,
modifier_concept_name, quantity, visit_occurrence_id, visit_occurrence_concept_name,
procedure_source_value, procedure_source_concept_id, source_concept_name, source_concept_code,
source_vocabulary, modifier_source_value
```

### Observation export (FH, CAD family history)

```
person_id, observation_concept_id, standard_concept_name, standard_concept_code, standard_vocabulary,
observation_datetime, observation_type_concept_id, observation_type_concept_name, value_as_number,
value_as_string, value_as_concept_id, value_as_concept_name, qualifier_concept_id,
qualifier_concept_name, unit_concept_id, unit_concept_name, visit_occurrence_id,
visit_occurrence_concept_name, observation_source_value, observation_source_concept_id,
source_concept_name, source_concept_code, source_vocabulary, unit_source_value,
qualifier_source_value, value_source_concept_id, value_source_value, questionnaire_response_id
```

### Measurement export (LDL/Trig, BMI)

```
person_id, measurement_concept_id, standard_concept_name, standard_concept_code, standard_vocabulary,
measurement_datetime, measurement_type_concept_id, measurement_type_concept_name,
operator_concept_id, operator_concept_name, value_as_number, value_as_concept_id,
value_as_concept_name, unit_concept_id, unit_concept_name, range_low, range_high,
visit_occurrence_id, visit_occurrence_concept_name, measurement_source_value,
measurement_source_concept_id, source_concept_name, source_concept_code, source_vocabulary,
unit_source_value, value_source_value
```

### Drug export (statins, non-statins)

```
person_id, drug_concept_id, standard_concept_name, standard_concept_code, standard_vocabulary,
drug_exposure_start_datetime, drug_exposure_end_datetime, verbatim_end_date, drug_type_concept_id,
drug_type_concept_name, stop_reason, refills, quantity, days_supply, sig, route_concept_id,
route_concept_name, lot_number, visit_occurrence_id, visit_occurrence_concept_name,
drug_source_value, drug_source_concept_id, source_concept_name, source_concept_code,
source_vocabulary, route_source_value, dose_unit_source_value
```

### Person export (demographics)

```
person_id, date_of_birth, race, sex_at_birth
```

(`date_of_birth` is `person.birth_datetime` aliased; `race`/`sex_at_birth` are `concept.concept_name`.)

### Survey export (`ds_survey`, question `43528793`)

```
person_id, survey_datetime, survey, question_concept_id, question, answer_concept_id, answer,
survey_version_concept_id, survey_version_name
```

### `col_types` contract

`read_bq_export_from_workspace_bucket()` passes a fixed `cols(...)` spec forcing these to character:
`standard_concept_name`, `standard_concept_code`, `standard_vocabulary`,
`condition_type_concept_name`, `stop_reason`, `visit_occurrence_concept_name`,
`condition_source_value`, `source_concept_name`, `source_concept_code`, `source_vocabulary`,
`condition_status_source_value`, `condition_status_concept_name`.

Note this spec is **condition-shaped** but applied to *every* domain, so for non-condition exports the
extra names are simply absent and everything else is type-inferred per shard. **A column that is
all-empty in shard 1 but populated in shard 2 will infer inconsistently** — a defect worth injecting
deliberately (see §7).

---

## 5. Seed vocabulary — the concept IDs that must resolve

The generated SQL hardcodes concept IDs. **If a concept ID has no `cb_criteria` row satisfying the
§3 invariants, its query returns zero rows silently.** Every ID below must be seeded in `concept` and
(except `ds_survey`) in `cb_criteria`.

| Section | Domain | Filter column | Concept IDs |
|---|---|---|---|
| MI / ischemic heart disease | condition | `condition_source_concept_id` | 94 ICD9CM/ICD10CM concepts: `1326588, 1569127, 1569134, 1569135, 1569145, 35207684–35207706, 44819697–44837099, 45533436–45605788` |
| Coronary athero CPT | procedure | `procedure_source_concept_id` | CPT4 concepts `2107216, 2107217, 2107218, 2107219, 2107220, 2107221, 2107222, 2107223, 2107224, 2107226, 2107227, 2107228, 2107231, 2107242, 2107243, 2107244, 2107250, …` |
| PAD | condition | `condition_concept_id` | `317309`, `3654996` |
| FH (familial hypercholesterolemia) | observation | `observation_source_concept_id` | `37202301` |
| FH | condition | `condition_source_concept_id` | `37200313` |
| CAD family history | observation | `observation_concept_id` | `4047566` |
| Hypercholesterolemia | condition | `condition_source_concept_id` | `35207060`, `37200312`, `37200313`, `44834564` |
| Statins | drug | `drug_concept_id` (via `cb_criteria_ancestor`) | `1510813, 1539403, 1545958, 1549686, 1551860, 1592085, 1592180, 40165636` |
| Non-statins | drug | `drug_concept_id` (via `cb_criteria_ancestor`) | `1501617, 1517824, 1518148, 1526475, 1551803, 1558242, 19095309, 37499009, 43560137, 46275447, 46287466` |
| LDL / triglycerides | measurement | `measurement_concept_id` | `3022192` (**triglycerides**), `37026687` |
| BMI | measurement | `measurement_concept_id` | `3038553` |
| Statin survey question | `ds_survey` | `question_concept_id` | `43528793` |

**Note the LDL/Trig split.** The measurement query pulls both analytes into one `labs_df`, then the R
code splits them:

```r
trig_df <- labs_df[labs_df$measurement_concept_id == 3022192, ]
ldl_df  <- labs_df[  labs_df$measurement_concept_id != 3022192 & ... , ]
```

So **LDL is defined negatively** — anything in the export that isn't `3022192`. If the fixture adds a
third analyte to that measurement query, it silently becomes "LDL". Worth a defect test.

**Also seed:** unit concepts (`mg/dL`, `kg/m2`), visit concepts (9201/9202/9203/581477/0), type
concepts (32817 EHR, 45905771 survey), and the demographic race/sex concepts named in §3.

**PREVENT panel concepts (added by T-004, 2026-07-20).** The study is no longer the LDLR study; the
PREVENT inputs (D-004, D-013) are seeded so `sql/01_prevent_concept_discovery.sql` resolves every code
and `sql/02_prevent_panel_completeness.sql` can count a complete panel offline. Total cholesterol
(`2093-3`), HDL-C (`2085-9`) and BMI (`39156-5`) already existed; T-004 adds:

| PREVENT input | Domain | Filter column | Concept / code |
|---|---|---|---|
| Systolic BP | measurement | `measurement_concept_id` | `3004249` (LOINC `8480-6`), unit `mmHg` |
| Serum creatinine | measurement | `measurement_concept_id` | `3016723` (LOINC `2160-0`), unit `mg/dL` |
| HbA1c | measurement | `measurement_concept_id` | `3004410` (`4548-4`), `3007263` (`17856-6`), unit `%` |
| Diabetes | condition | `condition_source_concept_id` | `45591001`/`45591002` (ICD10CM `E11.9`/`E10.9`); SNOMED std `201826` |
| Antihypertensive | drug | `drug_concept_id` (via `cb_criteria_ancestor`) | `1308216`, `974166` — **illustrative only** |
| Current smoking | `ds_survey` | `question_concept_id` | `1585857` — **illustrative only** |

The three new **measurement** concepts are seeded as *standalone* `cb_criteria` nodes (not under the
lipid group `37026687`), precisely so they do **not** get swept into the negatively-defined LDL export
above. Only HDL (`2085-9`) and total cholesterol (`2093-3`) are lipid-group leaves and therefore
reach `labs_df` — HDL is misread as LDL (defect A9), total cholesterol is excluded by the notebook.

---

## 6. Synthetic cohort design

### Scale

Real CDR v7 (`C2022Q4R9`, cutoff 2022-07-01):

| Quantity | Real v7 |
|---|---|
| `person` rows | 413,457 |
| `has_whole_genome_variant = 1` (the study cohort) | **245,394** |
| `has_array_data = 1` | 312,945 |
| Participants with EHR data | ~287,000+ |

**Fixture target: 300 persons.** Small enough to eyeball and to commit; large enough that
`group_by`/`distinct` behavior is meaningful. Proportions to preserve (not absolute counts):

- ~60% `has_whole_genome_variant = 1` → ~180 in-cohort persons. The other ~120 exist **only** to prove
  the cohort gate works and must never appear in any output.
- Of the in-cohort persons, ~70% have EHR data; ~30% have **none** (survey/genomic only).
- ~24 of them are the hand-authored scenario persons in §8; the rest are randomized filler.

### Identifiers

- `person_id`: 7-digit, `1000001`–`1000300`. Reserve `1000001`–`1000024` for the scenario persons so
  the answer key is stable as filler is regenerated.
- Other surrogate keys (`measurement_id`, etc.): monotonically increasing, unique, non-overlapping
  across tables.
- `cb_criteria.id`: a separate number space starting at `1` — **never equal to a `concept_id`**.

### Dates

Generate coherent per-person timelines spanning roughly **1990-01-01 → 2022-07-01** (the v7 cutoff).
Order within a person must always be sane except where a defect deliberately breaks it:
`birth_datetime` < first visit ≤ measurements/conditions ≤ cutoff.

**On date shifting.** All of Us shifts every participant's dates backward by a constant random 1–365
days for privacy. Sources conflict on whether the *Controlled* Tier (which this notebook uses) serves
shifted or unshifted dates — the Cell 2022 data-quality paper describes the Controlled Tier as
providing "unshifted dates of events," while the Participant Privacy Protections page describes
shifting broadly. **For the fixture this is immaterial**, because shifting is constant within a person
and every computation in the notebook is a within-person date difference. Recommendation: generate
unshifted, coherent timelines, and expose an optional `--date-shift` knob if someone later wants to
test cross-participant date logic (which would be a bug anyway).

Times of day should frequently be exactly `00:00:00` — real EHR datetimes often carry no time.

---

## 7. Defect catalogue

Each defect: what it is, where to inject it, and which notebook cell is meant to absorb it.

### 7.1 Defects the notebook already handles

| # | Defect | Where | Injection | Caught by |
|---|---|---|---|---|
| D1 | **Inconsistent units** | `measurement.unit_source_value` | Mix `mg/dL`, `mg/dl`, `MG/DL`, `mg/dL calc`, `mmol/L`, `%`, empty, `unk` for lipids; `kg/m2`, `kg/m^2`, `Kg/M2`, NULL for BMI | `filter(unit_source_value == 'mg/dL')` / `== 'kg/m2'` |
| D2 | **Non-physiologic values** | `measurement.value_as_number` | LDL `0`, `-1`, `9999`; Trig `5000`; BMI `0.2`, `900`. ~2% of rows | `filter(value_as_number > 1 & < 1000)`; LDL `< 400`; BMI `> 14 & < 60` |
| D3 | **Same-day duplicate measurements** | `measurement` | 2–3 rows, same `person_id` + `measurement_concept_id` + date, different `measurement_id`, values equal or slightly different. ~15% of person-analyte pairs | `filter(date == min(date))` **does not fix this** — `distinct(person_id, .keep_all=TRUE)` does. This is precisely why step 5 of the cleaning idiom exists |
| D4 | **LDL == Trig** | `measurement` | For ~2% of persons with both analytes, emit identical `value_as_number` for LDL and Trig on the same date | `### Troubleshooting`: `diff = LDL - Trig`, drop `diff == 0`. **Applied only to the scratch frame `ldl_trig`, NOT to `ldl_df`/`trig_df` used in the main join** — so the defect *survives* into `pheno_df`. The fixture should make this visible |
| D5 | **No EHR data at all** | all clinical tables | ~30% of in-cohort persons have zero condition/procedure/measurement/visit rows | `left_join` onto `demo_df` → NA columns; `CAD_code` → 0 |
| D6 | **`PMI: Skip` / `None Indicated` demographics** | `person` → `concept.concept_name` | ~8% of persons get `PMI: Skip`, `I prefer not to answer`, or `None Indicated` for race and/or sex_at_birth | Nothing filters these — they flow into `pheno_df2$race` as literal strings. Intentional; confirm they don't break downstream `factor()`/model code |
| D7 | **CAD code precedes first visit** | `condition_occurrence` vs `visit_occurrence` | Give some persons a CAD condition dated before their earliest `visit_start_datetime` (realistic: conditions can carry NULL `visit_occurrence_id`) | The censoring section's `type == 2` branch |

### 7.2 Adversarial defects — currently **NOT** handled

These exist to expose gaps. A correct pipeline should either handle them or fail loudly; today most
pass through silently.

| # | Defect | Injection | Expected failure |
|---|---|---|---|
| A1 | **Case-variant unit** | `unit_source_value = 'mg/dl'` (lowercase L) on an otherwise-valid LDL row | `filter(== 'mg/dL')` **silently drops the row**. The person loses their LDL entirely and no warning is raised. High-value test |
| A2 | **`value_as_number` NULL, `value_source_value` populated** | `value_as_number = NULL`, `value_source_value = '<10'` / `'>500'` / `'TNP'` / `'CANCELED'`, `operator_concept_id` set | `filter(value_as_number > 1 & < 1000)` drops NULLs silently. Censored lab values are discarded rather than handled |
| A3 | **`birth_datetime` after event dates** | One person with DOB *after* their CAD code date | `CAD_age = year(CAD_code_date) - year(date_of_birth)` yields a **negative age**. Nothing checks |
| A4 | **Duplicate `person` rows** | Same `person_id` twice in `person` with different race | `demo_df` is the left-most table of the join → **row multiplication** across the entire `pheno_df`. Nothing dedups `demo_df` |
| A5 | **NULL `person_id`** | One `measurement` row with NULL `person_id` | `group_by(person_id)` creates an NA group that survives to the join |
| A6 | **WGS participant with zero visits** | `has_whole_genome_variant = 1`, has a CAD code, but **no `visit_occurrence` rows** | Censoring computes `max(visit_start_datetime)` over an empty set → `-Inf` / NA. Types 1 and 3 both break |
| A7 | **`LDL_measured_on_meds` NA propagation** | Person with an LDL value but no meds at all (`any_chol_med_start_date` = NA) | `case_when(LDL_dt <= start ~ 0, LDL_dt > start ~ 1)` has **no `.default`** → yields **NA**, not 0. Untreated persons get NA instead of "not on meds" |
| A8 | **Cross-shard type inference** | A column empty in shard 1, populated in shard 2 | `read_csv` infers per shard; `bind_rows` may coerce or error |
| A9 | **Extra analyte in the LDL query** | A measurement row with a lipid concept that is neither `3022192` nor a real LDL concept | `ldl_df` is defined as `measurement_concept_id != 3022192` → the stray analyte **becomes LDL** |

### 7.3 Suspected pre-existing bug the fixture should pin down

**`any_chol_med` collapses to 1 for everyone in `meds_df`, including people who answered "No."**

The chain:

1. `meds_df <- full_join(statin_df, nonstatin_df) |> full_join(survey_df)`. `survey_df` contains
   **every** responder to question `43528793` — including those who answered *No*.
2. `mutate(any_chol_med = case_when(on_statin=='yes' | on_nonstatin=='yes' | ans=='Yes' ~ 'yes', .default = 'no'))`
   → correctly yields the **string** `'no'` for a non-medicated responder.
3. But then, after the join into `pheno_df2`:
   ```r
   pheno_df2$any_chol_med[!is.na(pheno_df2$any_chol_med)] <- 1
   pheno_df2$any_chol_med[ is.na(pheno_df2$any_chol_med)] <- 0
   ```
   `'no'` is **not NA**, so it becomes **`1`**. Only people entirely absent from `meds_df` (never
   surveyed, no prescriptions) get `0`.

Net effect: anyone who merely *answered the survey* is coded as being on cholesterol medication.
Additionally, `any_chol_med_start_date` for such a person is their **survey date**, which then drives
`LDL_measured_on_meds`.

The fixture must include a person in exactly this state (see `P014` in §8). This has **not** been
confirmed against real data — the fixture is the way to confirm it. Per `CLAUDE.md`, do not silently
"fix" this; the point is to make it reproducible and visible.

---

## 8. Ground-truth answer key

27 hand-authored persons, `1000001`–`1000027`, one per scenario. Each row states what the final
`pheno_df3` **should** contain. Where the current pipeline is expected to produce something *else*,
that is stated explicitly — those are the tests that should fail today.

> **T-004 (2026-07-20) added a second wave: `1000028`–`1000034`, the PREVENT panel participants.**
> They exercise systolic BP, serum creatinine, HbA1c/diabetes, smoking and antihypertensive use, and
> the answer key gains `has_*` / `complete_prevent_panel` columns (populated only for them). They are
> checked by `tests/testthat/test-prevent-panel-sql.R` against `sql/02_prevent_panel_completeness.sql`,
> not only by `verify.py`. Because the LDLR pipeline is unchanged, each one's HDL row is still misread
> as LDL (A9), which is what their `LDL` column records. Filler now runs `1000035`–`1000307`. See
> `fixture/README.md` for the per-participant table.

> This section was revised after the fixture was actually built (see §11). Three changes: the
> adversarial cases A4/A8/A9 got their own persons (P25–P27) rather than being folded into existing
> ones; P10 carries **no survey response** (a survey "No" would have tripped the §7.3 bug and muddied
> its expectation); and P06's expected LDL is a *set*, not a value — see below.

Shared reference values (used unless a scenario overrides): DOB `1960-06-15`, first visit
`2010-03-01`, last visit `2021-11-20`.

| # | person_id | Scenario | Defects | Expected `CAD_code` / `CAD_code_date` | Expected `LDL` / date | Expected `any_chol_med` | Censor type → `CAD_censored_date` |
|---|---|---|---|---|---|---|---|
| P01 | 1000001 | Clean baseline: ICD CAD code, clean LDL, statin | — | 1 / 2015-04-10 | 130 / 2012-05-02 | 1 | 3 → 2021-11-20 |
| P02 | 1000002 | Clean, no CAD at all | — | 0 / NA | 110 / 2013-01-09 | 0 | 1 → 2021-11-20 |
| P03 | 1000003 | CAD via **CPT only** (no ICD) | — | 1 / 2016-08-22 | 145 / 2011-02-11 | 0 | 3 → 2021-11-20 |
| P04 | 1000004 | Both ICD **and** CPT; ICD earlier | — | 1 / **2014-03-05** (earliest of the two) | 160 / 2010-06-01 | 1 | 3 → 2021-11-20 |
| P05 | 1000005 | CAD code **before** first visit | D7 | 1 / 2009-05-01 | 120 / 2011-04-04 | 0 | **2 → 2009-05-01** |
| P06 | 1000006 | Duplicate same-day LDL (3 rows, values 130/131/132) | D3 | 0 / NA | **one of {130, 131, 132}** — exactly one row survives, but *which* is arbitrary (see below) / 2012-05-02 | 0 | 1 → 2021-11-20 |
| P07 | 1000007 | LDL rows in `mmol/L` and `%` only | D1 | 0 / NA | **NA** (all rows filtered out) | 0 | 1 → 2021-11-20 |
| P08 | 1000008 | LDL = `9999`, and a valid `140` on a later date | D2 | 0 / NA | **140** / later date (outlier dropped *before* the earliest-record filter) | 0 | 1 → 2021-11-20 |
| P09 | 1000009 | LDL == Trig (both `180` on same date) | D4 | 0 / NA | **180** / date — *defect survives*; `ldl_df`/`trig_df` are not filtered by `diff != 0` | 0 | 1 → 2021-11-20 |
| P10 | 1000010 | Genomic only — **zero EHR rows, no survey** | D5 | 0 / NA | NA | 0 | 1 → **NA** (no visits) |
| P11 | 1000011 | Race = `PMI: Skip`, sex = `I prefer not to answer` | D6 | 0 / NA | 115 / 2014-07-07 | 0 | 1 → 2021-11-20 |
| P12 | 1000012 | Race = `None Indicated` (`race_concept_id = 0`) | D6 | 0 / NA | 125 / 2013-03-03 | 0 | 1 → 2021-11-20 |
| P13 | 1000013 | Non-statin (ezetimibe) only, no statin | — | 0 / NA | 150 / 2016-01-01 | 1 (start = drug date) | 1 → 2021-11-20 |
| P14 | 1000014 | **Survey answered "No"**, no prescriptions | §7.3 | 0 / NA | 105 / 2018-02-02 | **0** *(pipeline currently yields **1**)* | 1 → 2021-11-20 |
| P15 | 1000015 | Survey answered "Yes", no prescriptions | — | 0 / NA | 190 / 2019-05-05 | 1 (start = survey date) | 1 → 2021-11-20 |
| P16 | 1000016 | Statin **before** LDL draw | — | 0 / NA | 95 / 2017-06-06 | 1 (start 2015-01-01) | 1 → 2021-11-20 |
| P17 | 1000017 | LDL drawn **before** any medication | — | 0 / NA | 175 / 2012-01-01 | 1 (start 2016-01-01) | 1 → 2021-11-20 |
| P18 | 1000018 | PAD + FH + CAD family history + hypercholesterolemia, all present | — | 0 / NA | 200 / 2015-09-09 | 0 | 1 → 2021-11-20 |
| P19 | 1000019 | BMI in `kg/m^2` and a `900` outlier | D1, D2 | 0 / NA | 120 / 2014-01-01 | 0 | 1 → 2021-11-20 |
| P20 | 1000020 | **`has_whole_genome_variant = 0`** — must be absent everywhere | — | **Must not appear in `pheno_df3` at all** | — | — | — |
| P21 | 1000021 | LDL unit `mg/dl` (lowercase) — the only LDL row | **A1** | 0 / NA | **NA** *(row silently dropped; ideally 135)* | 0 | 1 → 2021-11-20 |
| P22 | 1000022 | LDL `value_as_number = NULL`, `value_source_value = '<10'` | **A2** | 0 / NA | **NA** *(silently dropped)* | 0 | 1 → 2021-11-20 |
| P23 | 1000023 | DOB `2019-01-01`, CAD code `2015-04-10` | **A3** | 1 / 2015-04-10 | 130 / 2012-05-02 | 0 | 3 → **negative `CAD_age`** |
| P24 | 1000024 | WGS + CAD code, **zero `visit_occurrence` rows** | **A6** | 1 / 2015-04-10 | 130 / 2012-05-02 | 0 | **breaks** — `max(visit_start_datetime)` over empty set |

| P25 | 1000025 | Stray lipid analyte (HDL `3007352`) plus a correctly-excluded `3008631` row | **A9** | 0 / NA | **55** — the HDL value, silently treated as LDL | 0 | 1 → 2021-11-20 |
| P26 | 1000026 | Same `person_id` twice in `person`, different race | **A4** | 0 / NA | 140 / 2015-05-05 | 0 | 1 → 2021-11-20 — **expect 2 rows, not 1** |
| P27 | 1000027 | `stop_reason` populated only here, and only in the final shard | **A8** | 1 / 2016-06-06 | 128 / 2016-06-06 | 0 | 3 → 2021-11-20 |

**A5** (NULL `person_id`) is a single orphan `measurement` row belonging to no participant, not a
scenario person. **A7** (`LDL_measured_on_meds` NA) is covered by P02.

### A finding from building this: the duplicate tie-break is not deterministic

`filter(date == min(date))` leaves *all* of a person's same-day duplicates; only
`distinct(person_id, .keep_all = TRUE)` reduces them to one — and `distinct()` keeps whichever row
appears **first**. The generated SQL carries no `ORDER BY`, and BigQuery does not guarantee row order,
so for any participant with same-day duplicate labs, **which value lands in `pheno_df` is arbitrary
and can change between runs.** (Building the fixture surfaced this: the first run yielded 132 where
the spec had assumed 130.)

The reproducible property is therefore "exactly one row survives, and its value is one of the
duplicates" — which is what the answer key asserts. If a deterministic LDL is wanted, the notebook
needs an explicit tie-break (e.g. `arrange(person_id, datetime, value_as_number)` or taking the mean
of same-day values) before `distinct()`. Flagging, not fixing, per `CLAUDE.md`.

### Derived columns to assert

- `CAD_code` ∈ {0, 1}; `CADFH_code` ∈ {TRUE, FALSE}; `any_chol_med` ∈ {0, 1}
- `CAD_age = year(CAD_code_date) - year(date_of_birth)`
- `Age_at_LDL_assessment = year(as.period(interval(date_of_birth, Date_LDL_assessment)))`
- `Age_at_HC = year(as.period(interval(date_of_birth, HC_code_date)))`
- `LDL_measured_on_meds` = 0 if `LDL_measurement_datetime <= any_chol_med_start_date`, 1 if `>`,
  **NA otherwise** (see A7)
- `any_chol_med_start_date = min(statin_start_date, nonstatin_start_date, survey_datetime, na.rm=TRUE)`

---

## 9. Suggested local runner (described, not prescribed)

### SQL engine

**DuckDB** is the recommended BigQuery stand-in: it reads/writes CSV and Parquet natively, runs
in-process from R via the `duckdb` package, and its SQL dialect is close enough to BigQuery's that the
generated queries need only small edits.

Expected dialect gaps between the generated SQL and DuckDB:

| BigQuery | DuckDB | Fix |
|---|---|---|
| `` `table` `` (backticks) | **Not accepted** — parser error | Replace `` ` `` with `"` before executing. This is the *only* translation the generated SQL needs (confirmed against all 13 queries) |
| `CONCAT('%.', a.id, '.%')` | Supported | none |
| `CAST(cr.id AS string)` | `STRING` aliases `VARCHAR` | none |
| `TIMESTAMP` semantics | Compatible | none |
| `bq_dataset_query()` / `bq_table_save()` | n/a | Shim: run the SQL, write sharded CSVs |

SQLite would also work but lacks `CONCAT` (needs `||`) and has weaker date handling — prefer DuckDB.

### Faking the GCS layer

`read_bq_export_from_workspace_bucket()` shells out to `gsutil ls` and `gsutil cat`. Two options:

1. **Shim the function** (cleanest): redefine it in a test-only setup cell to `list.files()` +
   `read_csv()` against a local directory, preserving the `bind_rows`-over-shards behavior and the
   `col_types` spec.
2. **Shim `gsutil` itself**: put a script named `gsutil` on `PATH` that implements `ls` and `cat`
   against a local directory. Higher fidelity (exercises the real code path unmodified), more setup.

Either way, mirror the real directory layout so paths in the notebook need no editing:

```
fixture/bucket/bq_exports/test@example.org/20240321/condition_99802609/condition_99802609_000000000000.csv
                                                                        condition_99802609_000000000001.csv
```

### Suggested repository layout

```
fixture/
  spec/            # this document's machine-readable companion (concept seeds, scenario table)
  build/           # generator scripts (to be written)
  db/aou_fixture.duckdb
  bucket/          # the fake GCS bucket, sharded CSVs
  expected/        # the §8 answer key as CSV, for assertion
```

---

## 10. Known divergences from the real CDR

State these plainly so nobody mistakes the fixture for a replica:

1. **Scale**: 300 persons vs. 413,457. Row-count ratios are approximated, not measured.
2. **Distributions are invented.** LDL/BMI/age distributions, disease prevalences, and medication
   rates are chosen to exercise code paths, not to resemble the cohort. Never estimate anything from
   this.
3. **`concept` is a stub.** The real vocabulary is ~7–8M rows across dozens of vocabularies; the
   fixture seeds only the few hundred concepts §5 requires. Any query touching an unseeded concept
   returns nothing.
4. **`cb_criteria` hierarchies are shallow.** Real paths are deep ICD/SNOMED trees; the fixture uses
   minimal 2–3 level paths sufficient to satisfy the `LIKE` predicates.
5. **`cb_search_all_events` is empty.** This notebook never reads it, but other All of Us code does —
   a query against the fixture that uses it will return nothing rather than erroring.
6. **`ds_survey` is a hand-built lossy view**, not the real derivation (which involves the `prep_pfhh_*`
   machinery for re-deriving Personal & Family Health History across survey versions).
7. **Date shifting is not applied by default** (see §6). Real CDR dates are shifted per participant.
8. **`cb_criteria_ancestor`'s column list is inferred** from the generated SQL, not from a published
   schema — confirm with `INFORMATION_SCHEMA.COLUMNS` in the Workbench before depending on it.
9. **Row counts per table in §6 are order-of-magnitude estimates.** The authoritative v7 Data
   Characterization Report is login-gated and was not consulted.

---

## 11. Status — the fixture is built

This spec has been implemented. See **`fixture/README.md`** for how to run it.

| | |
|---|---|
| Database | `fixture/db/aou_fixture.duckdb` — 301 `person` rows (300 participants + P26's duplicate), 191 in the srWGS cohort |
| Exports | `fixture/bucket/…/bq_exports/…/<date>/<name>/<name>_*.csv` — all 13, sharded |
| Answer key | `fixture/expected/answer_key.csv` — 27 scenarios |
| Generator | `fixture/build/generate.py` → `export.py` → `verify.py` |

The exports are produced by running the notebook's **own generated SQL**, extracted verbatim from
`LDLR Get phenotypes.ipynb` (`fixture/build/queries/*.sql`) — not by a paraphrase. All 13 queries
return rows against the fixture, which is what proves the `cb_criteria` seeding in §3 is correct.

`verify.py` replays the R cleaning pipeline and diffs it against the answer key. Current result:
**26 pass, 1 reproduced-bug, 0 unexpected failures.** The one "reproduced-bug" is P014 — the §7.3
`any_chol_med` defect, now **confirmed**: a participant who answered the survey *"No"* and takes no
medication comes out as `any_chol_med = 1`. It also cascades further than §7.3 predicted, flipping
`LDL_measured_on_meds` from `NA` to `1`, because their survey date becomes `any_chol_med_start_date`.

## Sources

- [All of Us Workbench CDR BigQuery schemas (`cb_*`, `ds_*`)](https://github.com/all-of-us/workbench/tree/main/api/db-cdr/generate-cdr/bq-schemas) — the `cb_*`/`ds_*` column lists above are verbatim from here
- [All of Us Curation OMOP schemas](https://github.com/all-of-us/curation/tree/develop/data_steward/resource_files/schemas)
- [OMOP CDM v5.3 specification](https://ohdsi.github.io/CommonDataModel/cdm53.html)
- [CDR v7 Release Notes](https://support.researchallofus.org/hc/en-us/articles/14769699298324-Curated-Data-Repository-CDR-version-7-Release-Notes)
- [Data Dictionaries](https://support.researchallofus.org/hc/en-us/articles/360033200232-Data-Dictionaries)
- [Participant Privacy Protections (date shifting)](https://support.researchallofus.org/hc/en-us/articles/4552681983764-Participant-Privacy-Protections)
- [Race and Ethnicity Data Collection and Transformation](https://support.researchallofus.org/hc/en-us/articles/360039299632-Race-and-Ethnicity-Data-Collection-and-Transformation)
- [The All of Us Research Program: data quality, utility, and diversity (Patterns, 2022)](https://www.cell.com/patterns/fulltext/S2666-3899(22)00181-7)
- [`allofus` R package paper (PMC11631081)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11631081/) — source for the `ds_survey` lossiness note
- [PMI: Skip usage analysis (PLOS ONE)](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0283601)

> `support.researchallofus.org` returns HTTP 403 to automated fetchers. Claims sourced from it above
> come from search-engine extracts, not full-page reads, and are marked where confidence is lower.
