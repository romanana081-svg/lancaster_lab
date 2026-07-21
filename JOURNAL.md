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

## 2026-07-20 (Workbench, later) — the feasibility count is in: ~219K complete PREVENT panels

**Did:** Re-ran the reconciliation against the real CDR (`C2025Q4R6`, v8) after `sql/02` was made
genomic-free (has_ehr_data + age_at_cdr, no srWGS gate). It now returns real numbers instead of the
srWGS-gated 0.

**The result (A-016 answered):** of **414,889** eligible (EHR, age 30–79), **218,798 (52.7%)** have a
complete PREVENT panel — TC, HDL, SBP, creatinine, BMI. That is the analysis-ready sample size, and it
is large: **the study is not underpowered on the phenotype side.** The **lipids are the bottleneck**
(total cholesterol 237K, HDL 232K; vs SBP 403K, BMI 404K, creatinine 311K) — completeness is set by
the scarcest member, and it is lipids, which is clinically sensible. Diabetes-by-code 77,436 (~19%).
Internal consistency holds: complete ≤ min single input (218,798 ≤ 232K).

**Caveats recorded:** this is the "ever" ceiling (a baseline window will shrink it); `bp_tx`/`smoking`
are not yet in the complete-panel definition (adding them shrinks it); and this is the genomic-free
cohort — the eventual srWGS genetic cohort is a subset, and this workspace's CDR has no genomic layer
(H-005). All counts are »20, so H-006 small-cell suppression is satisfied and they are safe to record.

**Next:** run `audit_codes()` to verify each domain's codes pull the right thing (esp. the statin
concept_id fragility, audit §8), then the extractor at CDR scale — which needs the SQL-side reduction
first (extract_prevent_panel currently downloads raw rows; at 219K+ that must be pushed into SQL).

---

## 2026-07-20 (Workbench run) — the reconciliation ran on real data, and the cohort is empty

**Did:** Ran `reconcile_prevent.R` against the real CDR (`wb-silky-artichoke-2408.C2025Q4R6`,
Controlled Tier **v8**) in the All of Us RStudio environment. The toolchain worked end to end on the
first real run — and it immediately earned its keep by surfacing a blocker that would otherwise have
cost months.

**The result, layer by layer:**
- **Vocabulary — all 7 PREVENT codes resolve.** Note the real `concept_id`s differ from the fixture
  (HDL `2085-9` → `3007070` not `3007352`; total cholesterol → `3027114`; one HbA1c → `3005673`).
  **This is a validation, not a problem:** the queries match on *codes*, and the IDs drifting between
  the fixture's v7-style seeds and the real v8 CDR is exactly why `prevent_concepts.yaml` insists on
  matching codes, never IDs. Nothing to fix.
- **Structure — the linkage trap is real.** ICD10CM sits on `condition_source_concept_id` (**113M**
  rows) and SNOMED on the standard column (175M), precisely as the fixture predicted. The whole class
  of silent-empty-phenotype bug is confirmed avoidable.
- **Coverage — the cohort is empty.** `n_eligible_srwgs_30_79 = 0`. Isolated it to the cohort gate:
  `dob` is fully populated (747,029 people, 1900–2006), but **`has_whole_genome_variant = 1` matches 0
  of 747,029.** And it is not a rename — **all four genomic flags are 0 for everyone**
  (`has_whole_genome_variant`, `has_lr_whole_genome_variant`, `has_array_data`,
  `has_structural_variant_data`). **This workspace's CDR has no genomic layer at all.**

**Learned — the thing worth the whole exercise:** *"0% coverage" and "wrong code" and "no data
provisioned" are three different facts that look identical from a single number*, and the layered check
told them apart. Step 1 proved the codes are right; step 3 gave 0; the follow-up proved the 0 is a
**data-availability** fact about this workspace, not a bug in our SQL. Learned in an afternoon for the
price of a few BigQuery scans, not in month three after building an extractor against an empty cohort.
This escalates **H-005 from 🟠 to 🔴** — it now blocks the cohort itself (D-013), not just the future
variant pipeline.

**Also confirmed working on real data:** the `run_sql.R` BigQuery fix (the `project.dataset` split +
billing) connected correctly, and the RStudio env vars had to be `Sys.setenv()`'d into the R session by
hand (the shell had `WORKSPACE_CDR`/`GOOGLE_PROJECT`, the R session did not inherit them — worth knowing
for next time).

