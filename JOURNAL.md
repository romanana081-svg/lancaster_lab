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
