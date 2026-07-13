# Synthetic All of Us CDR fixture

A dummy stand-in for the All of Us Controlled Tier CDR v7, built to the spec in
[`../FORMAT.md`](../FORMAT.md), so `LDLR Get phenotypes.ipynb` can be run and regression-tested
offline.

**Contains no real participant data.** Every value is invented. Nothing here is derived from the
controlled-tier CDR, and building or using it requires no Workbench access.

## What's here

```
fixture/
  build/
    extract_sql.py     pulls the 13 generated queries out of the notebook, verbatim
    queries/*.sql      those queries (regenerate; don't hand-edit)
    generate.py        builds the DuckDB database + the answer key
    export.py          runs the queries -> sharded CSV exports
    verify.py          replays the R cleaning pipeline, diffs vs the answer key
    gsutil             offline shim so the notebook's reader works unmodified
  db/aou_fixture.duckdb
  bucket/              the fake GCS bucket (sharded CSV exports)
  expected/answer_key.csv
```

## Build it

```bash
py -m pip install duckdb          # only dependency
py fixture/build/extract_sql.py   # only needed if the notebook's SQL changes
py fixture/build/generate.py
py fixture/build/export.py
py fixture/build/verify.py
```

`verify.py` exits non-zero on any unexpected mismatch, so it works as a CI check.

Expected output:

```
26 pass, 1 reproduced-bug (expected), 0 unexpected failure(s)
```

## Scale

300 participants (301 `person` rows — one is deliberately duplicated), 191 of them in the srWGS
cohort (`has_whole_genome_variant = 1`). The rest exist to prove the cohort gate actually filters.
Real CDR v7 has 413,457 participants and 245,394 with srWGS; the *ratios* are approximated, the
absolute numbers are not.

## The exports are produced by the notebook's own SQL

`export.py` does not paraphrase the queries — it runs the 13 SQL strings lifted verbatim out of the
notebook. If a query comes back empty, the fixture's `cb_criteria` seeding is wrong, and that is
precisely the silent failure mode `FORMAT.md` §3 warns about (a bad `path` or a missing
`[…_rank1]` token yields zero rows and no error). All 13 currently return rows.

The one dialect translation applied is `` ` `` → `"`, because DuckDB rejects backtick identifiers.

## Running the notebook against it

The notebook's `read_bq_export_from_workspace_bucket()` shells out to `gsutil ls` / `gsutil cat`.
Put the shim on `PATH` and it works with no edits to the notebook:

```bash
export PATH="$(pwd)/fixture/build:$PATH"
export FIXTURE_BUCKET_ROOT="$(pwd)/fixture/bucket"
```

The export directories mirror the real bucket layout and dates (`20240321`, `20240324`, `20241101`,
`20241104`), so the `gs://…` paths hardcoded in the "Format" cells resolve as-is.

Three exports are written as a **single** shard, not two, because their "Format" cells hardcode an
exact filename (`…_000000000000.csv`) rather than a `*.csv` glob — splitting those would strand half
the rows.

## What it's testing

Every defect in `FORMAT.md` §7 is present in the data, and every one has a named participant in
`expected/answer_key.csv`:

- **Handled today (D1–D7):** inconsistent `unit_source_value`, non-physiologic values, same-day
  duplicates, the LDL == Trig defect, participants with no EHR at all, `PMI: Skip` / `None Indicated`
  demographics, and a CAD code preceding the first visit.
- **Not handled (A1–A9):** lowercase `mg/dl` that silently drops a person's only LDL; censored lab
  values (`value_as_number` NULL, `value_source_value = '<10'`); a DOB after the events, producing
  negative ages; a duplicated `person` row that multiplies rows across the whole join; a NULL
  `person_id`; a cohort member with zero visits, which breaks censoring; `LDL_measured_on_meds`
  returning `NA` rather than `0`; cross-shard type inference; and a stray analyte that silently
  becomes "LDL".

## Two findings this fixture confirmed

**1. `any_chol_med` is wrong for survey non-users** (`FORMAT.md` §7.3). `meds_df` contains everyone
who *answered* the statin survey, including those who said "No" — `case_when` correctly gives them the
string `'no'`. But the collapse is `pheno_df2$any_chol_med[!is.na(...)] <- 1`, and `'no'` is not `NA`,
so they become **1**. Participant `1000014` demonstrates it. It cascades: their survey date becomes
`any_chol_med_start_date`, which flips `LDL_measured_on_meds` from `NA` to `1`.

**2. The same-day duplicate tie-break is not deterministic.** `distinct(person_id, .keep_all = TRUE)`
keeps whichever row comes first, and the generated SQL has no `ORDER BY`. For any participant with
same-day duplicate labs, the LDL that lands in `pheno_df` is arbitrary. The answer key therefore
asserts membership (`one_of:130|131|132`), not a fixed value.

Both are flagged, not fixed — per `CLAUDE.md`, the rough edges in this notebook are load-bearing
history.

## Regenerating

`generate.py` seeds `random.seed(20240321)`, so the filler cohort is stable across runs. The 27
scenario participants (`1000001`–`1000027`) are hand-authored and never randomised, so the answer key
stays valid when the filler is regenerated.