**Next:** this is a PI / All of Us question (H-005) — verify genomic data access and that the workspace
is provisioned with srWGS. Nothing in the pipeline needs changing; when a genomic-enabled workspace is
available, `reconcile_prevent.R` produces the real counts unchanged. Optionally, run the completeness
query with the srWGS gate removed (on `has_ehr_data = 1`) to confirm the PREVENT *measurement* coverage
has real data behind it — validating that half of the logic while the genomic access is sorted.

---

## 2026-07-20 (later) — taking T-004 to the Workbench: an R entry point, a connection fix, a repo slip

**Did:** Started running the PREVENT reconciliation in All of Us and hit friction that was all
*environment*, not analysis. Three concrete outcomes.

1. **`run_sql.R`'s BigQuery connection was broken** and would have failed the very first Workbench
   query. `connect_cdr()` passed the whole `WORKSPACE_CDR` (a `"project.dataset"` string) as bigrquery's
   `dataset` and never set `billing`, so no table would resolve. Fixed: split on the last dot into
   data-project + dataset and bill to `GOOGLE_PROJECT`; with the dataset on the connection bigrquery
   sends it as the job's default dataset, so the bare table names in the `.sql` files resolve — the same
   mechanism the notebook's `bq_dataset_query()` calls already rely on. Offline path untouched, 73
   testthat still green. **Still unproven against real BigQuery (H-004)** — but now it matches
   documented usage instead of being wrong on its face.

2. **Added `src/phenotype/R/reconcile_prevent.R`** — a sourceable R entry point for the whole check.
   The lesson: the analysis notebook `LDLR Get phenotypes.ipynb` is a **Jupyter** artifact, and the R
   home in All of Us is **RStudio**, which does not run `.ipynb` cells. The AoU *Jupyter* image we first
   tried was conda-based with a **read-only system R library and no `DBI`/`tidyverse`/`bigrquery`** —
   installs fought back. RStudio ships all of it. So the reusable deliverable is a plain `.R` you
   `source()` from the repo root, not a cell buried in a notebook. It prints the same three layers
   (resolve? / linkage / completeness) and returns the frames invisibly.

3. **The repo was briefly made public.** A private HTTPS clone via R's `system("git clone …")` *hangs*
   — git's credential prompt has nowhere to appear, so it looks like "cloning forever" when it is
   really blocked on auth (the whole `.git` is <1 MB; size was never the issue). Rather than wire up a
   token, the repo was flipped to public, cloned, and set back to private. **For those minutes the
   A-014 identifiers — bucket UUID + Megan's institutional email — were public.** No participant data or
   secrets (T-012). This is the exposure D-010 accepted *only for a private repo*, so H-006's Q-R1 and
   the courtesy-to-Megan are now live questions for the PI, recorded in `handoff.md`.

**Learned:** the offline fixture did its job twice here — the connection fix and the reconciliation
script were both dry-run against DuckDB before ever spending a Workbench query, which is exactly the
point of D-003. The environment surprises (which AoU image, which R library, notebook-vs-script) cost
more than the code did — worth writing down so the next person picks RStudio and `reconcile_prevent.R`
straight away.

**Next:** run `reconcile_prevent.R` in the AoU RStudio env against the real CDR; record the resolve
table + counts in `docs/workbench_reconciliation.md`; feed any divergence back through
`prevent_concepts.yaml` → the SQL → the fixture. Then T-003 (the extractor) and T-015 (ASCVD events).

---

## 2026-07-20 — T-004: the fixture finally has the PREVENT panel in it

**Did:** Seeded every PREVENT domain into the fixture, so the thing this week is actually about can be
tested offline for the first time. Seven hand-authored participants `1000028`–`1000034` in
`generate.py` carry systolic BP, serum creatinine, HbA1c/diabetes, smoking and antihypertensive use;
the answer key gained `has_*` / `complete_prevent_panel` columns; filler moved to `1000035`–`1000307`.
`01_prevent_concept_discovery.sql` now resolves **all 7** codes (was: SBP/creatinine/HbA1c did not
resolve); `02_prevent_panel_completeness.sql` counts **3** complete panels. `verify.py`: **33 pass, 1
reproduced-bug, 0 unexpected**; full testthat suite green. Flipped the two testthat assertions that
deliberately pinned the *absence* of these domains — that flip was the intended signal (the test file
said so in a comment).

**Learned — the one interaction that could have quietly corrupted the LDLR answer key, and how the
fixture's own design defused it:**

