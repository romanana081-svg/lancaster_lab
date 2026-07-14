# TASKS.md

The priority queue. One task per unit of work that can be *finished and validated*.

**A task is not done when the code runs. It is done when its validation passes** — every task carries a
"Done when" clause, and that clause is the contract. If it cannot be stated, the task is not yet
understood well enough to start (see [`VALIDATION.md`](VALIDATION.md)).

**Status:** `TODO` · `IN PROGRESS` · `BLOCKED` (→ why, and the `H-0NN` / `Q-` that blocks it) ·
`DONE` (→ date)
**Priority:** P0 do this next · P1 on the critical path · P2 needed, not urgent · P3 nice to have

**Template**

```
### T-0NN — <title>
- Status / Priority / Depends on / Blocks
- Why:       what this buys us
- Done when: the falsifiable completion criterion
- Notes:     traps, links to D- / A- / Q- entries
```

---

## This week (advisor's plan, 2026-07-14)

> **The goal:** build the code that pulls the **PREVENT inputs** and the **ASCVD event data**, cleans
> them, and is tested **both here (on the fixture) and in All of Us** — then check the result against
> the PREVENT literature. PRS and low-frequency variants start next week.

The order below is not arbitrary. **T-017 comes first** because it is one query and it decides whether
the rest of the plan is even feasible; **T-014 comes before T-015** because you cannot ascertain events
from codes you have not yet resolved; and **T-004 blocks the offline testing half of the goal**,
because the fixture currently contains almost none of the PREVENT variables.

### T-017 — Count the PREVENT panel completeness in the real CDR **first**
- **Status:** **QUERY WRITTEN & TESTED — awaiting a Workbench run** · **Priority:** P0
  · **Blocked by:** H-004 (Workbench access only) · **Blocks:** T-002
- **Progress 2026-07-14:** `sql/01_prevent_concept_discovery.sql` and
  `sql/02_prevent_panel_completeness.sql` are written, run against the fixture, and covered by tests.
  `src/phenotype/R/run_sql.R` runs either file against **DuckDB offline or BigQuery in the Workbench**
  — it picks the backend from `WORKSPACE_CDR`, so the same SQL runs in both places unchanged.
  **To run it in All of Us:** open an R notebook, `source("src/phenotype/R/run_sql.R")`, then
  `run_sql_file("sql/01_prevent_concept_discovery.sql")` — **query 01 first**, then 02.
- **Fixture result (a fixture fact, NOT a data finding):** 179 eligible srWGS participants aged 30–79;
  **0 with a complete panel**, because the fixture has no systolic BP and no serum creatinine at all.
  Query 01 correctly reports those codes as `DOES NOT RESOLVE`. That is exactly the distinction the
  discovery step exists to make: **"0% coverage" and "your code is wrong" look identical** unless you
  check the vocabulary first.
- **Why:** D-013 **excludes** anyone missing any PREVENT input, so **the completeness rate *is* the
  sample size** (A-016). Nobody has counted it. If the complete-panel cohort turns out to be small, the
  study is underpowered before genetics is even added, and the response is a *design change* — a
  relaxed panel, imputation, a broader outcome — not a shrug. This is one query and it is far better to
  learn the answer in week one than in month three.
- **Done when:** for srWGS participants aged ≥ 30, we have a count for **each** PREVENT input
  separately **and for the full intersection**, plus the same broken down by sex and genetic ancestry
  (that breakdown is what tests A-015).
- **Notes:** run this before writing the extractor, not after. The answer may change what the extractor
  needs to do.

### T-014 — Concept-code dictionary: resolve `concept_id` → code → meaning
- **Status:** TODO · **Priority:** P0 · **Blocks:** T-015, T-003
- **Why:** D-014. The existing notebook hardcodes long lists of concept IDs pasted from the Cohort
  Builder **with no record of what any of them mean** — which is exactly why a wrong or stale ID
  returns zero rows *with no error*. Resolving IDs against the All of Us vocabulary makes the outcome
  definition **inspectable and reviewable**, and it is what lets us tell an acute MI from a chronic
  ischemic-heart-disease code from a revascularisation procedure — a distinction the notebook's
  `codes_df` collapses entirely.
- **Done when:** given any set of concept IDs (or an OMOP domain), we can produce a table of
  `concept_id, concept_code, vocabulary, concept_name, domain`, works against **both** the fixture
  (DuckDB `concept` table) and BigQuery, and every ID used in an outcome definition is round-tripped
  through it. Unresolvable IDs **fail loudly** rather than silently disappearing.
