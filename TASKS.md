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

## Now

### T-013 — Decide what to do about the hardcoded workspace identifiers
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** Q-R3 (a decision) · **Blocks:** a public push
- **Why:** T-012 cleared the participant-data risk (A-012) but found a smaller one (A-014): the
  workspace bucket UUID and a named researcher's email are hardcoded in 13 notebook cells **and**
  replicated as ~24 tracked directory names under `fixture/bucket/`. Not a data-policy breach; still
  not something to publish for no reason.
- **Done when:** Q-R3 is decided and recorded as a D-entry, and — if the decision is to scrub — the
  notebook, the fixture, and the answer key are changed **together** and `verify.py` is still green.
- **Notes:** the fix is entangled, which is exactly why it is a decision and not a chore. The notebook
  resolves those `gs://` paths as literals and the fixture mirrors them so the notebook runs unmodified
  offline. Changing one without the other breaks the offline harness. Scrubbing the working tree also
  does **not** scrub git history.

### T-002 — Cohort construction and the attrition flowchart
- **Status:** BLOCKED · **Priority:** P0 · **Blocked by:** Q-S1 (index date), Q-A1 (outcome), Q-A2
  (EHR density) · **Blocks:** T-003, T-007, T-009
- **Why:** Stage 1 of DESIGN §5. Every downstream number is conditioned on who is in the cohort. Doing
  this before the three questions above are settled means doing it twice — and worse, it means the
  second version is chosen with knowledge of what the first one produced.
- **Done when:** a reproducible cohort table exists (srWGS, age 30–79 at index, no prior ASCVD,
  PREVENT inputs available), together with an attrition flowchart that accounts for **every** excluded
  person, and the counts are reproduced by a test on `fixture/`.
- **Notes:** the prevalent-vs-incident exclusion is the one that silently inflates apparent accuracy if
  botched (DESIGN §2). The notebook's `# Get censored ages` section is the existing machinery for it.

---

## Next — the phenotype pipeline

### T-003 — Extract the PREVENT input phenotypes
- **Status:** TODO · **Priority:** P1 · **Depends on:** T-002 (index date) · **Blocks:** T-006, T-007
- **Why:** **The single largest implementation gap in the project.** PREVENT needs total cholesterol,
  HDL-C, systolic BP, antihypertensive use, diabetes, current smoking, eGFR, BMI, age, and sex
  (D-004). The existing notebook extracts **only BMI** of these — it was built for an LDLR study and
  pulls LDL, triglycerides, and CAD codes, none of which PREVENT takes as input. Without this task
  there is no baseline model, and without a baseline there is no study.
- **Done when:** each PREVENT input is extracted, unit-harmonised, bounded, and lands in
  `phenotypes_v<N>.parquet` conforming to `configs/phenotype_schema.json`; a missingness report exists
  for each; and the fixture covers every new domain (T-004).
- **Notes — two inherited assumptions must be revisited here, not inherited silently:**
  - **A-001 (earliest-value-wins) is probably wrong for this study.** For a *prediction* model the
    correct anchor is the value **at the index date**, not the earliest value ever recorded. The
    notebook's `filter(date == min(date))` idiom must not be copied over without thought.
  - **A-004's LDL `< 400` cap deletes exactly the people we care about.** Untreated FH carriers
    routinely exceed 400 mg/dL. Applying this bound to a rare-variant study would systematically
    remove the strongest carriers. Revisit the bound; do not port it.

### T-004 — Extend the fixture to cover the new domains
- **Status:** TODO · **Priority:** P1 · **Depends on:** T-003 · **Paired with:** T-003, always
- **Why:** D-003 makes `fixture/` the offline substrate, and it only stays useful if it grows with the
  pipeline. A new domain with no fixture coverage means the fixture *silently stops testing* the thing
  we just wrote — the tests still pass, and they now mean less than they did.
- **Done when:** every domain added by T-003 has (a) seeded `cb_criteria` vocabulary so the generated
  SQL returns rows, (b) at least one deliberately dirty record exercising the relevant defect class,
  and (c) a named participant in `expected/answer_key.csv`. `verify.py` stays green.
- **Notes:** extend, never regenerate blindly — participants `1000001`–`1000027` are hand-authored and
  the answer key depends on them (`fixture/README.md`).

### T-005 — Refactor the notebook's R logic into a tested `src/phenotype/` package
- **Status:** TODO · **Priority:** P1 · **Depends on:** —
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

### T-006 — Implement PREVENT in Python and validate it against the published values
- **Status:** TODO · **Priority:** P1 · **Depends on:** T-003 · **Blocks:** T-007, T-009
- **Why:** PREVENT is the baseline (D-004) and its linear predictor is the offset in the primary model
  (D-006). If the implementation is subtly wrong, **every result in the project is wrong**, and wrong
  in a way that no amount of downstream statistical care can detect.
- **Done when:** `src/aou_ascvd/prevent/` reproduces the **published example risk values from Khan et
  al. (2024) to within rounding** — this is the validation-tier test in DESIGN §7, and it is pass/fail.
  Sex-specific coefficients, the 10-year and 30-year equations, and the input units (mg/dL vs mmol/L,
  the classic trap) are all covered by unit tests.
- **Notes:** transcribing published coefficients is exactly the kind of task that *feels* trivial and
  produces silent errors. Type them once, test them against the paper's worked examples, never trust
  them until that test passes.

### T-007 — Validate PREVENT's performance *in All of Us*
- **Status:** TODO · **Priority:** P1 · **Depends on:** T-002, T-006 · **Blocks:** T-009
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

### T-008 — Build the rare-variant feature pipeline
- **Status:** BLOCKED · **Priority:** P1 · **Blocked by:** Q-G1 (gene set), Q-G2 (MAF/mask), Q-G3
  (offline substrate), Q-S4 (power) · **Blocks:** T-009
- **Why:** Produces the `G` term — the exposure. Stage 6 of DESIGN §5.
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
