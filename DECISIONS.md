# DECISIONS.md

An append-only log of every significant decision. **Never delete an entry.** If a decision is
reversed, add a new entry that supersedes it and mark the old one `SUPERSEDED BY D-0xx`.

Why this file exists: in six months, "why is the ETL in R when the rest is Python?" will be a real
question, and the answer must not depend on anyone's memory.

**Entry template**

```
## D-0NN — <short title>
- Status: PROPOSED | ACCEPTED | SUPERSEDED BY D-0xx | REVERSED
- Date:
- Context:            what forced a choice
- Alternatives:       what else was on the table, and their costs
- Reasoning:          why the winner won
- Decision:           the actual commitment, stated unambiguously
- Expected impact:    what this makes easier, and what it makes harder
- Links:              files, functions, tasks, questions
```

---

## D-001 — Project documentation is committed to git, not gitignored

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** The initial instruction was to create the ten project documents *and add them to
  `.gitignore`*. That instruction conflicts with the same brief's other requirements: "maintain
  complete project memory through documentation", "every decision should be traceable", and
  `loop.md`'s own "commit changes" step. A gitignored file has no history, no backup, cannot be
  reviewed, cannot be shared with an advisor, and dies with the laptop.
- **Alternatives:**
  1. *Gitignore all ten as literally requested.* Keeps the remote tidy. Destroys project memory,
     traceability, and collaboration. The autonomous loop could not commit its own state.
  2. *Split — commit the scientific docs, ignore the agent-workflow ones (`TASKS`, `JOURNAL`,
     `handoff`, `loop`).* Defensible, but `JOURNAL.md` and `TASKS.md` are exactly the files whose
     *history* is most valuable ("when did we decide to drop that gene set?").
  3. *Commit all ten.*
- **Reasoning:** The instruction was raised with the user as an internal contradiction rather than
  guessed at. The user confirmed alternative 3. Documentation that cannot be version-controlled is
  not project memory; it is a scratch pad.
- **Decision:** All ten documents are tracked in git and committed. The root `.gitignore` is
  rewritten and **itself tracked** (it previously contained the line `.gitignore`, so it ignored
  itself and never reached a clean clone).
- **Expected impact:** Full history of scientific reasoning. Advisor can review by reading the repo.
  Cost: the repo root has ten markdown files in it, which some people find noisy.
- **Links:** `.gitignore`; all root `*.md`.

---

## D-002 — Bilingual stack: R for phenotyping ETL, Python for modelling and statistics

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** The project brief says "prefer modular Python packages over notebooks; production
  logic belongs in `src/`". But the one asset that already exists and works is
  `LDLR Get phenotypes.ipynb` — an R/tidyverse phenotyping pipeline with non-obvious, hard-won
  cleaning logic (unit harmonisation, physiologic bounds, earliest-record-wins, tie-breaking,
  censoring types), already validated end-to-end against a synthetic CDR.
- **Alternatives:**
  1. *Port everything to Python.* Architecturally clean, single toolchain, one test framework.
     But it means rewriting validated epidemiological logic — in a language the author is still
     learning — with no scientific payoff, and every transcription error becomes a silent data bug.
  2. *Keep R, wrap it in a tested package; do everything else in Python.*
  3. *Everything in R.* PREVENT's reference implementation and the best survival/calibration/
     decision-curve tooling are Python; this would trade one rewrite for another.
- **Reasoning:** The user chose alternative 2 with the trade-off stated explicitly. The deciding
  argument: rewriting working cleaning code is *pure downside risk*. The riskiest bugs in this kind
  of project are silent data-cleaning bugs, and the fixture already proves the R version's behaviour.
- **Decision:** Phenotyping ETL stays R/tidyverse, refactored out of the notebook into an R package
  at `src/phenotype/` with `testthat` tests. PREVENT, genetic features, statistics, and figures are
  Python in `src/aou_ascvd/`. **This explicitly overrides the "src/ is Python" rule in the brief.**
- **Expected impact:**
  - *Easier:* keeps validated logic; matches the All of Us Workbench's R-first idiom; no risky rewrite.
  - *Harder:* two toolchains, two dependency systems, two test runners; a serialization boundary
    (see D-005); contributors need both languages. **And R is not currently installed on the
    development machine** — nothing R-based can be tested locally until it is (`handoff.md` H-001).
- **Links:** `src/phenotype/`, `src/aou_ascvd/`, `LDLR Get phenotypes.ipynb`, D-005, T-005, H-001.
- **Correction (2026-07-13):** the claim above that *"R is not currently installed on the development
  machine"* was **wrong**. R 4.6.0 and 4.3.2 are both installed, **with `tidyverse`** — R was merely
  absent from `PATH`. (`bigrquery` genuinely is missing, but it is only needed by the "Do once" cells,
  which run inside the Workbench anyway.) The decision is unchanged and this entry is not rewritten —
  but the cost recorded against it was overstated: **the R half is testable locally today**, which is
  what T-005 depends on. H-001 is closed. See `docs/environment.md`.

