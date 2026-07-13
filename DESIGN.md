# DESIGN.md

The single source of truth for *what this project is and how it is built*.
If you read only one file, read this one. Terms in **bold-italic** on first use are defined in
[`GLOSSARY.md`](GLOSSARY.md).

- **Status:** scaffold (v0.1.0). No analysis code exists yet.
- **Last updated:** 2026-07-13
- **Related:** [`DECISIONS.md`](DECISIONS.md) · [`ASSUMPTIONS.md`](ASSUMPTIONS.md) · [`VALIDATION.md`](VALIDATION.md) · [`TASKS.md`](TASKS.md)

---

## 1. Scientific overview

### 1.1 The question

> **Do low-frequency and rare genetic variants improve prediction of atherosclerotic cardiovascular
> disease (_**ASCVD**_) beyond the current state-of-the-art clinical prediction model?**

The state-of-the-art baseline is the American Heart Association ***PREVENT*** equations
(Khan SS et al., *Circulation* 2024), which predict 10- and 30-year risk of cardiovascular disease
from routinely available clinical variables.

Framed as a *residual risk* question:

> After we have accounted for everything PREVENT already knows about a person, is there **remaining,
> unexplained risk** that low-frequency variants can explain?

### 1.2 Why this is a meaningful question

Clinical risk models are built from common, cheap, measurable things: age, blood pressure,
cholesterol, diabetes, smoking, kidney function. They perform reasonably well *on average* but
misclassify individuals. Two people with identical PREVENT inputs can have very different outcomes.
Some of that gap is noise; some of it is biology the model cannot see.

Rare and low-frequency coding variants are a plausible source of that unseen biology, because they
can have **large effect sizes** — much larger than the individual common variants that make up a
***polygenic risk score (PRS)***. Familial hypercholesterolemia is the canonical example: a single
loss-of-function variant in `LDLR`, `APOB`, or `PCSK9` can raise lifetime ASCVD risk severalfold,
and such a person may still look unremarkable to a clinical risk calculator at age 40.

The scientific novelty is *not* "do rare variants cause CAD" — they do. It is: **once you already
have PREVENT, do they add anything you did not already have?** That is a strictly harder and more
clinically useful bar, and it is the bar this project is built to test.

### 1.3 The critical methodological idea

You cannot answer "does X add value beyond model M?" by fitting a new model with X in it and
comparing C-statistics. That conflates *adding a variable* with *refitting all the other
coefficients*. The correct construction is:

> Fit a survival model in which **the PREVENT linear predictor is an *offset*** — a term with its
> coefficient fixed at 1, not estimated — and then test whether a genetic term added to that model
> is significantly non-zero.

An ***offset*** says: "take PREVENT's prediction as given, on the log-hazard scale, and tell me
whether genetics explains anything about what is *left over*." If the genetic coefficient is
indistinguishable from zero, low-frequency variants add nothing beyond PREVENT, and that is a
publishable negative result. This design is recorded as **D-006** in [`DECISIONS.md`](DECISIONS.md).

### 1.4 Data source

The ***All of Us*** Research Program, **Controlled Tier, Curated Data Repository (_**CDR**_) v7**.
Analysis is restricted to participants with **short-read whole genome sequencing (_**srWGS**_)** —
approximately 245,000 people in v7 — because rare-variant analysis requires sequence, not array, data.

All computation on real data happens **inside the All of Us Researcher Workbench**. Nothing in this
repository contains, or may ever contain, real participant-level data (see §8).

---

## 2. Target population, exposure, outcome

These three definitions determine everything downstream, and **two of the three are not yet settled**
(see [`QUESTIONS.md`](QUESTIONS.md) and [`handoff.md`](handoff.md) H-003).

| | Working definition | Status |
|---|---|---|
| **Population** | All of Us participants with srWGS, aged 30–79 at index date, **without ASCVD before the index date** (PREVENT is a *primary prevention* model) | Proposed |
| **Index date (time zero)** | The date of the first assessment at which all PREVENT inputs are available | **Open — Q-S1** |
| **Exposure** | Aggregated burden of low-frequency / rare variants (see §5) | Proposed |
| **Outcome** | ***Incident*** ASCVD: non-fatal myocardial infarction, coronary heart disease death, fatal or non-fatal stroke | **Open — Q-A1, needs advisor** |
| **Censoring** | Last known EHR contact, death from a non-ASCVD cause (a ***competing risk***), or administrative end of follow-up | Proposed |

Two traps are worth naming now because they invalidate studies:

- ***Prevalent vs. incident disease.*** A person who already had a heart attack before we start the
  clock cannot "develop" ASCVD during follow-up; including them inflates apparent prediction
  accuracy. PREVENT is only defined for people without prior CVD. The existing notebook's
  `# Get censored ages` section — currently marked IN PROGRESS — is precisely the machinery needed
  to separate these groups, which is why it is load-bearing rather than scratch work.
- ***Immortal time bias.*** If the index date is chosen *after* looking at follow-up data (e.g. "the
  first visit where we have a cholesterol value" — but that visit only exists because the person
  survived to it), you build survival into the design. Q-S1 exists to force an explicit answer.

---

## 3. Software architecture

### 3.1 The bilingual split, and why

This project is deliberately **two languages** (decision **D-002**):

| Layer | Language | Why |
|---|---|---|
| **Phenotyping ETL** — pull OMOP domains out of BigQuery, clean them, produce one row per person | **R / tidyverse** | An extensively validated R implementation already exists (`LDLR Get phenotypes.ipynb`), the All of Us Workbench is R-first for this kind of work, and rewriting working, reviewed cleaning logic is pure risk with no scientific payoff. |
| **PREVENT, genetics, statistics, figures** | **Python** | The PREVENT reference implementation is Python; survival analysis, calibration, and decision-curve tooling are mature here; and the user wants to learn Python. |

**The cost of this decision is real and is recorded, not hidden:** two toolchains, two test
frameworks (`testthat` and `pytest`), two dependency systems, and a serialization boundary in the
middle. It is accepted because the alternative — rewriting validated epidemiological cleaning code
in a language the author is still learning — is the more dangerous of the two options.

### 3.2 The contract between them

The two halves meet at exactly **one** artifact, and nowhere else:

```
                        ┌──────────────────────────────┐
   R half writes  ───►  │  phenotypes_v<N>.parquet     │  ◄─── Python half reads
                        │  + configs/phenotype_schema  │
                        └──────────────────────────────┘
```

- One row per `person_id`. Columns, types, units, and permitted values are declared in
  `configs/phenotype_schema.json`.
- **Both sides validate against that schema** — R on write, Python on read. A schema violation is a
  hard failure, never a warning.
- The file is **versioned and immutable**. `phenotypes_v2.parquet` never overwrites
  `phenotypes_v1.parquet`; previous analyses stay reproducible.

This is decision **D-005**. The point of a single narrow contract is that either half can be
rewritten — including replacing the R half with Python later — without touching the other.

### 3.3 Repository layout

```
lancaster_lab/
├── CLAUDE.md              instructions for the AI assistant working in this repo
├── README.md              orientation: what this is, how to run it
│
├── DESIGN.md              ← you are here
├── DECISIONS.md           every significant decision, with reasoning
├── ASSUMPTIONS.md         every assumption, none hidden in code
├── VALIDATION.md          how we know each step worked
├── TASKS.md               the priority queue
├── QUESTIONS.md           open scientific questions
├── JOURNAL.md             chronological log of work sessions
├── handoff.md             things only a human can unblock
├── loop.md                the autonomous working loop
├── GLOSSARY.md            every technical term, explained for a newcomer
│
├── configs/               ALL parameters. No hard-coded paths or thresholds in code.
│   ├── config.yaml            paths, cohort criteria, physiologic bounds
│   └── phenotype_schema.json  the R→Python contract (§3.2)
│
├── sql/                   BigQuery / DuckDB queries, one file per domain
│
├── src/                   production logic ONLY (never notebooks)
│   ├── aou_ascvd/             Python package
│   │   ├── io/                    load/save, schema validation
│   │   ├── prevent/               the PREVENT equations
│   │   ├── features/              genetic feature construction
│   │   ├── stats/                 survival models, discrimination, calibration
│   │   ├── validation/            data-quality reports
│   │   └── viz/                   figures (every figure regenerable from code)
│   └── phenotype/             R package: the phenotyping ETL
│
├── tests/
│   ├── python/            pytest: unit + integration + validation tests
│   └── testthat/          testthat: same, for the R half
│
├── fixture/               synthetic All of Us CDR — the offline test substrate (see FORMAT.md)
├── notebooks/             EXPLORATORY ONLY. Nothing here is ever a dependency of src/.
├── reports/              generated outputs. Sources tracked; rendered artifacts gitignored.
├── docs/                  tutorials and educational notes
└── data/                  ENTIRELY GITIGNORED. Real data never enters this repository.
```

**Rules that this layout enforces:**
1. Notebooks are for exploring. Once logic works, it moves to `src/` and gets a test. Nothing in
   `src/` may import from `notebooks/`.
