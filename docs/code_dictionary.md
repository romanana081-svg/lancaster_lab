# Code dictionary — every code the pipeline pulls, and what it means

**Purpose.** So you (and your advisor) can *read the code and know exactly what it pulls*, and change
what needs changing. Every code the extractor and the outcome definition rely on is listed here with
its plain-English meaning, which CDR table/column it comes from, its role, and where to edit it.

**Two companions to this file:**
- `configs/prevent_concepts.yaml` and `configs/ascvd_codes.yaml` are the *machine-readable* source of
  truth for these codes — edit those to change what the pipeline matches.
- `src/phenotype/R/audit_codes.R` is the *live check*: run it in the Workbench and it resolves each
  code below to its **official All-of-Us concept name** and counts the people behind it, so you can
  confirm this table against the real data (and catch anything that drifted in CDR v8).

**How matching works.** We match on **codes** (LOINC / ICD10CM / CPT4 / RxNorm), never on bare
`concept_id`s — concept IDs change between CDR versions, codes don't. ICD10CM lives on
`condition_source_concept_id` and CPT4 on `procedure_source_concept_id` (the *source* columns; the
standard columns are SNOMED). Match by code **prefix** (e.g. `I21` catches `I21.0`, `I21.4`, …).

---

## 1. PREVENT model inputs — measurements (LOINC → `measurement`)

Unit expected in parentheses. eGFR is *derived* from creatinine, not pulled.

| Code | Stands for | Unit | Role | Edit in |
|---|---|---|---|---|
| `2093-3`  | Cholesterol [Mass/vol] in Serum/Plasma — **total cholesterol** | mg/dL | PREVENT `total_c` | `prevent_concepts.yaml` |
| `2085-9`  | Cholesterol in HDL [Mass/vol] — **HDL-C** | mg/dL | PREVENT `hdl_c` | `prevent_concepts.yaml` |
| `8480-6`  | **Systolic blood pressure** | mmHg | PREVENT `sbp` | `prevent_concepts.yaml` |
| `2160-0`  | Creatinine [Mass/vol] in Serum/Plasma | mg/dL | → **eGFR** (CKD-EPI 2021, race-free) | `prevent_concepts.yaml`, `egfr.R` |
| `39156-5` | **Body mass index (BMI)** [Ratio] | kg/m² | PREVENT `bmi` | `prevent_concepts.yaml` |
| `4548-4`  | Hemoglobin **A1c** / Hemoglobin.total in Blood | % | diabetes-by-HbA1c (extended) | `prevent_concepts.yaml` |
| `17856-6` | Hemoglobin A1c by **IFCC** protocol | % | HbA1c (alt code) | `prevent_concepts.yaml` |

> **Watch the units.** The extractor bounds each value physiologically, which also catches unit
> confusions (cholesterol in mmol/L is ~5 and falls below the mg/dL floor, so it's dropped rather than
> misread). Section 2 of the audit shows the real unit distribution per code.

## 2. Diabetes — diagnosis codes (ICD10CM → `condition_source_concept_id`)

| Prefix | Stands for | Edit in |
|---|---|---|
| `E08` | Diabetes mellitus due to underlying condition | `prevent_concepts.yaml` |
| `E09` | Drug- or chemical-induced diabetes mellitus | `prevent_concepts.yaml` |
| `E10` | **Type 1** diabetes mellitus | `prevent_concepts.yaml` |
| `E11` | **Type 2** diabetes mellitus | `prevent_concepts.yaml` |
| `E13` | Other specified diabetes mellitus | `prevent_concepts.yaml` |

> Diabetes has **three** possible definitions — diagnosis code (here), HbA1c ≥ 6.5%, or a
> glucose-lowering drug — and they identify **different people**. The pipeline uses the diagnosis code.
> This is a decision to confirm with your advisor.

## 3. ASCVD outcome — ACUTE events (ICD10CM → source). *What PREVENT actually predicts.*

A first-ever code here is a genuine **event date**.

| Prefix | Stands for |
|---|---|
| `I21` | **Acute myocardial infarction** (STEMI/NSTEMI) — the canonical hard endpoint |
| `I22` | Subsequent myocardial infarction |
| `I23` | Certain current complications following acute MI |
| `I24` | Other acute ischemic heart disease |
| `I63` | **Cerebral infarction** (ischemic stroke) — part of PREVENT's composite |

## 4. ASCVD outcome — CHRONIC / stable disease (ICD10CM → source). *Prevalent, not an event.*

A first code here is a **diagnosis** date, not necessarily an event date — these make someone
*prevalent* (excluded at baseline, D-013), they are **not** automatically incident events.