---

## D-003 — The synthetic DuckDB fixture is the offline test substrate

- **Status:** ACCEPTED
- **Date:** 2026-07-12 (predates this log; recorded retroactively)
- **Context:** The notebook only runs inside the All of Us Workbench against controlled-tier
  BigQuery. Nothing could be tested on a laptop, so every change had to be validated by hand in the
  cloud, against real data, with no regression safety net.
- **Alternatives:**
  1. *Mock the data frames directly in tests.* Fast, but tests nothing about the SQL, and the SQL is
     where the subtle failures live (a wrong `cb_criteria.path` returns zero rows **with no error**).
  2. *SQLite.* Weaker SQL dialect coverage; no `EXCLUDE`, weaker window functions.
  3. *DuckDB fixture replicating OMOP CDM v5.3 + the All of Us `cb_*` tables, deliberately seeded
     with dirty and missing data, plus a ground-truth answer key.*
- **Reasoning:** Only alternative 3 exercises the *actual* generated SQL. The exporter runs the 13
  queries lifted verbatim from the notebook; if the vocabulary seeding is wrong, they return no rows
  and the build fails loudly instead of silently.
- **Decision:** `fixture/` is the offline substrate. Spec in `FORMAT.md`. `fixture/build/verify.py`
  is a regression check and must stay green (`26 pass, 1 reproduced-bug, 0 unexpected failures`).
- **Expected impact:** ETL is testable on a laptop; regressions are caught in seconds. Cost: the
  fixture must be extended whenever a new OMOP domain is added (T-004), or it silently stops covering
  the pipeline.
- **Links:** `FORMAT.md`, `fixture/README.md`, `fixture/build/verify.py`, T-004.

---

## D-004 — AHA PREVENT is the baseline clinical model

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** "Beyond the state of the art" requires naming the state of the art.
- **Alternatives:**
  1. *Pooled Cohort Equations (PCE, 2013).* The previous standard. Known to overestimate risk;
     includes race as a biological input, which is now widely rejected. Beating PCE in 2026 is a
     weak claim.
  2. *SCORE2 (Europe).* Not the US standard; not calibrated for a US population.
  3. *QRISK3 (UK).* UK-specific; requires predictors All of Us does not reliably capture.
  4. *PREVENT (Khan et al., Circulation 2024).* Current AHA recommendation; race-free; includes
     kidney function and BMI; provides both 10-year and 30-year risk.
- **Reasoning:** PREVENT is what a US clinician is being told to use *now*. Demonstrating incremental
  value over a superseded model would not be persuasive. PREVENT's inclusion of eGFR also makes it a
  harder, fairer baseline.
- **Decision:** PREVENT is the baseline. Its linear predictor is the offset in the primary model
  (D-006). Secondary comparison against PCE is optional and is *not* on the critical path.
- **Expected impact:** Sets the required phenotype variables: total cholesterol, HDL-C, systolic BP,
  antihypertensive use, diabetes, current smoking, eGFR, BMI, age, sex. **None of these except BMI
  are extracted by the current pipeline** — this is the single largest implementation gap (T-003).
- **Links:** T-003, T-006, `src/aou_ascvd/prevent/`, H-002.

---

## D-005 — The R→Python boundary is one versioned, schema-validated Parquet file

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** D-002 creates two halves that must exchange data. Left informal, this boundary becomes
  the place bugs hide: a column silently renamed, units changed from mg/dL to mmol/L, an integer
  becoming a string.
- **Alternatives:**
  1. *CSV.* Universal, but has no types — everything round-trips through strings, dates become
     ambiguous, and `NA` vs `""` vs `NULL` becomes a source of real bugs.
  2. *Call R from Python (`rpy2`).* Couples the two halves tightly; fragile; hard to test either
     side alone.
  3. *A versioned Parquet file with an explicit JSON schema, validated on write (R) and on read
     (Python).*
- **Reasoning:** Parquet preserves types. An explicit schema turns a whole class of silent data bugs
  into loud failures. A single narrow contract means either half can be rewritten independently —
  including, later, replacing the R half with Python, without touching anything downstream.
- **Decision:** The contract is `phenotypes_v<N>.parquet` + `configs/phenotype_schema.json`.
  Validation on both sides is **mandatory and fails hard**. Output files are **immutable**: a new
  version never overwrites an old one, so prior analyses stay reproducible.