- **Notes:** the fixture has a real `concept` table (208 rows: ICD10CM, CPT4, LOINC, RxNorm, SNOMED),
  so this is testable offline today.

### T-015 — ASCVD event ascertainment: timing, type, and stage
- **Status:** TODO · **Priority:** P0 · **Depends on:** T-014 · **Blocks:** T-002
- **Why:** D-014. Both **billing/diagnosis (ICD)** and **procedure (CPT)** codes are pulled and
  analysed, and the resolved dictionary is used to establish **when** each event happened and **what
  disease type/stage** it represents.
- **Done when:** per person we can produce the first ASCVD event date, its code, its resolved meaning,
  and its classification (acute event / chronic disease / revascularisation procedure); the ICD ∪ CPT
  union is handled (`combine_codes()` already does this); and the outcome can be reported **with and
  without** revascularisation.
- **Notes:** a **revascularisation is a treatment decision, not purely a disease event** — it is
  confounded by healthcare access. Including it inflates the event count; excluding it loses real
  events. The point of the dictionary is that we no longer have to choose blind: report both (Q-A1).

### T-003 — Extract the PREVENT input panel *(rewritten 2026-07-14)*
- **Status:** TODO · **Priority:** P0 · **Depends on:** T-014, T-017 · **Blocks:** T-002, T-016
- **Why:** **The largest implementation gap in the project.** PREVENT needs total cholesterol, HDL-C,
  systolic BP, antihypertensive use, diabetes, current smoking, eGFR (from serum creatinine), BMI, age,
  and sex (D-004). The existing notebook extracts **only BMI** of that list — it was built for an LDLR
  study, and LDL and triglycerides are *not* PREVENT inputs at all.
- **Done when:** each input is extracted, unit-harmonised, bounded, and lands in
  `phenotypes_v<N>.parquet` conforming to `configs/phenotype_schema.json`; missingness is reported per
  input; and the fixture covers every new domain (T-004).
- **Notes:**
  - **eGFR is a derived variable, not a lab.** It comes from serum creatinine via the **CKD-EPI 2021**
    equation — the **race-free** version. Using the older race-adjusted equation would smuggle race
    back into a model that was deliberately built without it (D-004), which would be a real scientific
    error, not a nit.
  - **A-001 (earliest-value-wins) is the wrong anchor here** and must not be copied over. The right
    anchor is the value at *baseline*, and baseline is Q-S6 — still open.
  - **Do not port A-004's LDL `< 400` cap.** It deletes untreated FH carriers, i.e. the strongest
    rare-variant carriers. (LDL is not a PREVENT input anyway, but the same reflex must not be applied
    to total cholesterol.)

### T-004 — Extend the fixture to the PREVENT domains *(now blocking, not housekeeping)*
- **Status:** TODO · **Priority:** P0 · **Paired with:** T-003 · **Blocks:** the "test it here" half of
  this week's goal
- **Why:** **The fixture currently contains almost none of the PREVENT variables.** Verified
  2026-07-14: it has LDL (278 rows), triglycerides (202), BMI (170), and exactly **one** HDL row and
  **one** total-cholesterol row. It has **no systolic BP, no serum creatinine, no HbA1c/diabetes, no
  smoking status, and no antihypertensive drugs.** You cannot test a PREVENT extractor offline against
  data that has no PREVENT variables in it, so this is a hard prerequisite for testing anything this
  week — not a chore to do afterwards.
- **Done when:** every PREVENT input has (a) seeded `concept` + `cb_criteria` vocabulary so the
  generated SQL returns rows, (b) at least one deliberately dirty record exercising the relevant defect
  class (wrong unit, out-of-range, same-day duplicate, missing), and (c) a named participant in
  `expected/answer_key.csv`. Plus: a participant with an **incomplete panel**, who must be *excluded*
  by D-013 — the eligibility rule needs a test as much as the cleaning does. `verify.py` stays green.
- **Notes:** extend, never regenerate blindly — participants `1000001`–`1000027` are hand-authored and
  the answer key depends on them.

### T-016 — PREVENT in R, validated against the published literature
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** H-002 · **Depends on:** T-003
  · *(replaces the old T-006, which assumed a Python implementation)*
