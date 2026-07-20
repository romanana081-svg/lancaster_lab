# Workbench reconciliation — the fixture vs. the real CDR

**The question this answers:** the fixture data is invented. When the PREVENT queries run in All of Us,
how do I tell what is actually working, and how do I keep the offline fixture honest as I learn?

---

## The one thing to internalize first

**The fixture does not reproduce All of Us's *data*. It reproduces its *structure*.**

Every number in the fixture is made up — the 184 eligible participants, the 3 complete panels, the
specific creatinine values. **Those will not match the real CDR and are not supposed to.** What must
match is the *shape*:

- which **column** an ICD code lives on (`condition_source_concept_id`, not `condition_concept_id`),
- the **`vocabulary_id`** a code carries (`LOINC`, `ICD10CM`, `RxNorm`),
- the **`cb_criteria` hierarchy** mechanics the notebook's generated SQL walks,
- the **`value_as_number` NULL** pattern (a censored lab is a row that looks like data and is useless
  as data).

The fixture's whole job is to let the *same SQL* run unchanged offline and in the Workbench (D-003). It
is a **hypothesis about the CDR's structure**; running in All of Us is the experiment that tests it.
Only the Workbench produces real numbers.

---

## Three layers where fixture and reality can diverge — and how each announces itself

| # | Layer | The question | Instrument | Fixture says | A real-CDR mismatch looks like |
|---|---|---|---|---|---|
| 1 | **Vocabulary** | does the code resolve at all? | `01` section A | all 7 resolve (they were seeded) | a row reads **`DOES NOT RESOLVE`** |
| 2 | **Coverage** | is there real data behind the code? | `01` section B, `02` | tiny invented counts | `n_people` is 0 or implausibly small |
| 3 | **Structure** | does the CDR behave like the fixture? | `01` section C (the linkage probe) | ICD on the *source* column | §C shows ICD on a different column, or a unit string differs |

**Why `01` runs before `02`, and why this is the whole point:** a code that **does not resolve** and a
code that resolves **but has no data** produce the *identical* symptom in `02` — "0% coverage." From the
completeness numbers alone you cannot tell "your code is wrong" from "the data isn't there." Query `01`
is the only thing that tells them apart. Run it first, every time, and never trust a `02` count for an
input whose `01` row is not `ok`.

---

## Run order in the Workbench

**The quick path:** the notebook `LDLR Get phenotypes.ipynb` now has a **"PREVENT panel reconciliation
— run this first"** cell immediately after `# Setup`. Run it and it prints all three checks below
(resolution table with a `resolves` PASS/FAIL column, the ICD linkage check, and the completeness
counts) in one go. The manual equivalent, if you want to run the pieces yourself:

```r
source("src/phenotype/R/run_sql.R")

# 1. Vocabulary check. RUN THIS FIRST. Copy the resolution_status column into the log below.
d01 <- run_sql_file("sql/01_prevent_concept_discovery.sql")   # section A only
print(d01)

# 2. Feasibility counts (the headline).
d02 <- run_sql_file("sql/02_prevent_panel_completeness.sql")  # section A only
print(d02)
```

**`run_sql_file()` executes only the FIRST statement of a file.** Sections B, C and D in each `.sql`
are commented-out follow-ups — the coverage counts (`01`§B), the linkage-trap probe (`01`§C), the
bottleneck / attrition / age-distribution tables (`02`§B–D). To run one, uncomment it (or paste it into
a notebook cell) and run it on its own. **Do run `01`§C at least once** — it *proves* which column ICD
codes live on in the real CDR, rather than trusting the comment.

---

## What is safe to bring out of the Workbench, and what is not (H-006)

- ✅ **Safe:** query `01`'s resolution output — `code → concept_id → concept_name → resolves?`. This is
  vocabulary *metadata*, not participant data.
- ⚠️ **Not without small-cell suppression:** query `02`'s **counts**, and *especially* the section C
  demographic breakdown. All of Us policy requires suppressing (dropping or rounding) any aggregate cell
  below the threshold **before it leaves the Workbench**. When in doubt, bring back only the resolution
  table and the top-line `n_eligible` / `n_complete_panel` — not per-stratum counts.

---

