# JOURNAL.md

A chronological log of work sessions. **Newest first.**

This is the project's narrative memory: not *what the code does* (that is `DESIGN.md`) and not *why we
chose it* (that is `DECISIONS.md`), but **what actually happened, what we learned, and what surprised
us**. The surprises are the valuable part. In six months, the question "why did we stop trusting the
earliest-value rule?" is answered here.

Write an entry when a session ends, not when it succeeds. Failed attempts and dead ends are recorded —
a dead end that is not written down gets explored twice.

**Template**

```
## YYYY-MM-DD — <session title>
**Did:**       what changed, concretely
**Learned:**   what we now know that we did not before — especially anything surprising
**Decided:**   any D-entries created (link them)
**Next:**      the state the next session starts from
```

---

## 2026-07-14 (advisor meeting) — The project turns: all R, cohort and outcome settled

**Did:** Rewrote the project's spine around the advisor's decisions, and started this week's code.

**Decided (four new D-entries, two supersessions):**

- **D-011 — the project is ALL R.** D-002 had split it in two, and the *entire* justification for the
  Python half was that PREVENT's reference implementation and the good survival tooling lived there.
  **That premise was false — the equations are available in R.** Once the benefit evaporated, the split
  was paying two toolchains, two test frameworks, and a serialisation boundary for nothing. Reversed.
  `src/aou_ascvd/` (Python) was deleted before a line of it was ever written; `src/ascvd/` (R) replaces
  it. *The fixture builder stays Python* — it is test tooling, not analysis, and rewriting a working
  harness is risk with no scientific payoff, which is the same argument D-002 originally made for
  keeping the R ETL.
- **D-012 — the phenotype table stays versioned, schema-validated, and immutable**, now within R.
  Worth being deliberate about: it would have been easy to drop the schema along with the language
  boundary it was written for. But **none of those protections were ever about Python.** A schema is
  what turns a renamed column or an mg/dL→mmol/L drift into a crash instead of a quietly wrong number,
  and that is just as necessary inside one language.
- **D-013 — cohort:** age ≥ 30, **complete PREVENT panel required** (excluded, not imputed), no prior
  ASCVD. Covariates from before the event; stratify on the event.
- **D-014 — outcome:** ASCVD from **both** ICD and CPT codes, with concept IDs **resolved through the
  All of Us vocabulary** so that event timing and disease type/stage can be read off them.

**Built:** `concept_dictionary.R` (T-014) — `resolve_concepts()` turns concept IDs into codes and
meanings, and **an unresolvable ID is a hard error**. That matters more than it sounds: a stale concept
ID returns **zero rows with no error**, so the phenotype quietly empties and the number at the end of
the pipeline is wrong but plausible. Plus `configs/ascvd_codes.yaml` — the outcome definition written
so a human can *read* it, with acute events, chronic disease, and revascularisation kept apart.
**59 testthat tests pass**, including tests that run against the real fixture DuckDB.

**Learned — three things, and two of them are problems:**

1. **The fixture contains almost none of the PREVENT panel.** Counted it: LDL (278 rows),
   triglycerides (202), BMI (170), and exactly **one** HDL row and **one** total-cholesterol row.
   **No systolic BP, no serum creatinine, no HbA1c, no smoking, no antihypertensives.** So "test the
   PREVENT extractor offline" is currently impossible — there is nothing to extract. T-004 is promoted
   from housekeeping to a **hard prerequisite** for this week's goal.