2. No hard-coded paths, thresholds, or concept IDs in code — they live in `configs/`.
3. Never overwrite a previous analysis; version the output.
4. Never commit generated data or credentials.

---

## 4. Data flow

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │  All of Us Researcher Workbench  (Controlled Tier — real data, cloud)  │
 │                                                                        │
 │   BigQuery CDR v7 (OMOP)          srWGS genomic data                   │
 │   person, measurement,            (Hail MatrixTable / VDS,             │
 │   condition_occurrence,            plink / VCF exports)                │
 │   drug_exposure, observation,               │                          │
 │   procedure_occurrence,                     │                          │
 │   visit_occurrence, ds_survey               │                          │
 │            │                                │                          │
 │            │ sql/*.sql  (cohort gate:       │  variant QC,             │
 │            │  has_whole_genome_variant=1)   │  MAF filter, annotation  │
 │            ▼                                ▼                          │
 │   ┌──────────────────┐              ┌──────────────────┐               │
 │   │ src/phenotype (R)│              │ src/aou_ascvd/   │               │
 │   │ clean, dedupe,   │              │   features/      │               │
 │   │ one row/person   │              │ gene burden      │               │
 │   └────────┬─────────┘              └────────┬─────────┘               │
 │            │ validate vs schema              │                         │
 │            ▼                                 │                         │
 │   phenotypes_v<N>.parquet ◄─── THE CONTRACT ─┤                         │
 │            │                                 │                         │
 │            ▼                                 ▼                         │
 │   ┌───────────────────────────────────────────────────┐                │
 │   │ src/aou_ascvd/prevent/   → 10y / 30y risk         │                │
 │   │ src/aou_ascvd/stats/     → offset Cox, ΔC,        │                │
 │   │                             calibration, NRI, DCA │                │
 │   │ src/aou_ascvd/viz/       → figures                │                │
 │   └───────────────────┬───────────────────────────────┘                │
 │                       ▼                                                │
 │                  reports/  (aggregate results only)                    │
 └───────────────────────┼────────────────────────────────────────────────┘
                         │  ONLY non-identifiable, aggregate results leave the Workbench
                         ▼
                   this repository
```

**Offline, this repository substitutes `fixture/` for the top-left box.** The fixture is a synthetic
DuckDB stand-in for the OMOP CDR, described in [`FORMAT.md`](FORMAT.md). It contains no real data and
lets the entire ETL and its cleaning rules be tested on a laptop. There is **no offline substitute
for the genomic half yet** — see Q-G3.

---

## 5. Analysis workflow

Executed in order. Each stage is a task in [`TASKS.md`](TASKS.md) and has a contract in
[`VALIDATION.md`](VALIDATION.md).

| # | Stage | Output |
|---|---|---|
| 1 | **Cohort construction** — srWGS, age 30–79, no prior ASCVD, PREVENT inputs available | cohort table + attrition flowchart |
| 2 | **Phenotype ETL** — clean each OMOP domain, one row per person | `phenotypes_v<N>.parquet` |
| 3 | **Data quality report** — missingness, dictionary, outliers, duplicates, schema | `reports/quality/` |
| 4 | **PREVENT computation** — 10y and 30y risk per person | risk column + calibration plots |
| 5 | **Baseline validation** — how well does PREVENT perform *in All of Us*? Discrimination and calibration, overall and by sex and genetic ancestry | this is a result in its own right |
| 6 | **Genetic feature construction** — variant QC, MAF bands, functional masks, gene-level aggregation | gene × person burden matrix |
| 7 | **Incremental value test** — offset Cox (§1.3); ΔC-index, time-dependent AUC, calibration, ***NRI***, ***decision-curve analysis*** | the primary result |
| 8 | **Sensitivity analyses** — MAF thresholds, variant masks, gene sets, ancestry-stratified, competing-risk (Fine–Gray) | robustness table |

**Stage 5 is not a formality.** PREVENT was derived in a different population; it will almost
certainly be **miscalibrated** in All of Us. If we skip this and go straight to stage 7, any apparent
"genetic improvement" may be nothing more than genetics soaking up PREVENT's calibration error. This
is the most likely way for this project to produce a wrong answer, and stage 5 is the guard against it.

---

## 6. Statistical workflow

### 6.1 The models

Let `LP_i` be the PREVENT linear predictor for person *i*, and `G_i` the genetic burden term.

| Model | Specification | Purpose |
|---|---|---|
| **M0** baseline | `h(t) = h₀(t) · exp(LP_i)` — offset, nothing estimated | PREVENT as published |
| **M0'** recalibrated | `h(t) = h₀(t) · exp(β · LP_i)` — `β` estimated | quantifies PREVENT's miscalibration in All of Us |
| **M1** incremental | `h(t) = h₀(t) · exp(offset(LP_i) + γ · G_i)` | **the primary test: is `γ` ≠ 0?** |
| **M2** refit | `h(t) = h₀(t) · exp(β · LP_i + γ · G_i)` | secondary; allows PREVENT to recalibrate |

The primary hypothesis test is on `γ` in **M1**.

### 6.2 How improvement is measured

Three different things, which are routinely and wrongly conflated:

- ***Discrimination*** — can the model rank a case above a non-case? (Harrell's ***C-index***,
  time-dependent AUC.) Note that **ΔC-index is notoriously insensitive**: a genuinely useful new
  predictor often moves it by 0.005. A tiny ΔC is *not* evidence of no effect.
- ***Calibration*** — do predicted risks match observed risks? (Calibration slope and intercept,
  ***ICI***, calibration plots by decile.) A model can discriminate well and still be badly wrong
  about absolute risk, which is what a clinician actually acts on.
- ***Clinical utility*** — does using the model lead to better decisions? (***Decision-curve
  analysis***, net benefit.) This is the only one that answers "should we do this in clinic?"

***NRI*** will be reported because reviewers ask for it, but it is **known to be biased toward
declaring improvement** and will not be a primary endpoint (Q-S3, D-007).

### 6.3 Multiple testing

If gene-level burden is tested exome-wide (~20,000 genes), the significance threshold must be
corrected (Bonferroni ≈ 2.5 × 10⁻⁶). If instead a *pre-specified* lipid/CAD gene set is used
(`LDLR`, `APOB`, `PCSK9`, `LPA`, `APOA5`, `ANGPTL3/4`, …), the burden is far lighter but the finding
is confirmatory rather than discovery. **This choice must be made and frozen before looking at
outcomes** — Q-G1.

---

## 7. Validation strategy

Validation is a first-class deliverable, not a chore. Full contract in [`VALIDATION.md`](VALIDATION.md).

Four layers:

1. **Unit tests** — does each function do what it claims, on tiny inputs with known answers?
2. **Integration tests** — does the pipeline run end-to-end on the synthetic `fixture/`?
3. **Validation tests (scientific ground truth)** — does the code reproduce *externally known*
   answers? Chiefly: **PREVENT must reproduce the published example risk values from Khan et al. to
   within rounding.** If it cannot, the implementation is wrong, no matter how clean the code is.
4. **Data quality reports** — for every dataset produced: missingness, variable summary, data
   dictionary, quality report, unexpected values, outliers, duplicates, schema validation.

**A task is not complete until its validation passes.** No exceptions.

---

## 8. Data governance (non-negotiable)

- Real participant data **never** leaves the All of Us Researcher Workbench and **never** enters this
  repository — not in a notebook output, not in a CSV, not in a commit message, not in a figure.
- Only **aggregate, non-identifiable results** may be exported, subject to All of Us policy
  (including small-cell suppression).
- `data/` is entirely gitignored.
- Everything in `fixture/` is **synthetic and invented**; it is safe to commit and contains no
  controlled-tier content.
- The notebook is committed *with outputs*; those outputs derive from real data and must be reviewed
  before any public push (**A-012**, and Q-R2).

---

## 9. Deliverables

| # | Deliverable | Consumer |
|---|---|---|
| 1 | Reproducible phenotyping pipeline (R) validated against a synthetic CDR | the lab; future studies |
| 2 | Validated Python PREVENT implementation | the field; reusable |
| 3 | **Performance of PREVENT in All of Us**, by sex and genetic ancestry | a paper in itself |
| 4 | Rare-variant feature pipeline (QC → masks → gene burden) | the lab |
| 5 | **The primary result: does low-frequency variation add predictive value beyond PREVENT?** | the paper |
| 6 | A framework that generalizes to other baselines and other variant classes | grants; future work |
| 7 | This documentation set — enough for someone else to rerun everything from a clean clone | reviewers; the future |

A **negative result is a real result** here and the project is designed to be able to report one
credibly: that requires the baseline to be validated (§5, stage 5) and the analysis pre-specified
(§6.3) *before* the answer is known.

---

## 10. Current state

Nothing above is implemented yet. This is a scaffold: documentation, directory structure, config, and
a test harness. See [`TASKS.md`](TASKS.md) for what happens next and [`handoff.md`](handoff.md) for
what is blocked on a human.
