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

- **Status:** ⛔ **SUPERSEDED BY D-011 (2026-07-14)** — the project is now all-R. Kept in full, per the
  append-only rule: the reasoning below is still the reason the *ETL* is in R, and only the Python half
  went away.
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

- **Status:** ⛔ **SUPERSEDED BY D-012 (2026-07-14)** — there is no longer an R→Python boundary to
  guard. The *versioning, schema validation, and immutability* survive; only the cross-language
  rationale is gone.
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

## D-011 — The project is **all R**. The Python half is dropped.

- **Status:** ACCEPTED · **Supersedes:** D-002
- **Date:** 2026-07-14 (advisor meeting)
- **Context:** D-002 split the project in two — R for the ETL, Python for PREVENT, statistics, and
  figures — on the reasoning that PREVENT's reference implementation and the best survival/calibration
  tooling were Python. **That premise is false: the PREVENT equations are available in R.** With it
  gone, the entire argument for the split collapses, and the user (who will be doing the work) is
  working solely in R.
- **Alternatives:** keep the split (now paying two toolchains, two test frameworks, and a serialisation
  boundary for *no* remaining benefit); or go all-R.
- **Reasoning:** D-002 accepted a real, recorded cost — "two toolchains, two dependency systems, two
  test runners, a serialization boundary" — and it bought exactly one thing: access to Python's
  modelling ecosystem. That thing turned out not to be needed. Paying a cost for a benefit that does
  not exist is the easiest kind of decision to reverse. R's survival stack (`survival`, `rms`,
  `riskRegression`, `timeROC`, `dcurves`) covers every method in DESIGN §6.
- **Decision:** **All analysis code is R.** `src/aou_ascvd/` (Python) is deleted before it is ever
  written. Everything lives in `src/phenotype/` (ETL) and a new `src/ascvd/` (PREVENT, statistics,
  figures). Tests are `testthat` only; `pytest` is dropped.
- **Scope note — the fixture *builder* stays Python.** `fixture/build/*.py` is **test tooling, not
  analysis**: it generates a synthetic DuckDB CDR and replays the pipeline to diff against an answer
  key. It works, it is not on the scientific path, and rewriting it in R would be pure risk for zero
  scientific payoff — the same argument D-002 made for *keeping* the R ETL, applied symmetrically.
  It stays until there is a reason to touch it.
- **Expected impact:** *Easier:* one language, one test runner, one dependency system; no serialisation
  boundary; the author can actually read every line. *Harder:* R's decision-curve and
  time-dependent-AUC tooling is thinner than Python's, and we lose `lifelines`/`scikit-survival` as a
  cross-check. If a specific method proves unavailable in R, that is a new decision, not a licence to
  quietly reintroduce Python.
- **Links:** D-002 (superseded), D-012, T-016, `src/ascvd/`.

---

## D-012 — The phenotype table stays versioned, schema-validated, and immutable — now within R

- **Status:** ACCEPTED · **Supersedes:** D-005
- **Date:** 2026-07-14
- **Context:** D-005 made the phenotype table a Parquet file with a JSON schema, validated on both
  sides, because it was the seam between two languages and seams are where silent bugs live. D-011
  removes the seam.
- **Reasoning:** the *cross-language* rationale is gone, but **none of the other reasons were about
  language.** A schema still turns a renamed column, a mg/dL→mmol/L unit drift, or a duplicated
  `person_id` into a loud failure instead of a quietly wrong number. Versioning still keeps last
  month's analysis reproducible. Those protections were never Python's doing, and dropping them
  because the language changed would be throwing away the guard along with the thing it guarded.
- **Decision:** the ETL still writes **`phenotypes_v<N>.parquet`**, still validated against
  `configs/phenotype_schema.json` **on write and on read**, still immutable (a new version never
  overwrites an old one). Validation is now R-side only (one gate instead of two). Parquet is retained
  over `.rds` because the genetics tooling arriving next week (PRS, variant burden) is not all R, and
  a typed, language-neutral file costs nothing to keep.
- **Expected impact:** we keep every protection that mattered. Cost: **R `arrow` must be installed** —
  it currently is not (`docs/environment.md`), and a CSV fallback is explicitly rejected for the same
  reason D-005 rejected it: CSV has no types.
- **Links:** D-005 (superseded), D-011, `configs/phenotype_schema.json`, T-003.

---

## D-013 — Cohort: age ≥ 30, complete PREVENT inputs, no ASCVD before baseline

- **Status:** ACCEPTED · **Resolves:** Q-A1's population half
- **Date:** 2026-07-14 (advisor meeting)
- **Context:** DESIGN §2 had the population "proposed" and the index date open. The advisor settled it.
- **Decision:**
  1. **Age ≥ 30** at baseline, per PREVENT's own validated range.
  2. **Complete-case:** a participant is eligible **only if every PREVENT input is available**.
     Participants missing any input are **excluded** — not imputed.
  3. **No ASCVD before baseline** — PREVENT is a primary-prevention model and is undefined for people
     who already have the disease.
  4. Covariates are taken from **before the event**; the cohort is then **stratified on whether an
     event occurred**, to ask whether the model predicts it.
