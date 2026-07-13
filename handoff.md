# handoff.md

**Things only a human can unblock.**

Everything here is outside the reach of the person or agent working in this repository: it needs
credentials, an institutional decision, a scientific judgement from someone with domain authority, or
an account that only a human can hold. If a thing *can* be done from inside the repo, it belongs in
[`TASKS.md`](TASKS.md) instead — this file is not a place to park hard work.

Each item states **what is needed, from whom, why it is blocking, and what is proceeding without it**,
so that nothing sits idle waiting for an answer that could have been worked around.

**Status:** 🔴 BLOCKING (work is stopped) · 🟠 WILL BLOCK (soon) · 🟢 RESOLVED (kept for the record)

---

## 🟢 H-001 — Install R on the development machine — **RESOLVED 2026-07-13**

- **Was needed from:** whoever administers the laptop.
- **Why it was blocking:** D-002 keeps the phenotyping ETL in R. When that decision was recorded, R was
  believed to be absent locally, which meant nothing R-based could be tested outside the Workbench —
  the fixture existed but the actual R cleaning code could never be run against it, only *replayed* in
  Python by `verify.py`.
- **Resolution:** R **is installed** — `R 4.6.0` (and `4.3.2`) at `C:\Program Files\R\`, with
  **`tidyverse` present**. It is simply not on `PATH`, which is why it appeared missing.
  `bigrquery` is absent, but that package is only needed for the "Do once" cells that talk to BigQuery,
  and those only run inside the Workbench — so its absence does not block offline work.
- **Consequence:** the R half is now testable locally, which is what T-005 (refactor into
  `src/phenotype/` with `testthat`) depends on. D-002's noted cost — "nothing R-based can be tested
  locally" — no longer applies.
- **See:** `docs/environment.md` for the interpreter paths; D-002; T-005.

---

## 🔴 H-006 — Confirm what may leave the Workbench, and whether this repo may be public

- **Needed from:** the lab PI / All of Us Data Use Agreement / the Resource Access Board.
- **Why it is blocking:** `LDLR Get phenotypes.ipynb` is committed **with cell outputs that were
  produced against the real controlled-tier CDR** (A-012). Nobody has yet read those outputs to check
  whether they contain row-level data, small-cell counts, or dates of birth. Until someone does, we do
  not know whether the repository is already carrying controlled-tier content — and therefore we cannot
  push it anywhere that is not private.
- **The specific questions:**
  1. May this repository be public at all (Q-R1)?
  2. If so, must notebook outputs be stripped, and does the *git history* need rewriting as well as the
     working tree (Q-R2)? Deleting a file in a new commit does **not** remove it from history.
  3. What is the small-cell suppression threshold we must apply to any exported aggregate result?
- **Proceeding without it:** T-012 (the cell-by-cell audit) does **not** need a human and is queued as
  P0. It is what turns this question from "we don't know" into "here is exactly what is in there" —
  which is the form a human can actually answer. Meanwhile the repository is treated as **if it were
  about to become public**, which is the only safe default.
- **See:** A-012, Q-R1, Q-R2, T-012. **This is the highest-urgency non-scientific item in the project.**

## 🔴 H-003 — Advisor sign-off on the outcome definition and the index date

- **Needed from:** the project advisor / an epidemiologist.
- **Why it is blocking:** two of the three definitions that determine everything downstream are open
  (DESIGN §2), and they are **not** the kind of question that can be settled by reading the data:
  - **Q-A1 — what counts as an incident ASCVD event?** PREVENT was derived against a specific composite
    outcome. If our outcome is not the outcome PREVENT predicts, its linear predictor is not a valid
    offset for it, and the primary model (D-006) is undermined at the root. Note the existing notebook
    already implements *something* — a union of ICD conditions and CPT procedures — so this is a
    decision about whether to **change** what is there, not a blank page.
  - **Q-S1 — what is the index date?** The convenient answer ("first visit where all PREVENT inputs
    exist") is the one that builds **immortal time bias** into the design, because such a date only
    exists for people who survived event-free long enough to accumulate one. A wrong choice here
    produces a perfectly calibrated, fully reproducible, entirely wrong study.
- **Why an advisor rather than a decision from within the repo:** both choices trade scientific
  validity against sample size, and getting them wrong is not detectable by any test we can write
  (VALIDATION §6). This is exactly the class of decision that should not be made by the person most
  motivated to have a large cohort.
- **Proceeding without it:** T-002 is BLOCKED, and so, transitively, is the entire analysis. What
  *can* proceed: quantify the cost of each option first — for each candidate index date and outcome
  definition, how many people are eligible, how many events, how much follow-up, how much missingness?
  **Bring numbers to the advisor, not just questions.** That analysis is unblocked and is the most
  useful preparation available.
- **See:** Q-S1, Q-A1, Q-A2; T-002; DESIGN §2.

## 🟠 H-002 — The PREVENT paper, its supplement, and its worked examples

- **Needed from:** anyone with journal access (Khan SS et al., *Circulation*, 2024).
- **Why it will block:** T-006 must implement PREVENT and **validate it against the published example
  risk values** — that external ground-truth check is the gate on the whole model half (VALIDATION §1).
  It requires three things from the paper: (a) the sex-specific coefficient tables, (b) the worked
  examples with their expected risk outputs, and (c) an unambiguous statement of the input units and
  which model variant we are using (the base equation, or the extended one with HbA1c / UACR / social
  deprivation index — All of Us may not support the extended inputs).
- **Proceeding without it:** the surrounding structure — schema, I/O, tests, the offset machinery — can
  all be built against a stub. But **no coefficient may be typed in from memory or from a secondary
  source.** Transcribing published coefficients is the kind of task that feels trivial and produces
  silent, total, undetectable error. It waits for the primary source.
- **See:** D-004; T-006; `src/aou_ascvd/prevent/`.

## 🟠 H-004 — All of Us Workbench access and a billing project

- **Needed from:** the lab / All of Us Researcher Workbench administration.
- **Why it will block:** every "Do once" cell in the notebook depends on `WORKSPACE_CDR`,
  `WORKSPACE_BUCKET`, `GOOGLE_PROJECT`, and `OWNER_EMAIL` being injected by the Workbench, plus
  authenticated `gsutil`. Nothing in this repository can touch real data without it, and the real
  cohort counts (needed for H-003's "bring numbers to the advisor") live behind it.
- **Proceeding without it:** essentially everything, for now — that is the entire point of `fixture/`
  (D-003). The ETL, the schema contract, PREVENT, and the statistical machinery can all be built and
  tested offline. This becomes blocking at T-002, when we need real counts.
- **Practical note:** confirm who holds the billing project and what the query budget is *before*
  re-running any "Do once" cell. Those cells cost real BigQuery time and write a new dated export
  directory (CLAUDE.md).

## 🟠 H-005 — Access to the srWGS genomic data, and a decision on the compute environment

- **Needed from:** the lab; All of Us controlled-tier genomic access.
- **Why it will block:** T-008 needs the variant data (Hail MatrixTable / VDS, or PLINK/VCF exports).
  Beyond access, there is a resourcing question a human must answer: rare-variant work on ~245,000
  genomes is not laptop-scale, and the choice of tooling (Hail on Spark vs. PLINK/REGENIE vs.
  SAIGE-GENE+) is partly a decision about **what compute the lab is willing to pay for**.
- **Proceeding without it:** Q-G3 proposes a synthetic variant fixture with a *planted* `LDLR` signal,
  so the entire genetic pipeline — QC, MAF banding, masking, gene-level aggregation, and the positive
  control in A-009 — can be developed and tested offline before any real genomic data is touched. That
  work is unblocked and should happen first regardless, because debugging a burden pipeline against
  controlled-tier data in the cloud is slow, expensive, and blind.
- **See:** Q-G3; T-008; D-008.

---

## How to use this file

When an item is resolved, **mark it 🟢 and keep it**, with what the answer was and what changed as a
result (see H-001). A resolved handoff is a record of how a blocker was actually removed, and that is
worth more than a tidy list.

If you are the human: the two that most need you are **H-006** (are we already carrying controlled-tier
data in a git repository?) and **H-003** (two study-design choices that no test can catch and that
determine whether the study is valid at all). Everything else has a way to make progress in the
meantime.