| Prefix | Stands for |
|---|---|
| `I25`   | Chronic ischemic heart disease |
| `I20`   | Angina pectoris |
| `I70`   | Atherosclerosis |
| `I73`   | Other peripheral vascular disease |
| `Z95.1` | Presence of aortocoronary bypass graft (history) |
| `Z95.5` | Presence of coronary angioplasty implant/graft (history) |

## 5. ASCVD outcome — REVASCULARISATION (CPT4 → `procedure_source_concept_id`)

**Read before using:** a revascularisation is a *treatment decision*, not purely a disease event
(confounded by healthcare access). The primary analysis is reported **with and without** it.

| Code | Stands for | Note |
|---|---|---|
| `929…` | Percutaneous coronary intervention (PCI) — angioplasty, stent | intended 92920–92944; `929%` is a **broad** match — review the exact range with your advisor |
| `33510` | Coronary artery bypass, **venous** graft (CABG) | representative code; full CABG-vein range is 33510–33516 |
| `33533` | Coronary artery bypass, **arterial** graft (CABG) | representative code; full CABG-arterial range is 33533–33536 |

## 6. Deliberately EXCLUDED (look cardiac, are not atherosclerotic — do not add without a decision)

| Prefix | Why excluded |
|---|---|
| `I60` | Subarachnoid haemorrhage — haemorrhagic, not atherosclerotic |
| `I61` | Intracerebral haemorrhage — haemorrhagic, not atherosclerotic |
| `I26` | Pulmonary embolism — thrombotic but not atherosclerotic |
| `I50` | Heart failure — in PREVENT's *broader* CVD composite but **not** hard ASCVD |

## 7. Medications (RxNorm → `drug_exposure`)

| Input | How matched | Status |
|---|---|---|
| **Statins** (PREVENT `statin`) | RxNorm ingredients (atorvastatin, simvastatin, rosuvastatin, pravastatin, fluvastatin, lovastatin, cerivastatin, pitavastatin), matched via `concept_ancestor` | ✅ **Fixed 2026-07-20**: was a direct concept_id match, which the audit showed found only 27,320 of 143,905 real statin users (~80% missed, because CDR drug rows are clinical drugs not ingredients). Now uses the `concept_ancestor` rollup. |
| **Antihypertensives** (PREVENT `bp_tx`) | — | 🚧 **PLACEHOLDER (FALSE for everyone)**. The ingredient list is deliberately not written (`prevent_concepts.yaml: NEEDS_A_CODE_LIST`) — do not improvise it; pull from the drug hierarchy with your advisor. |

## 8. Survey (`ds_survey` / `observation`)

| Input | Status |
|---|---|
| **Current smoking** (PREVENT `smoking`) | 🚧 **PLACEHOLDER (FALSE for everyone)**. Survey mapping open (`prevent_concepts.yaml: NEEDS_MAPPING`). |

## 9. Demographics & cohort gates (`cb_search_person`)

| Column | Stands for | Role |
|---|---|---|
| `age_at_cdr` | Age at the CDR cutoff (CDR-computed) | PREVENT `age`; the 30–79 gate |
| `sex_at_birth` | Sex at birth (`"male"`/`"female"`) | PREVENT `sex` (→ 0/1) |
| `has_ehr_data` | Has EHR data | cohort gate (PREVENT needs EHR measurements) |
| `has_whole_genome_variant` | Has short-read WGS | **not used this week** — added for the genetic cohort next week (D-013). In this workspace's v8 CDR it is 0 for everyone (H-005). |

---

## How to change a code (the common case)

1. Edit the code in the config: `configs/prevent_concepts.yaml` (inputs) or `configs/ascvd_codes.yaml`
   (outcome). These are written to be read and reviewed.
2. If it's a measurement/diabetes/statin code the SQL lists explicitly, update the matching `IN (...)`
   / `LIKE` in `sql/02_prevent_panel_completeness.sql`, `src/phenotype/R/extract_prevent.R`, and
   `src/phenotype/R/audit_codes.R`.
3. Re-run the offline tests (`Rscript -e "testthat::test_dir('tests/testthat')"`) — they check the
   fixture still matches.
4. Re-run `audit_codes()` in the Workbench to confirm the new code resolves and pulls sensible data.

**To get the live All-of-Us concept names + counts for everything above**, run in the Workbench:

```r
source("src/phenotype/R/run_sql.R"); source("src/phenotype/R/audit_codes.R")
con <- connect_cdr(); audit_codes(con); DBI::dbDisconnect(con)
```

Paste the output back and it can be folded in beside each code here (H-006: the code/name tables are
safe to export; the counts need small-cell suppression first).
