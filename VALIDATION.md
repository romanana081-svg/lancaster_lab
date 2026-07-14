# VALIDATION.md

**How we know each step actually worked.**

Validation is a deliverable, not a chore (DESIGN §7). The reason is specific to this kind of project:
an epidemiological pipeline almost never fails loudly. It fails by producing *a number* — plausible,
well-formatted, and wrong. A unit conversion, a join that duplicates rows, a filter that quietly drops
the very people the study is about: none of these raise an exception. The only defence is to state, in
advance, what "correct" would look like, and then check.

**The rule: a task is not complete until its validation passes. No exceptions.**

---

## 1. The four layers

| Layer | Question it answers | Where it lives | When it runs |
|---|---|---|---|
| **1. Unit** | Does this function do what it claims, on a tiny input with a known answer? | `tests/testthat/` | every change |
| **2. Integration** | Does the pipeline run end-to-end and produce the expected table? | `fixture/build/verify.py`, `tests/testthat/` | every change |
| **3. Validation (scientific ground truth)** | Does the code reproduce an **externally known** answer? | `tests/testthat/` (PREVENT vs. the published values) | every change to the model code |
| **4. Data quality** | Is the *data* the pipeline produced sane? | `reports/quality/` (T-011) | every time a dataset is produced |

*(All R since D-011. `pytest` is gone; the only Python left is the fixture builder, which is tooling.)*

Layers 1 and 2 test the **code**. Layer 3 tests whether the code implements the **science**. Layer 4
tests the **data**. All four are necessary and none substitutes for another — code can be perfectly
tested and still implement the wrong equation, and a correct equation can be fed garbage.

### Layer 3 is the one people skip

It is the one that matters most. A unit test written by the same person who wrote the bug will happily
assert the bug. External ground truth cannot be argued with:

> **PREVENT must reproduce the published example risk values from Khan et al. (2024) to within
> rounding. If it cannot, the implementation is wrong — no matter how clean the code is, and no matter
> how well it passes its own unit tests.**

That test is the gate on T-006, and by extension on every result in the project.

---

## 2. Current state — what is actually verified today

Honest inventory, 2026-07-13.

| Component | Status | Evidence |
|---|---|---|
| Synthetic CDR fixture | ✅ **GREEN** | `26 pass, 1 reproduced-bug (expected), 0 unexpected failure(s)` |
| The notebook's 13 generated SQL queries | ✅ run, all return rows | `fixture/build/export.py` runs them **verbatim** |
| The R cleaning pipeline's behaviour | ✅ characterised (incl. its bugs) | `fixture/expected/answer_key.csv`, 27 scenario participants |
| R available locally (4.6.0, tidyverse, testthat, DBI, **duckdb**, **arrow**) | ✅ confirmed 2026-07-14 | H-001 resolved. `duckdb`+`arrow` installed 2026-07-14 — **R can now read the fixture and write the Parquet contract** |
| Python available locally (3.13.7, duckdb) | ✅ confirmed 2026-07-13 | fixture builder only; not on `PATH` |
| Cleaning idiom (`clean_measurement`, `clean_codes`) | ✅ **59 testthat tests pass** | T-005 |
| Concept dictionary (`resolve_concepts`) | ✅ tested **against the real fixture DuckDB** | T-014, D-014 |
| **Fixture coverage of the PREVENT panel** | ❌ **ALMOST NONE** | LDL/trig/BMI only; **no SBP, creatinine, HbA1c, smoking, or antihypertensives**. Blocks offline testing of the PREVENT extractor → **T-004** |
| PREVENT implementation | ⛔ **does not exist** | T-016 (R, not Python — D-011) |
| Phenotype schema contract | ⛔ **does not exist** | §3 below, T-003 |
| Genetic pipeline | ⛔ **does not exist**, and has **no offline substrate** | T-008, Q-G3 |
| Notebook free of controlled-tier data | ✅ **VERIFIED** 2026-07-14 | T-012: **0 outputs** in 291 code cells, in the working tree *and* all history |
| Notebook free of workspace identifiers | ❌ **REFUTED** | A-014: bucket UUID + owner email in 13 cells; → Q-R3, T-013 |

