# lancaster_lab — rare variants and residual ASCVD risk

**Do low-frequency and rare genetic variants improve prediction of atherosclerotic cardiovascular
disease beyond the AHA PREVENT equations?**

Not "do rare variants cause heart disease" — they do. The question is the harder, more useful one:
**once a clinician already has PREVENT, does genetics add anything they did not already have?** A
credible *negative* answer is a real result, and this project is built so that one could be reported
honestly.

Data: **All of Us** Controlled Tier, CDR v7, restricted to participants with short-read WGS.
All real-data computation happens **inside the All of Us Researcher Workbench**.
**No real participant data ever enters this repository** (DESIGN §8).

---

## Start here

| If you want to… | Read |
|---|---|
| Understand the project | **[DESIGN.md](DESIGN.md)** ← the single source of truth |
| Know why something is the way it is | [DECISIONS.md](DECISIONS.md) |
| Know what we are taking on faith | [ASSUMPTIONS.md](ASSUMPTIONS.md) |
| Know what is still genuinely unknown | [QUESTIONS.md](QUESTIONS.md) |
| Do some work | [TASKS.md](TASKS.md), then [loop.md](loop.md) |
| Know how we prove any of it | [VALIDATION.md](VALIDATION.md) |
| Look up a term | [GLOSSARY.md](GLOSSARY.md) — written for a newcomer, not an expert |
| See what happened so far | [JOURNAL.md](JOURNAL.md) |
| Unblock the project (human!) | [handoff.md](handoff.md) |

## Status

**Scaffold.** Documentation, directory structure, config, and an offline test harness exist. The
analysis does not — there is no PREVENT implementation and no genetic pipeline yet.

What *does* work today is the **synthetic CDR fixture**: a DuckDB stand-in for the All of Us OMOP CDR
that runs the existing notebook's 13 SQL queries **verbatim**, so the phenotyping ETL can be tested on
a laptop. It is green, and it has already earned its keep by catching two real bugs in the existing
pipeline ([VALIDATION.md](VALIDATION.md) §2).

```powershell
$env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python313;$env:PATH"   # see docs/environment.md
python fixture/build/generate.py
python fixture/build/export.py
python fixture/build/verify.py
# -> 26 pass, 1 reproduced-bug (expected), 0 unexpected failure(s)
```

Neither Python nor R is on `PATH` on this machine even though both are installed —
[docs/environment.md](docs/environment.md) has the working invocations.

## The two things most in need of a human

1. **[H-006]** The notebook is committed **with cell outputs produced against real controlled-tier
   data**, and nobody has read them yet. Until someone does, this repository must be treated as
   private. (A-012, T-012 — the audit itself needs no permissions and is queued as P0.)
2. **[H-003]** Two study-design choices — the **outcome definition** (Q-A1) and the **index date**
   (Q-S1) — are open, and no test can catch getting them wrong. They block cohort construction and
   therefore everything downstream.

## Layout

```
DESIGN · DECISIONS · ASSUMPTIONS · VALIDATION · TASKS · QUESTIONS · JOURNAL · handoff · loop · GLOSSARY
configs/    all parameters — no hard-coded thresholds or concept IDs in code
sql/        BigQuery / DuckDB queries, one per domain
src/        production logic only:  aou_ascvd/ (Python)  ·  phenotype/ (R)
tests/      pytest + testthat
fixture/    synthetic All of Us CDR — the offline test substrate (spec: FORMAT.md)
notebooks/  exploratory only; never a dependency of src/
reports/    generated outputs
data/       entirely gitignored. real data never lands here.
```

Why two languages? The phenotyping ETL is validated R and rewriting it would be pure downside risk;
everything else is Python. The two halves meet at exactly one artifact — a versioned, schema-validated
Parquet file — and nowhere else. See **D-002** and **D-005**.