- **Why:** PREVENT is the baseline (D-004) and its linear predictor is the offset in the primary model
  (D-006). If the implementation is subtly wrong, **every result in the project is wrong**, and wrong
  in a way no downstream statistical care can detect.
- **Done when:** it **reproduces the published example risk values from Khan et al. (2024) to within
  rounding** — pass/fail, no partial credit (VALIDATION §1, layer 3). Sex-specific coefficients, the
  10-year and 30-year equations, and the input units (mg/dL vs mmol/L — the classic trap) are all
  unit-tested.
- **Notes:** the advisor says the equations are already in R (which is what killed the Python half,
  D-011). **Borrowed code is not validated code** — whether we install `preventr`, use the advisor's
  code, or transcribe from the supplement, the published-worked-example test is the gate either way.

### T-019 — Event-time anchoring: define the baseline for non-cases — *later goal*
- **Status:** DEFERRED (by decision — D-015) · **Priority:** P2 · **Blocks:** any survival model
  (T-007, T-009)
- **Why:** Q-S6. "Use data from before the event" defines a baseline for cases and for nobody else,
  and most participants never have an event. Deferred on purpose: this week we include the events and
  **keep the timing**, which costs nothing and leaves every option open.
- **Done when:** a single anchoring rule is chosen and applied **symmetrically** to cases and
  non-cases (candidates: first complete panel; a landmark time; a nested design), and it is applied
  *before* any survival model is fitted.
- **⚠️ The one way this deferral goes wrong:** a de-facto anchor creeping in by accident. If any
  extractor quietly takes each person's *earliest* value (A-001 — the notebook does this everywhere),
  cases and non-cases end up anchored differently and **every predictor looks stronger than it is,
  with no bug appearing anywhere.** `configs/config.yaml: anchor: none` and `retain_all_dates: true`
  are what keep the deferral honest. Do not "helpfully" reduce a person to one value per variable.

### T-002 — Cohort construction and the attrition flowchart
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** T-014, T-015, T-017 · **Blocks:** T-007,
  T-009 · *(Q-S6 and Q-S7 no longer block — D-015)*
- **Why:** Stage 1 of DESIGN §5. Every downstream number is conditioned on who is in the cohort.
- **Done when:** a reproducible cohort table exists (srWGS, age ≥ 30, complete PREVENT panel, no prior
  ASCVD — D-013), with an attrition flowchart accounting for **every** excluded person, and the counts
  are reproduced by a test on `fixture/`.
- **Notes — the attrition table is a scientific result here, not bookkeeping.** A-015: the complete-
  panel requirement excludes people with sparse EHR, who differ systematically (access, socioeconomic
  status, ancestry). **Compare included vs. excluded on everything observable for both** — that
  comparison is what bounds the generalisability claim, and it is what tells us whether cohort
  membership is entangled with ancestry before the PRS work begins.

---

## Next — the phenotype pipeline

### T-005 — Refactor the notebook's R logic into a tested `src/phenotype/` package
- **Status:** IN PROGRESS · **Priority:** P1
- **Progress 2026-07-14:** `src/phenotype/R/clean_measurement.R` now implements the six-step idiom
  once, with every buried literal (units, bounds, anchor, tie-break) promoted to an argument.
  **23 `testthat` tests pass** — the R half is tested locally for the first time (possible only because
  H-001 turned out to be a non-blocker). Defaults are **bit-compatible with the notebook**: nothing is
  silently improved. The tests pin the *known bugs* as well as the wanted behaviour, so neither can
  change by accident — including the lowercase-`mg/dl` data loss (A-003) and the arbitrary tie-break.
- **Progress 2026-07-14 (later):** the tie-break decision is **settled — D-009, `mean`** — and
  `clean_codes()` / `combine_codes()` / `as_binary_phenotype()` now cover the code-based phenotypes
  (CAD, PAD, FH, hypercholesterolemia), including the notebook's ICD ∪ CPT union for CAD.
  **45 `testthat` tests pass.**
