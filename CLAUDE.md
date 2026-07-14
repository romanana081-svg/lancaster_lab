# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single **R** Jupyter notebook (`LDLR Get phenotypes.ipynb`, kernel `ir`) that builds a phenotype
matrix for an LDLR (familial hypercholesterolemia / CAD) genetics study out of the
**All of Us Researcher Workbench**, Controlled Tier Dataset v7.

The cohort is All of Us participants with short-read WGS — every generated query filters on
`has_whole_genome_variant = 1` in `cb_search_person`. One row per `person_id`.

The notebook is **not runnable outside the All of Us Workbench**. It depends on:

- Environment variables injected by the Workbench: `WORKSPACE_CDR` (the BigQuery CDR dataset),
  `WORKSPACE_BUCKET` (the workspace's GCS bucket), `GOOGLE_PROJECT` (BigQuery billing project),
  `OWNER_EMAIL`.
- `gsutil` on PATH and authenticated Google credentials.
- R packages `tidyverse` and `bigrquery` (plus `lubridate`, used via `tidyverse`).

There is no build, no test suite, and no lint config. Local work is limited to reading and editing
the notebook; execution happens in the Workbench.

## Notebook architecture

Each top-level section (`# Get MI and ischemic heart disease codes`, `# Get PAD codes`,
`# Get FH codes`, `# Get CAD family history`, `# Get hypercholesterolemia codes`,
`# Get medication history`, `# Get lab data`, `# Get demographics`, `# Get BMI`) follows the same
two-phase shape:

1. **"Do once (done)"** — a cell pasted from the All of Us Cohort/Dataset Builder. It holds a long
   auto-generated SQL string with **hardcoded OMOP concept IDs**, then calls
   `bq_table_save(bq_dataset_query(...), <domain>_<id>_path, destination_format = "CSV")` to export
   sharded CSVs to `gs://<WORKSPACE_BUCKET>/bq_exports/<OWNER_EMAIL>/<YYYYMMDD>/<name>/`.
   These cells are **already run** — do not re-run them casually; they cost BigQuery time and write a
   new dated export directory.
2. **"Format ..."** — hardcodes the `gs://` path of a *previously produced* export (dated
   `20240321`, `20240324`, `20241101`, or `20241104` depending on section), reads it via
   `read_bq_export_from_workspace_bucket()` (defined in `# Setup`; it shells out to
   `gsutil ls`/`gsutil cat` and `bind_rows` the shards), then cleans it.

Because the export paths are pinned to specific dates, editing a "Do once" query without also
updating the corresponding path literal in the "Format" cell will silently keep using the old data.

Section headers are annotated with status (`- DONE`, `- IN PROGRESS`) — treat these as the source of
truth for what has been validated.

### The per-domain cleaning idiom

Nearly every "Format" section repeats the same pipeline, and new domains should match it:

```r
df$<datetime_col> <- as.Date(df$<datetime_col>)                       # 1. coerce to Date
df <- df %>% filter(unit_source_value == 'mg/dL')                     # 2. keep one consistent unit
df <- df %>% filter(value_as_number > 1 & value_as_number < 1000)     # 3. drop non-physiologic values
df <- df %>% group_by(person_id) %>%                                  # 4. keep each person's EARLIEST record
             filter(<datetime_col> == min(<datetime_col>))
df <- distinct(df, person_id, .keep_all = TRUE)                       # 5. break remaining ties -> 1 row/person
df <- select(df, person_id, ...); colnames(df) <- c(...)              # 6. slim + rename
```

Step 4 alone does **not** guarantee one row per person (same-day duplicates survive), which is why
step 5 always follows it. Units must be inspected with `group_by(unit_source_value) %>% summarize(n=n())`
before filtering — All of Us unit strings are inconsistent and differ per measurement.

Physiologic bounds currently in use: triglycerides and LDL `>1 & <1000 mg/dL` (LDL further narrowed to
`<400`), BMI `>14 & <60 kg/m2`.

### Data flow

Per-domain frames, all keyed on `person_id`:

| Frame | Contents |
|---|---|
| `demo_df` | `date_of_birth`, `race`, `sex_at_birth` (the left-most table in the join) |
| `ldl_df` / `trig_df` | earliest LDL / triglyceride value + date, split out of `labs_df` by `measurement_concept_id` (trig = `3022192`) |
| `codes_df` | earliest CAD event — ICD conditions (`icd_df`) and CPT procedures (`CPT_df`) `rbind`-ed, then re-reduced to the earliest per person |
| `PAD_df`, `FH_df`, `CADFH_df`, `hc_df` | peripheral artery disease, familial hypercholesterolemia, CAD family history, hypercholesterolemia codes |
| `meds_df` | `statin_df` + `nonstatin_df` + survey `ans`, folded into `any_chol_med` / `any_chol_med_start_date` |
| `BMI_df` | earliest BMI |

These are `left_join`-ed onto `demo_df` into `pheno_df`, reshaped/renamed into `pheno_df2` (where
`CAD_code`, `any_chol_med`, `CADFH_code` are collapsed to 1/0 or TRUE/FALSE and ages are derived from
`date_of_birth`), and finally joined with the censored-date frame into `pheno_df3`.

Outputs land in `gs://<WORKSPACE_BUCKET>/data/`:
`LDLR_phenotypes.csv` → `LDLR_phenotypes_formatted.csv` → `LDLR_phenotypes_formatted_censored_ages.csv`
(the last is the final product).

### Save/restore checkpoints

The notebook repeatedly checkpoints to GCS rather than holding everything in memory:

```r
write_excel_csv(my_dataframe, destination_filename)
system(paste0("gsutil cp ./", destination_filename, " ", Sys.getenv('WORKSPACE_BUCKET'), "/data/"), intern = TRUE)
```

and reloads with the mirror-image `gsutil cp` + `read_csv`. Note this means a variable can be
restored from a CSV in a *later* cell, so **the notebook does not execute cleanly top-to-bottom** —
some cells depend on state produced further down (e.g. the censoring section's `codes_df <- pheno_df2[...]`
at cell ~234 reads `pheno_df2`, which is only built at cell ~300). Keep this in mind before
"fixing" an apparent undefined-variable error.

## Known rough edges

Do not silently clean these up — they are load-bearing history, but flag them if touching nearby code:

- **`# Get censored ages` is IN PROGRESS.** It classifies each person into `type` 1/2/3 (no CAD code /
  CAD code precedes first visit / CAD code after first visit) to pick a `CAD_censored_date`, and is
  followed by a `## Scratch` section of commented-out dead ends.
- **LDL == Trig data defect.** Some source rows have LDL equal to triglycerides; the `### Troubleshooting`
  cells diagnose this via `diff = LDL - Trig` and drop `diff == 0` rows. This filter is applied in the
  troubleshooting scratch frame (`ldl_trig`), *not* to `ldl_df`/`trig_df` used in the main join.
- Cell ~291 contains a typo — `Sys.getenv('WORKSPACE_BUCKET')b` — in one of the save blocks.
- ~~The notebook is committed **with outputs**, which is why it is ~180 KB.~~ **Corrected 2026-07-14
  (T-012): this is false.** The notebook has **no outputs** — all 291 code cells have `outputs: []` and
  `execution_count: null`, in the working tree and in every historical commit. It is ~180 KB because it
  is ~101 KB of *source*: the auto-generated All of Us SQL strings run to ~6 KB per cell. Diffs are
  still noisy for that reason, so when reviewing, compare cell `source` rather than the raw JSON.
- The notebook **does** hardcode the workspace bucket UUID and the owner's email in 13 cells
  (`gs://fc-secure-…/bq_exports/megan.lancaster@researchallofus.org/…`), and `fixture/bucket/` mirrors
  those literals as tracked directory names. Not participant data; still unresolved — see A-014, Q-R3.
  **Do not "fix" this unilaterally:** the fixture is built to mirror those exact paths so the notebook
  runs unmodified offline, so notebook, fixture, and answer key must change together.