2. **R could not read the fixture at all** — the `duckdb` R driver was not installed. Installed it (and
   `arrow`, which D-012's Parquet contract needs). Both were silently blocking, and neither was in any
   document.
3. **D-013 opens a hole that the advisor's phrasing hides — Q-S6 (🔴).** "Use data from before the
   event" defines a baseline for people who *have* an event. **Most participants never have one**, so
   for them it defines nothing. If cases end up anchored just before their event while non-cases are
   anchored at, say, their first complete panel, then cases' risk factors get measured *closer to their
   disease* — and **every predictor looks stronger than it is, with no bug appearing anywhere.** This
   is the immortal-time problem wearing a different hat. It needs five minutes with the advisor and it
   changes the ETL, so it is asked now rather than discovered in the results.

**Also flagged (A-015, 🔴):** the complete-panel requirement is **not a neutral filter**. Having
lipids *and* a BP *and* a creatinine *and* a smoking status on file is a marker of sustained healthcare
contact — so the excluded skew toward sparse-EHR participants, which tracks access, socioeconomic
status, and ancestry. In a study whose whole point is genetics in a deliberately diverse cohort, that
means **cohort membership is entangled with ancestry**, which is a route to a spurious genetic finding
(A-011). It is measurable, and the attrition table in T-002 must measure it — before the PRS work
starts.

**Next:** T-017 (count PREVENT panel completeness in the real CDR — one query, and it decides whether
the design is even feasible), then T-015 (ASCVD events), T-003 (the PREVENT extractor), T-004 (fixture).

---

## 2026-07-14 (later) — Two decisions taken; the tie-break is fixed

**Did:** Put the two open decisions to the user and implemented both.

- **D-009 — same-day duplicates are resolved by their MEAN.** This retires A-002, which was the
  project's only outright *reproducibility* defect: the notebook's `distinct(person_id, .keep_all=T)`
  over SQL with no `ORDER BY` kept an arbitrary row, so the LDL that reached the analysis for anyone
  with same-day repeats could differ **between runs of the same code**. `clean_measurement()` now
  defaults to `mean` and a test pins that default, so the arbitrary behaviour cannot creep back.
  Min and max were rejected for a reason worth remembering: both impose a *systematic directional
  bias* on the study's key exposure, and `min` would attenuate precisely the FH signal the study is
  built to detect.
- **D-010 — the hardcoded workspace identifiers stay.** Accepted as a limitation rather than fixed:
  it is a low-severity disclosure (no participant data; the bucket is access-controlled), and removing
  it would mean modifying a notebook the lab treats as validated *and* rebuilding the offline harness
  everything else is tested against.

**Learned / worth flagging:** the fixture's answer key still asserts `one_of:130|131|132` for
participant `1000006`, and **that is still correct** — the *notebook* has not switched over to the
package, so it still does the arbitrary thing. The temptation is to "update the test to match the new
behaviour"; doing that now would assert a behaviour nothing in the pipeline actually has. The assertion
tightens to `131` **when the ETL switches**, not when the function does. Recorded in D-009 and A-002 so
the next session does not get it backwards.

Also noted, because it will bite at T-003: **R's `arrow` package is not installed**, and D-005's
contract is a *Parquet* file. CSV is not an acceptable fallback — D-005 rejects it precisely because it
has no types.

**Decided:** D-009, D-010. Q-R3 resolved, T-013 closed, A-002 resolved, A-014 accepted-as-limitation.

**Next:** T-005's remaining domains (conditions, drugs, survey, demographics, censoring) and its
end-to-end fixture test. The analysis path is still gated on H-003.

---

## 2026-07-14 — T-012: the governance audit, and a risk that never existed

**Did:** Ran T-012 — the P0 governance audit. Parsed `LDLR Get phenotypes.ipynb` as JSON rather than
reading it by eye, checked **every version of it in git history**, and scanned the source for
identifiers, secrets, and reported counts.

**Learned — the headline finding is a negative one, and it retires the project's biggest blocker:**

**The notebook has no cell outputs. It never did.** All 291 code cells carry `outputs: []` and
`execution_count: null`, in the working tree *and* in both historical commits (`41791cc`, `832f3e2`).
Zero output bytes have ever entered this repository. A-012 is verified — vacuously — and H-006's
blocking form is answered: **we are not carrying controlled-tier participant data.**

**The interesting part is where the belief came from.** CLAUDE.md states, as fact, that the notebook is
committed *with* outputs "which is why it is ~180 KB". That inference is backwards. The file is 101 KB
of **source** — the auto-generated All of Us SQL strings are ~6 KB *per cell* — plus JSON overhead. A
plausible explanation for a file size was written down as a fact, that fact became A-012 (🔴, "the
highest-urgency non-scientific item in the project"), and it propagated into `handoff.md`, `README.md`,
and the `.gitignore` rationale. Nobody had opened the JSON. **The lesson is not "CLAUDE.md was wrong" —
it is that a documentation system this dense will faithfully propagate an unchecked premise into five
files, and only a mechanical check dislodges it.** Corrected at the source in CLAUDE.md, so future
sessions do not re-inherit it.

**What the audit *did* find (A-014, new):** the notebook hardcodes the workspace bucket UUID and the
owner's institutional email —
`gs://fc-secure-7e84f6f0-…/bq_exports/megan.lancaster@researchallofus.org/…` — in 13 cells, and the
fixture **mirrors those literals as ~24 tracked directory names**. This is information disclosure, not
a data-policy breach: no participant data, and the bucket is access-controlled. But it is an internal
identifier and a colleague's email, in a repo we intend to make public, for no benefit.

The fix is **entangled**, which is why it became a question (Q-R3) and not a chore: the "Format" cells
resolve those `gs://` paths as *literals*, and the fixture was deliberately built to mirror them so the
notebook runs unmodified offline. Notebook, fixture, and answer key have to move together or the
offline harness breaks — and scrubbing the working tree does nothing about git history.

Also confirmed clean: no API keys or secrets anywhere in the notebook, and no participant counts
reported in any markdown cell.

**Decided:** no new D-entries. Q-R2 is **resolved** (answer: nothing needs stripping). Q-R3 is raised
and needs a human. H-006 downgraded 🔴 → 🟠. A-012 verified; A-014 opened.

**Next:** the governance path is clear until someone answers Q-R3. The analysis path is still gated on
H-003 (advisor: outcome definition + index date). The largest genuinely-unblocked task is T-005 —
lifting the notebook's R cleaning logic into a tested `src/phenotype/` package, which is now possible
locally because R turned out to be installed after all.

---

## 2026-07-13 — Completing the documentation scaffold; two environment findings

**Did:**
- Wrote the six documents that `DESIGN.md`, `DECISIONS.md`, and `ASSUMPTIONS.md` had been
  cross-referencing but which did not exist: `QUESTIONS.md`, `TASKS.md`, `VALIDATION.md`,
  `handoff.md`, this file, and `loop.md`. Every `T-`, `Q-`, and `H-` identifier already cited in the
  earlier documents now resolves to a real entry — a dangling cross-reference is a genuine defect in a
  system whose entire purpose is memory.
- Created the `configs/`, `sql/`, `src/`, `tests/`, `docs/`, `notebooks/`, `reports/`, and `data/`
  skeleton from DESIGN §3.3, with `config.yaml` holding the parameters that are currently hard-coded
  in the notebook.
- Fixed `.gitignore`, which contained the line `.gitignore` — **it ignored itself**, so it would never
  have reached a clean clone, and neither would the protections it encodes. D-001 called for this; it
  had not actually been done.
- Ran the fixture end-to-end: **green** — `26 pass, 1 reproduced-bug (expected), 0 unexpected
  failure(s)`, matching what `fixture/README.md` documents.

**Learned — two things about the machine, both of which change a written record:**

1. **R is installed.** D-002 states, as a recorded cost of the bilingual decision, that "R is not
   currently installed on the development machine — nothing R-based can be tested locally until it is",
   and `handoff.md` H-001 existed to track that. **This is false.** R 4.6.0 and 4.3.2 are both present
   under `C:\Program Files\R\`, and **`tidyverse` is installed**. R is simply not on `PATH`, which is
   what made it look absent. `bigrquery` is genuinely missing, but it is only needed for the "Do once"
   BigQuery cells, which run inside the Workbench anyway — so it does not block offline work.

   The consequence is not cosmetic: the R half of the pipeline is **testable locally right now**, which
   is the precondition for T-005 (lifting the notebook's cleaning logic into a tested `src/phenotype/`
   package). A blocker that was written down as real turned out to be a `PATH` entry. H-001 is closed
   and D-002's stated cost has been annotated rather than rewritten.

2. **Python is also not on `PATH`** (3.13.7 lives under `%LOCALAPPDATA%\Programs\Python\`, with
   `duckdb` available). The fixture's documented commands (`py fixture/build/...`) therefore do not run
   as written in a fresh shell. Recorded in `docs/environment.md` with the working invocations, because
   an environment quirk that is not written down is rediscovered by the next person at the cost of an
   afternoon.

**Also learned, from reading the fixture's own evidence:** the fixture is doing more work than a test
suite usually does. It does not merely check the pipeline — it **encodes two known bugs as assertions**
so they cannot be fixed by accident or reintroduced silently: the `any_chol_med` survey-non-user defect
(participant `1000014`, who says "No" to statins and is scored as a user), and the non-deterministic
same-day tie-break (asserted as `one_of:130|131|132`, because the generated SQL has no `ORDER BY` and
the surviving row is genuinely arbitrary). That is why the expected result is "1 reproduced-bug", not
"27 pass". Both are now carried forward as completion criteria on T-005.

**Decided:** no new `D-` entries. D-002 gains a dated correction on the R-availability point; the
decision itself is unchanged and, per the append-only rule, nothing was deleted.

**Next:** T-012 (audit the notebook's committed outputs for controlled-tier data) is the P0 item — it
needs no human, no credentials, and no unresolved question, and it gates any push to a non-private
remote. Everything on the analysis path runs through T-002, which is blocked on H-003: an advisor must
settle the outcome definition (Q-A1) and the index date (Q-S1). The most useful preparation for that
conversation is to **bring numbers** — the eligible-N, event count, and missingness under each candidate
definition — rather than only questions.

---

## 2026-07-12 — The synthetic CDR fixture *(recorded retroactively)*

**Did:** Built `fixture/` — a DuckDB stand-in for the All of Us OMOP CDR (spec in `FORMAT.md`): 300
participants, 191 in the srWGS cohort, 27 hand-authored scenario participants, a deliberately dirty
dataset, and an answer key. `export.py` runs the **13 SQL queries lifted verbatim from the notebook**,
and a `gsutil` shim lets the notebook's own reader work unmodified against a fake bucket.

**Learned:** Running the notebook's real SQL — rather than paraphrasing it — was the decision that paid
off, and it paid off twice:

- **`any_chol_med` is wrong for survey non-users.** `meds_df` includes everyone who *answered* the
  statin survey, "No" included. The collapse `pheno_df2$any_chol_med[!is.na(...)] <- 1` treats the
  string `'no'` as present-and-therefore-yes. Non-users are scored as users, and it cascades into
  `LDL_measured_on_meds`.
- **The same-day duplicate tie-break is not deterministic.** `distinct(person_id, .keep_all = TRUE)`
  keeps whichever row arrives first, and the SQL has no `ORDER BY`. Results are not bit-reproducible.

Neither bug would have been found by mocking data frames, because both live in the seam between the SQL
and the cleaning code. This is the argument for D-003, and it is now an argument backed by evidence
rather than by principle.

**Decided:** D-003 (the fixture is the offline test substrate), recorded retroactively.

**Next:** the documentation scaffold, and a home for these findings — which became A-002 and the
`any_chol_med` note in `FORMAT.md` §7.3.