- **Still to do:** (a) the drug + survey domain — this is where the **`any_chol_med` defect** lives
  (a survey "No" is scored as a *user*), so fixing it is the substantive part, not a port;
  (b) demographics and the censoring/`censor_type` logic (the notebook's IN PROGRESS section);
  (c) the Parquet writer — **needs R `arrow`, which is not installed** (D-005 rejects a CSV fallback);
  (d) the end-to-end fixture test, at which point the answer key's `one_of:130|131|132` tightens
  to `131`.
- **Why:** D-002 keeps the ETL in R precisely because it is validated; but validated logic living in a
  notebook cannot be imported, tested, or reused, and the notebook does not even execute cleanly
  top-to-bottom (CLAUDE.md). Moving it into a package is what turns "it worked once in the cloud" into
  "it works, and we can prove it after every change".
- **Done when:** the cleaning pipeline is a set of R functions with `testthat` tests, the fixture-based
  end-to-end test passes, and **the same-day tie-break is deterministic** (A-002).
- **Notes:** A-002 is **REFUTED as safe** — `distinct(person_id, .keep_all = TRUE)` over SQL with no
  `ORDER BY` keeps an arbitrary row, so results are not bit-reproducible today. Fix it with an explicit
  rule (order by value, or mean the same-day values) and record the choice as a D-entry. Do not
  "tidy up" the other rough edges in passing — CLAUDE.md marks them as load-bearing history; flag them
  instead.

---

## Then — the model

### T-006 — ~~Implement PREVENT in Python~~ — **SUPERSEDED by T-016** (D-011: the project is all R)

### T-018 — PRS (polygenic risk score) — *next week, advisor-led*
- **Status:** TODO · **Priority:** P2 · **Depends on:** T-002 · **Blocks:** T-008's framing
- **Why:** the advisor has a good handle on this and will help. It is the **first** genetic layer, and
  the ordering is scientifically load-bearing: a PRS captures *common*-variant risk, so once it is in
  the model, the rare-variant question sharpens from "does genetics add anything beyond PREVENT?" to
  **"do rare variants add anything beyond PREVENT *and* common-variant risk?"** — which is the claim a
  reviewer will actually press on, and a much stronger paper if the answer is yes.
- **Done when:** a PRS per person, ancestry-appropriate (a PRS derived in European-ancestry cohorts
  performs *worse* in other ancestries — in a deliberately diverse cohort that is a first-class
  problem, not a footnote; see A-011), and validated by a positive control.

### T-007 — Validate PREVENT's performance *in All of Us*
- **Status:** TODO · **Priority:** P1 · **Depends on:** T-002, T-016 · **Blocks:** T-009
- **Why:** Stage 5 of DESIGN §5, and **the guard against the study's single most dangerous failure
  mode** (A-008, Q-S2). PREVENT was derived in a different population; it will almost certainly be
  miscalibrated here. If we skip straight to the genetic test, a genetic term can absorb that
  miscalibration and appear significant while carrying no genetic information at all. This task is not
  a formality and it is not optional.
- **Done when:** discrimination (Harrell's C, time-dependent AUC) and calibration (slope, intercept,
  ICI, decile plots) are reported for PREVENT in All of Us — overall **and stratified by sex and
  genetic ancestry** — and the answer to Q-S2 is decided *on the evidence produced here*, before any
  genetic term is fitted.
- **Notes:** this is deliverable #3 in DESIGN §9 — a publishable result in its own right, independent
  of whether the genetic finding is positive or negative.

### T-008 — Build the **low-frequency / rare-variant** feature pipeline — *the week after next*
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** Q-G1 (gene set), Q-G2 (MAF/mask), Q-G3
  (offline substrate), Q-S4 (power), T-018 (PRS comes first) · **Blocks:** T-009
- **Why:** Produces the `G` term — the exposure. Stage 6b of DESIGN §5. This is the "another layer" the
  advisor described: it sits **on top of** the PRS, and the incremental-value question is asked against
  PREVENT **and** the PRS together.
- **Done when:** variant QC, MAF banding, functional masking, and gene-level aggregation produce a
  gene × person burden matrix, **and the positive control passes: burden in `LDLR` associates with LDL
  cholesterol** (A-009). If that control fails, the pipeline is broken and nothing downstream of it can
  be believed — so it is the completion criterion, not a nice-to-have.
- **Notes:** the four blocking questions are not bureaucracy. Q-G1 and Q-G2 **must be frozen before
  outcomes are examined**, or the p-value means nothing regardless of its size. Q-S4 may reveal the
  study is underpowered, which would change this task's design rather than its schedule.

### T-009 — The incremental value test (the primary result)
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** T-002, T-006, T-007, T-008
- **Why:** The question the project exists to answer (DESIGN §1.1). Stage 7.
- **Done when:** models M0, M0', M1, M2 (DESIGN §6.1) are fitted; the primary test on `γ` in the offset
  model M1 is reported with a confidence interval; discrimination, calibration, and decision-curve
  analysis all appear (D-007); the proportional-hazards assumption is checked (Q-S5); and the
  **negative control** from Q-S2 has been run.
- **Notes:** a **negative result is a real result here** (DESIGN §9) — but only if the baseline was
  validated (T-007) and the analysis pre-specified (Q-G1, Q-G2, Q-S3) *before* the answer was known.
  Both conditions are the reason the tasks above block this one.

### T-010 — Sensitivity analyses
- **Status:** TODO · **Priority:** P2 · **Depends on:** T-009
- **Why:** Stage 8. A single result under a single set of choices is not robust, and reviewers will —
  correctly — ask what happens under the others.
- **Done when:** the pre-declared grid runs: MAF thresholds, variant masks, gene sets,
  ancestry-stratified models, and a competing-risk (Fine–Gray) model for non-ASCVD death.
- **Notes:** "pre-declared" is what separates a sensitivity analysis from a fishing expedition. The grid
  comes from Q-G2, and it is written down before T-009 is run, not after.

---

## Infrastructure

### T-001 — Repository scaffold and the ten project documents
- **Status:** IN PROGRESS · **Priority:** P1
- **Why:** D-001. Documentation that is not in git is not project memory; and the directory layout in
  DESIGN §3.3 is what enforces "no hard-coded thresholds", "notebooks are not dependencies", and
  "never overwrite an analysis".
- **Done when:** all ten documents exist and cross-reference each other consistently; `configs/`,
  `sql/`, `src/`, `tests/` exist with a working config; `.gitignore` no longer ignores itself; and the
  whole thing is committed.
- **Notes:** the docs currently reference IDs (`T-`, `Q-`, `H-`, `A-`, `D-`) across files — a broken
  cross-reference is a real defect in a memory system, so check them.

### T-011 — Data-quality report harness
- **Status:** TODO · **Priority:** P2 · **Depends on:** T-003
- **Why:** Stage 3, and layer 4 of the validation strategy (DESIGN §7). Every dataset the pipeline
  produces gets: missingness, a variable summary, a data dictionary, unexpected values, outliers,
  duplicates, and schema validation.
- **Done when:** `src/aou_ascvd/validation/` generates the report for any phenotype table, and it runs
  automatically as part of the ETL rather than as a thing someone remembers to do.
- **Notes:** this is how A-003 (unit strings), A-004 (bounds), and A-005 (LDL == Trig) get *measured*
  rather than assumed. Several assumptions currently sitting at UNVERIFIED are one report away from
  being settled.

---

## Done

### T-013 — Decide what to do about the hardcoded workspace identifiers ✅ 2026-07-14 (closed, no work)
- **Result:** decided **not** to scrub — D-010. The exposure (workspace bucket UUID + a colleague's
  email, in 13 notebook cells and ~24 fixture paths) is a low-severity disclosure, not a data-policy
  breach, and removing it would mean modifying a validated notebook *and* rebuilding the offline
  harness. A-014 becomes ACCEPTED-AS-LIMITATION; Q-R3 resolved.
- **If this is ever revisited:** it is cheap now (3 commits, no collaborators) and needs
  `git filter-repo` once anyone has cloned. Reopen as a new D-entry rather than editing D-010.

### T-012 — Audit the committed notebook's outputs for controlled-tier data ✅ 2026-07-14
- **Result:** **The notebook has no outputs at all** — 291 code cells, every one with `outputs: []` and
  `execution_count: null`, in the working tree *and* in both historical commits. Zero output bytes ever
  entered this repository. A-012 is VERIFIED (vacuously), and the project's highest-urgency governance
  blocker is cleared.
- **The premise was wrong.** CLAUDE.md states the notebook is ~180 KB *"because it is committed with
  outputs"*. It is not. The size is 101 KB of source — the auto-generated All of Us SQL runs to ~6 KB
  per cell — plus JSON overhead. A whole risk was inferred from a mis-read file size.
- **What the audit did find:** hardcoded workspace identifiers (A-014) → T-013, Q-R3. Also confirmed:
  no API keys or secrets, and no participant counts reported in markdown.
- **See:** `JOURNAL.md` 2026-07-14; A-012; A-014.