## The reconciliation log — fill this in the first time you run in All of Us

Fixture column is what we assert offline today. Leave the real-CDR columns blank until you have run it;
then the gap between the two columns is *the finding*.

| PREVENT input | Code (vocab) | Fixture: resolves? | **Real CDR: resolves?** | **Real CDR: n_people** (suppressed) | Verdict | Action if mismatch |
|---|---|:---:|:---:|:---:|---|---|
| total cholesterol | `2093-3` (LOINC) | ✅ | | | | |
| HDL-C | `2085-9` (LOINC) | ✅ | | | | |
| systolic BP | `8480-6` (LOINC) | ✅ | | | | also check *physical measurements*, not only LOINC |
| serum creatinine | `2160-0` (LOINC) | ✅ | | | | confirm the unit is `mg/dL` |
| BMI | `39156-5` (LOINC) | ✅ | | | | |
| HbA1c | `4548-4` (LOINC) | ✅ | | | | AoU may use `17856-6` instead, or both |
| HbA1c | `17856-6` (LOINC) | ✅ | | | | |
| diabetes (dx code) | `E08–E11, E13` (ICD10CM) | ✅ | | | | on `condition_source_concept_id` |
| **complete panel** | (intersection) | 3 | | | | this is the sample size (A-016) |
| antihypertensive | — | *illustrative only* | | | | needs the real ingredient list (Q, `prevent_concepts.yaml`) |
| current smoking | — | *illustrative only* | | | | survey mapping still open |

---

## When reality differs — the update loop (how you keep the fixture honest)

The fixture is a guess about the CDR's structure; the Workbench is the test. **When the test fails,
update in this order so the offline tests come to reflect what you actually learned:**

1. **`configs/prevent_concepts.yaml`** — the single source of truth for the codes. If AoU stores
   creatinine under a different LOINC, or only one HbA1c code populates, change it *here first*.
2. **`sql/01` and `sql/02`** — update the `wanted` list and the `has_*` CTEs to match.
3. **`fixture/build/generate.py`** — re-seed the fixture's `concept` rows to **mirror the real
   vocabulary**, so the offline fixture now encodes reality rather than the July guess. Then rebuild and
   re-test:
   ```
   python fixture/build/generate.py && python fixture/build/export.py && python fixture/build/verify.py
   Rscript -e "testthat::test_dir('tests/testthat')"
   ```
   (interpreter paths: `docs/environment.md`).
4. **Write it down** — `JOURNAL.md` for *what the real CDR actually did*, and `ASSUMPTIONS.md` if it is a
   lasting structural fact (e.g. "AoU populates only `17856-6` for HbA1c"). A divergence discovered and
   not recorded gets rediscovered at the cost of an afternoon.

**The invariant:** after any reconciliation, a green offline test should mean *"consistent with what the
real CDR does,"* not *"consistent with what I guessed before I had access."* That is what keeps the
fixture worth trusting.

---

## Things most likely to differ (so you are not surprised)

- **HbA1c** — two candidate LOINCs are seeded; AoU may populate one, both, or neither.
- **Systolic BP** — AoU also carries BP in *physical measurements*, not only as a LOINC `measurement`.
  A participant can have a BP this query misses entirely. Check both sources before concluding "no SBP."
- **Creatinine unit** — assumed `mg/dL`; confirm. eGFR is *derived* from it (CKD-EPI 2021, race-free),
  it is not itself a PREVENT input.
- **Diabetes** — code vs. HbA1c ≥ 6.5% vs. glucose-lowering drug identify **different people**. Query
  `02` uses the diagnosis code only; that is a choice, not the truth.
- **Antihypertensive use & current smoking** — **not yet** in `02`'s complete-panel flag, and only
  *illustrative* in the fixture. Expect to build these against the real drug hierarchy and survey, and
  note (A-015) that a rich-EHR participant with no completed survey has *no* smoking status and is
  therefore **excluded** under complete-case — possibly the single biggest driver of exclusion.

**See:** `sql/01_prevent_concept_discovery.sql`, `sql/02_prevent_panel_completeness.sql`,
`configs/prevent_concepts.yaml`, `handoff.md` H-004 / H-006, TASKS T-017 / T-003, A-015 / A-016.