The notebook defines LDL **negatively** — any measurement in the labs export that isn't triglycerides
or `3008631`. So a naive add of serum creatinine (which is in **mg/dL**, and can read `> 1`) would
have been silently swept up as "LDL" for every PREVENT participant, and the same for HDL. But the labs
export doesn't select by a flat concept-id list — it **walks the `cb_criteria` hierarchy under the lipid
group** (`37026687`/`3022192`). So the fix was structural, not a matter of picking values: seed
SBP/creatinine/HbA1c as **standalone** `cb_criteria` nodes (like BMI already is), and they never enter
the export at all. Only HDL and total cholesterol are lipid-group leaves and reach `labs_df` — HDL
misread as LDL (the pre-existing A9 defect), TC excluded. That is why each PREVENT participant's
answer-key `LDL` is deliberately their **HDL** value, and it is faithful rather than a fudge.

**Also learned:** the `value_as_number IS NOT NULL` guard in query 02 is load-bearing and now has a
test that would catch its removal — participant `1000031` has a creatinine *row* with a NULL value
(a censored `<0.2`), which must **not** count toward completeness. A row that looks like data and is
useless as data; if `n_serum_creatinine` ever rises from 3 to 4, that guard has been dropped.

**A discipline point:** antihypertensive and current-smoking are seeded as **illustrative** rows only.
`prevent_concepts.yaml` marks them `NEEDS_A_CODE_LIST` / `NEEDS_MAPPING`, and the fixture must not
quietly become the place where an authoritative drug list gets improvised from memory (the exact thing
that config warns against). The rows exist so a future extractor has something to read; they are not a
definition, and both configs now say so.

**Decided:** no new `D-` entries — T-004 executes decisions already made (D-013, D-014, T-017).

**Next:** T-004 unblocks the offline half of **T-003** (extract the PREVENT input panel) — the fixture
can now test an extractor for every input. Still open before the *analysis* can proceed: T-017 needs a
Workbench run (H-004) for the real counts, and T-015 (ASCVD event ascertainment) is unblocked and
independent. When T-003's extractor lands, the `has_*` answer-key columns become its per-person oracle.

---

## 2026-07-14 (evening) — T-017: the feasibility query, and a linkage trap

**Did:** Closed three open items (D-015) and wrote the query the week depends on.

- **Ages 30–79** (Q-S7 resolved). **The complete-panel skew is accepted as a limitation** (A-015) — the
  concession is deliberate, in order to use the PREVENT equation as published, and it is **conditional
  on reporting the demographics** of included vs. excluded. **Event-time anchoring is deferred** to a
  later goal (Q-S6 → T-019): for now we include the events and *keep the timing*.
- Wrote `sql/01_prevent_concept_discovery.sql` and `sql/02_prevent_panel_completeness.sql`, plus
  `run_sql.R`, which picks DuckDB or BigQuery off `WORKSPACE_CDR` so **the same SQL runs offline and
  in the Workbench unchanged**. 71 testthat tests pass.

**Learned — one trap that would have cost real time, and it is not hypothetical:**

**ICD codes are not on the column you would reach for.** In the CDR (verified in the fixture, and true
upstream), `condition_occurrence.condition_concept_id` maps to **SNOMED**; the ICD10CM code lives on
`condition_source_concept_id`. Same for procedures — CPT4 is on `procedure_source_concept_id`, while
the standard column is SNOMED. **Query the obvious column for an ICD code and you get zero rows and no
error.** Your diabetes phenotype is then simply empty, the completeness count reads 0%, and nothing
anywhere complains. There is now a test that pins this (`test-prevent-panel-sql.R`), because the whole
class of bug is invisible by construction.

**Why the discovery query is a separate step, and not fussiness.** Run against the fixture, query 01
immediately flagged `8480-6` (systolic BP), `2160-0` (creatinine) and both HbA1c codes as **DOES NOT
RESOLVE** — and query 02 duly reported 0 people with a complete panel. Those two facts have completely
different meanings: one is *"the fixture lacks these domains"* (true — T-004), the other would be
*"All of Us participants don't have blood pressures recorded"* (absurd). **From the completeness
numbers alone you cannot tell "no data" from "wrong code."** That is why 01 runs first, and why a
failure to resolve is an error rather than a warning.

**A deferral that is only safe while it stays honest.** Q-S6 is postponed, not solved — and the way it
could quietly un-defer itself is if some extractor "helpfully" reduces each person to their *earliest*
value, which is the notebook's habit everywhere (A-001). That would install a de-facto anchor, cases
and non-cases would be anchored differently, and every predictor would look stronger than it is with no
bug appearing anywhere. Hence `anchor: none` and `retain_all_dates: true` in the config, and a warning
on T-019. **The dates are the thing keeping the option open.**

**Next:** T-017 needs a Workbench run (H-004) — that is the only thing standing between us and knowing
whether this design is feasible. Meanwhile T-015 (ASCVD events) and T-004 (seed the fixture with the
PREVENT domains) are both unblocked.

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