**Reproduce the green check:**

```bash
python fixture/build/generate.py   # rebuild the DuckDB CDR + answer key
python fixture/build/export.py     # run the 13 queries -> sharded CSV exports
python fixture/build/verify.py     # replay the R cleaning logic, diff vs answer key
```

`verify.py` exits non-zero on any *unexpected* mismatch, so it is usable as a CI gate as-is.

### What "1 reproduced-bug (expected)" means, and why it is not swept under the rug

One assertion in the answer key documents a **known defect that we have deliberately not fixed**: the
`any_chol_med` collapse marks survey respondents who answered *"No"* as **1** (participant `1000014`).
`meds_df` contains everyone who *answered* the statin survey; the collapse is
`pheno_df2$any_chol_med[!is.na(...)] <- 1`, and the string `'no'` is not `NA`, so a non-user becomes a
user. It cascades — their survey date becomes `any_chol_med_start_date`, which flips
`LDL_measured_on_meds` from `NA` to `1`.

The fixture asserts the **buggy** behaviour on purpose. That way the bug cannot be fixed *by accident*
and, more importantly, it cannot be *reintroduced* silently: when T-005 fixes it, this assertion
flips and the change is visible in the diff. A test that encodes a known bug is a test that turns
"we know about this" into something a machine enforces.

Similarly, A-002's non-determinism is asserted as **membership** (`one_of:130|131|132`), not as a
value — because the underlying SQL has no `ORDER BY` and the surviving row is genuinely arbitrary. The
answer key refuses to pretend otherwise. Fix that in T-005 and the assertion tightens to a single value.

---

## 3. The R → Python contract (D-005)

The two halves of the project meet at exactly one artifact, and this section is that artifact's
specification. Everything about it is designed so that a mistake becomes a **crash**, not a wrong
number.

```
   R half (src/phenotype)  ──write──►  phenotypes_v<N>.parquet  ──read──►  Python half (src/aou_ascvd)
                                       configs/phenotype_schema.json
                                  validated on BOTH sides, hard-fail
```

**The rules:**

1. **One row per `person_id`.** Enforced, not hoped for. The fixture proves this can break: a
   duplicated `person` row (participant `1000026`, defect A4) multiplies rows across the entire join.
   A duplicate-key check is therefore mandatory on write **and** on read.
2. **Every column declares its type, unit, and permitted range** in `configs/phenotype_schema.json`.
   Units are part of the type. `total_cholesterol_mgdl` is a different thing from
   `total_cholesterol_mmoll`, and the schema is where that is stated once, unambiguously.
3. **Validation fails hard.** A schema violation raises. It is never a warning, never a coerced value,
   never a silently-dropped row. The entire point of the contract is to convert silent corruption into
   a loud stop.
4. **Files are immutable and versioned.** `phenotypes_v2.parquet` never overwrites
   `phenotypes_v1.parquet`. A result produced last month must remain reproducible next month, and that
   is impossible if its inputs can be rewritten under it.
5. **The schema is the source of truth for both languages.** Neither side hard-codes a column list.
   When a phenotype is added (T-003), the schema changes first, and both sides fail loudly until they
   agree with it.

**What validation must check on every read and every write:**

| Check | Why — the failure it catches |
|---|---|
| Column set matches the schema exactly | a silently renamed or dropped column |
| Types match | an integer that became a string on a CSV round-trip |
| `person_id` unique and non-null | the duplicate-person join blow-up (A4); the NULL `person_id` (A5) |
| Values within declared physiologic range | unit drift (mg/dL vs mmol/L), data-entry errors |
| Units column matches the declared unit | the mistake that silently rescales a whole variable |
| Non-negative ages, dates ordered sensibly | DOB after events (participant `1000023`, defect A3) |
| Missingness reported per column, never imputed at this boundary | imputation is an *analysis* decision (and an assumption) — it does not belong in a transport layer |