- **Expected impact — and the cost is real, so it is recorded and not buried:** complete-case
  restriction is *not* a neutral filter. Having a full PREVENT panel (lipids **and** SBP **and**
  creatinine **and** smoking **and** diabetes status) is a marker of **sustained healthcare contact**.
  The excluded are disproportionately people with sparse EHR — which tracks insurance, access, and
  therefore socioeconomic status and ancestry. So the analysis cohort is a healthier, better-monitored
  subset than All of Us as a whole, and **generalisability is limited accordingly**. This is
  recorded as **A-015 (🔴)**, and the mitigation is to *quantify* it: compare included vs. excluded on
  the variables we do observe, and report it as an attrition table (T-002). Note it also interacts with
  A-011: if completeness correlates with ancestry, so does cohort membership.
- **Links:** A-015; Q-S1; Q-S6; Q-S7; T-002; T-003; `configs/config.yaml`.

---

## D-014 — ASCVD events are ascertained from **both** ICD conditions and CPT procedures, via a resolved concept dictionary

- **Status:** ACCEPTED · **Resolves:** Q-A1's outcome half
- **Date:** 2026-07-14 (advisor meeting)
- **Context:** Q-A1 was blocking everything: PREVENT's linear predictor is only a valid offset for the
  outcome PREVENT was built to predict, so the outcome definition had to be settled by someone with
  domain authority.
- **Decision:** ASCVD is ascertained from **both** billing/diagnosis codes (ICD, via
  `condition_occurrence`) **and** procedure codes (CPT, via `procedure_occurrence`). Both are pulled,
  both are analysed. Crucially, the codes are **not** treated as opaque IDs: we build tooling that
  **resolves each `concept_id` back to its code and its meaning in the All of Us vocabulary** and then
  uses that to establish (a) **when** the event occurred and (b) **what disease type / stage** it
  represents.
- **Reasoning:** a concept ID is meaningless on its own, and All of Us's vocabulary is the only
  authority on what a given ID actually denotes. The existing notebook hardcodes long lists of concept
  IDs pasted from the Cohort Builder with **no record of what they mean** — which is exactly why a
  wrong or stale ID returns zero rows *with no error*. Resolving codes to names makes the outcome
  definition **inspectable and reviewable** rather than a wall of integers, and it is what lets us
  distinguish an acute MI from a chronic ischemic-heart-disease code from a revascularisation
  procedure — a distinction the current `codes_df` collapses entirely.
- **Expected impact:** the outcome becomes auditable. It also surfaces a question the old pipeline hid:
  **a revascularisation (CPT) is a treatment decision, not purely a disease event**, and it is
  confounded by healthcare access. Including it inflates event counts; excluding it loses real events.
  The dictionary is what lets us report both.
- **Links:** Q-A1 (resolved); T-014; T-015; `src/phenotype/R/concept_dictionary.R`.

---

## D-015 — Age 30–79; the complete-panel skew is accepted and reported; event-time anchoring is deferred

- **Status:** ACCEPTED
- **Date:** 2026-07-14 (user, following the advisor meeting)
- **Context:** three open items from the advisor meeting, closed together.
- **Decision:**
  1. **Age 30–79** (resolves **Q-S7**). The upper bound is PREVENT's validated range; above 79 the
     model would be extrapolated outside the data it was fitted in.
  2. **The complete-panel selection skew is accepted as a limitation** (resolves **A-015**). We
     require a complete PREVENT panel *in order to base the model on the equation as published*, and
     we accept that this yields a healthier, better-monitored cohort. **The concession is conditional
     on reporting it:** demographics of included vs. excluded are checked and the result is published
     with that caveat. The caveat is not a sentence in a discussion section — it is a table (T-002,
     and §C of `sql/02_prevent_panel_completeness.sql`).
  3. **Event-time anchoring is a later goal, not this week's** (defers **Q-S6**). For now, events are
     simply *included* in the data, and **the timing is preserved**: when each event happened and when
     each value was obtained are carried as separate, explicit columns.