- **Expected impact:** Prevents unit and type drift across the language boundary. Cost: the schema
  must be updated whenever a phenotype is added, and both sides must be kept in step.
- **Links:** `configs/phenotype_schema.json`, `src/aou_ascvd/io/`, D-002, VALIDATION.md §3.

---

## D-006 — Incremental value is tested with the PREVENT linear predictor as a fixed offset

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** The research question is "do rare variants add value **beyond** PREVENT?" The naive
  approach — fit a model with genetics plus all the PREVENT variables, compare its C-index to
  PREVENT's — silently *refits* the clinical coefficients, so it answers a different question:
  "is a newly-fitted model better?" That conflates adding information with re-estimating the
  baseline, and it flatters the new variable.
- **Alternatives:**
  1. *Refit everything, compare C-statistics.* Standard practice in weak papers; answers the wrong
     question.
  2. *Two-stage: regress the outcome on PREVENT risk, take residuals, correlate with genetics.*
     Intuitive, but residual-based two-stage methods have the wrong null distribution under
     censoring, so the p-values are not trustworthy.
  3. *Fixed offset:* `h(t) = h₀(t)·exp(offset(LP) + γ·G)`, test `γ = 0`.
- **Reasoning:** The offset holds PREVENT exactly as published — coefficient fixed at 1, nothing
  re-estimated — and asks whether genetics explains what is *left over*. That is a literal
  formalisation of "residual risk", and it gives a valid likelihood-ratio / score test for `γ`.
- **Decision:** Primary model is **M1** in DESIGN.md §6.1: PREVENT LP as an offset, genetic burden as
  the only estimated term. Primary hypothesis test is on `γ`.
- **Expected impact:** Makes a **negative result interpretable and publishable** — "γ is
  indistinguishable from zero" is a clean statement. Requires PREVENT to be validated in All of Us
  *first* (DESIGN.md §5, stage 5): if PREVENT is badly miscalibrated here, the genetic term can
  absorb that miscalibration and produce a false positive. That risk is the reason stage 5 is
  mandatory and not optional.
- **Links:** DESIGN.md §1.3, §6; `src/aou_ascvd/stats/`; T-009; Q-S2.

---

## D-007 — Discrimination, calibration, and clinical utility are all reported; NRI is not a primary endpoint

- **Status:** ACCEPTED
- **Date:** 2026-07-13
- **Context:** "Improves prediction" has at least three meanings, routinely conflated.
- **Alternatives:** report ΔC-index alone (the common default); report NRI as headline; report all
  three domains.
- **Reasoning:** ΔC-index is famously insensitive — a genuinely useful predictor may move it by
  0.005 — so relying on it alone risks a false negative. NRI, conversely, is **biased toward
  declaring improvement** and is sensitive to arbitrary risk-category cut-points; using it as the
  headline risks a false positive. Decision-curve analysis answers the question a clinician actually
  has ("would acting on this model help?").
- **Decision:** Report **discrimination** (Harrell's C, time-dependent AUC), **calibration**
  (slope, intercept, ICI, decile plots), and **clinical utility** (decision-curve analysis / net
  benefit). NRI is reported for reviewers, explicitly labelled as secondary, with its cut-points
  pre-specified.
- **Expected impact:** Harder to over-claim; harder to under-claim. Cost: more analysis, more figures.
- **Links:** DESIGN.md §6.2, `src/aou_ascvd/stats/`, Q-S3.

---

## D-008 — Rare-variant burden is aggregated at the gene level, not tested variant-by-variant

- **Status:** PROPOSED *(not yet confirmed — see Q-G1, Q-G2)*
- **Date:** 2026-07-13
- **Context:** Individually, rare variants are too rare to have power: a variant carried by 3 people
  in 245,000 cannot support a per-variant test.
- **Alternatives:** single-variant association (no power); **burden test** (assumes all variants in a
  gene act in the same direction); **SKAT** (allows mixed directions, loses power when they don't);
  **SKAT-O** (adaptively combines the two).
- **Reasoning:** Aggregation across variants within a gene is the standard solution to the power
  problem. SKAT-O is the usual default because it does not require guessing in advance whether a
  gene's variants act in one direction.
- **Decision (provisional):** Aggregate to gene level. Use SKAT-O for discovery; use a directional
  burden score as the `G` term in the offset model (D-006), because M1 needs a single scalar per
  person. **Open:** the MAF threshold, the functional mask, and whether the gene set is
  pre-specified or exome-wide (Q-G1, Q-G2). These must be frozen *before* outcomes are examined.
- **Expected impact:** Determines power, multiple-testing burden, and whether the study is
  confirmatory or discovery.
- **Links:** DESIGN.md §5, §6.3; T-008; Q-G1; Q-G2.