Every one of these corresponds to a defect **that is present in the fixture right now**. This table is
not defensive theatre; it is a list of things that have already been observed to happen.

---

## 4. Per-task validation contracts

The "Done when" in [`TASKS.md`](TASKS.md) is binding. Restated here as checkable criteria:

| Task | Validation that must pass |
|---|---|
| **T-002** cohort | Attrition flowchart accounts for **every** excluded person (counts sum to N). Zero prevalent-ASCVD cases remain in a primary-prevention cohort. Reproduced on `fixture/`. |
| **T-003** PREVENT phenotypes | Each input present, unit-harmonised, bounded; missingness reported; schema (§3) validates; fixture covers each new domain (T-004). |
| **T-004** fixture extension | `verify.py` green; each new domain has seeded vocabulary, a dirty record, and an answer-key participant. |
| **T-005** R package | `testthat` green; end-to-end fixture test green; **tie-break deterministic** — the `one_of:` assertion in the answer key becomes a single value (A-002). |
| **T-006** PREVENT | **Reproduces Khan et al.'s published example values to within rounding.** Sex-specific equations, 10y and 30y, unit handling all unit-tested. Pass/fail; no partial credit. |
| **T-007** baseline | C-index and calibration reported overall **and by sex and genetic ancestry**. Q-S2 answered from this evidence *before* any genetic term is fitted. |
| **T-008** genetics | **Positive control: `LDLR` burden associates with LDL cholesterol** (A-009). If it does not, the pipeline is broken and nothing downstream is trustworthy. |
| **T-009** primary result | Negative control (Q-S2) run; proportional hazards checked (Q-S5); CI reported, not just a p-value; pre-specification of Q-G1/Q-G2/Q-S3 demonstrably predates the fit. |
| **T-011** quality report | Runs automatically as part of the ETL, not on request. |
| **T-012** governance | Every notebook output cell read and classified; A-012 moves off UNVERIFIED. |

---

## 5. Negative and positive controls

Two controls carry more weight than any test suite, because they can detect a pipeline that is
*coherently* wrong — the failure mode that unit tests cannot see.

**Positive control (does the pipeline detect a signal that is definitely there?)**
Rare-variant burden in `LDLR` **must** associate with LDL cholesterol. This is settled biology; it is
the reason the gene is named what it is. If our pipeline cannot recover it, the pipeline is broken.
Gate on T-008. Q-G3 proposes planting exactly this signal in a synthetic variant fixture so the control
can be run **offline, before touching real data** — turning a hope into a test.

**Negative control (does the pipeline invent a signal that is not there?)**
Put a genetically null term — burden in a gene with no plausible lipid or CAD role — into the offset
model M1. It **must not** come out significant. If it does, the offset is absorbing PREVENT's
calibration error rather than measuring residual genetic risk (A-008, Q-S2), and the primary analysis
as specified is unusable.

These two controls are, between them, the strongest evidence the project can produce that its result —
positive *or* negative — means what it says.

---

## 6. What validation cannot do

Stated plainly, because a green test suite is seductive:

- **The fixture can prove the code is broken; it cannot prove the code is correct on real data**
  (A-013). It reproduces the *structure* and the known *defect classes* of the CDR — not its
  distributions, and 300 people rather than 245,000. It catches structural and logical bugs. It is
  blind to distributional ones.
- **No test can detect a wrong assumption**, only a violated one. If A-001 (earliest-value-wins) is the
  wrong anchor for a prediction study — and it probably is (T-003) — every test still passes. That is
  what [`ASSUMPTIONS.md`](ASSUMPTIONS.md) is for: assumptions are attacked by *review*, not by CI.
- **Statistical validity is not a unit test.** Immortal time bias (Q-S1) produces a beautifully
  calibrated, fully reproducible, entirely wrong answer. The guard is study design, and design is
  guarded by humans (H-003).

The tests protect against the mistakes we can automate. The documents protect against the ones we
cannot — which are the more dangerous of the two.