- **Reasoning on (3), because it is the subtle one:** the temptation would be to fold timing away now
  and reconstruct it later. Carrying the dates forward instead costs nothing today and keeps every
  anchoring option open — a common baseline, a landmark time, a nested design. **What we must not do
  is let a de-facto anchor creep in by accident**: if an extraction quietly takes each person's
  *earliest* value (the notebook's habit — A-001), then cases and non-cases end up anchored
  differently and every predictor looks stronger than it is, with no bug appearing anywhere. So the
  deferral is safe **only because timing is retained and no anchor is applied**. That is the whole
  point of keeping the dates.
- **Expected impact:** the phenotype table gains a date column beside every value and every event.
  Q-S6 stays open as a **later goal** (T-019) rather than a blocker; T-002 is unblocked.
- **Links:** Q-S6 (deferred → T-019), Q-S7 (resolved), A-015 (accepted), A-001, D-013, T-019.

---

## D-009 — Same-day duplicate measurements are resolved by taking their **mean**

- **Status:** ACCEPTED
- **Date:** 2026-07-14
- **Context:** A-002 is **REFUTED as safe**. Every "Format" section of the notebook ends with
  `distinct(person_id, .keep_all = TRUE)` after a `min(date)` filter, which keeps whichever row
  happens to arrive first — and the generated SQL has **no `ORDER BY`**. So for anyone with more than
  one measurement on their earliest date, the value that reaches the analysis is **arbitrary and can
  differ between runs**. Results are not bit-reproducible today. The fixture proves it: participant
  `1000006` has same-day LDL values of 130, 131, and 132, and the answer key can only assert
  *membership* (`one_of:130|131|132`), not a value.
- **Alternatives:**
  1. *Keep `first` (status quo).* Zero work; results remain non-reproducible. Not viable for
     publication.
  2. *Mean of the same-day values.* Uses all the information; smooths assay measurement error.
     Produces a value that was never literally observed.
  3. *Median.* Robust to a single wild same-day outlier — but with the 2–3 repeats that are typical,
     it is almost always identical to the mean, so the robustness rarely buys anything.
  4. *Min.* Conservative for a risk factor, but it biases every person's LDL **downward** —
     working directly against detecting the FH carriers this study exists to find.
  5. *Max.* Biases upward, symmetrically.
- **Reasoning:** the user chose the mean. Same-day repeats of a lab are best understood as repeated
  measurements of one underlying quantity, so averaging them is the natural estimator and it uses all
  the data. Min and max were rejected because both impose a *systematic directional bias* on the
  study's key exposure variable; min in particular would attenuate the very signal we are testing for.
  Median was rejected as near-identical to the mean at realistic repeat counts.
- **Decision:** `same_day_tiebreak: mean`. `clean_measurement()` now defaults to `tiebreak = "mean"`.
  The legacy `"first"` path is retained but **warns that it is not reproducible**.
- **Expected impact:** results become bit-reproducible, which is a precondition for publishing
  anything. Cost: the ETL no longer reproduces the notebook bit-for-bit, so the fixture's
  `one_of:130|131|132` assertion must tighten to `131` **at the point where the pipeline switches over
  to the package** — until then the notebook still uses `distinct()` and the fixture correctly asserts
  the old behaviour. Do not change the answer key before the ETL actually changes.
- **Links:** A-002; T-005; `configs/config.yaml`; `src/phenotype/R/clean_measurement.R`.

---

## D-010 — The hardcoded workspace identifiers stay; the risk is accepted, not fixed

- **Status:** ACCEPTED
- **Date:** 2026-07-14
- **Context:** T-012's audit cleared the participant-data risk (A-012 — the notebook has **no outputs
  at all**) but found a smaller one (A-014): the notebook hardcodes the workspace bucket UUID and the
  owner's institutional email in 13 cells
  (`gs://fc-secure-7e84f6f0-…/bq_exports/megan.lancaster@researchallofus.org/…`), and the fixture
  mirrors those literals as ~24 tracked directory names.
- **Alternatives:**
  1. *Parameterise the paths and rewrite history.* The clean end state. But the notebook's "Format"
     cells resolve those `gs://` paths as **literals**, and the fixture was deliberately built to
     mirror them so the notebook runs **unmodified** offline — so notebook, fixture, and answer key
     would all have to change together, and `verify.py` re-verified. It also cuts against CLAUDE.md's
     rule that the notebook's quirks are load-bearing and must not be silently "fixed".
  2. *Ask the lab / Megan first.*
  3. *Leave it.*
- **Reasoning:** the user chose to leave it. The exposure is **not** a data-policy breach: no
  participant data, and the bucket is access-controlled, so the UUID is an identifier rather than a
  credential. Weighed against that, option 1 means modifying a notebook the lab treats as validated and
  rebuilding the offline harness that everything else is tested against — real risk, for a low-severity
  disclosure.
- **Decision:** leave the identifiers in place. Q-R3 is closed. A-014 becomes
  **ACCEPTED-AS-LIMITATION** rather than an open item.
- **Expected impact:** no work, no risk to the fixture. **Two things are worth being honest about:**
  (a) a colleague's institutional email will appear in a public repository and she has not been asked;
  (b) this decision is *cheap to reverse today* (3 commits, no collaborators) and gets materially more
  expensive the moment anyone clones, because scrubbing the working tree does not scrub git history.
  If either of those matters later, reversing this is a `git filter-repo` job — reopen as a new
  D-entry rather than editing this one.
- **Links:** A-014; Q-R3 (resolved); T-012; T-013 (closed); H-006.

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
