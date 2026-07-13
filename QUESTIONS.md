# QUESTIONS.md

Open **scientific** questions — the ones where the honest answer is "we do not know yet", and where
guessing wrong changes the result rather than merely costing time.

This file is not a to-do list. [`TASKS.md`](TASKS.md) is the to-do list. A question earns a place here
only if **a reasonable expert could answer it differently from us**, and that difference would change
a number in the paper. Engineering unknowns ("which parquet library?") do not belong here.

Anything that needs a *human* — an advisor, the All of Us Resource Access Board, a lab meeting — is
also in [`handoff.md`](handoff.md). A question can appear in both: here for the science, there for the
blocking.

**Status key:** 🔴 blocks a result · 🟠 shapes a result · 🟡 refines a result
**Lifecycle:** OPEN → PROPOSED ANSWER → RESOLVED (record the resolution as a `D-0NN` in
[`DECISIONS.md`](DECISIONS.md) and link it here; never just delete the question)

**Template**

```
### Q-X0 — <the question, as an actual question>
- Priority:      🔴/🟠/🟡
- Status:        OPEN | PROPOSED ANSWER | RESOLVED (→ D-0NN)
- Why it matters: what breaks if we get it wrong
- The options:   the live candidate answers, with their costs
- Leaning:       our current best guess, and how confident we are
- To resolve:    what would actually settle it (an analysis, a paper, a human)
- Deadline:      the point past which it must be settled — usually "before outcomes are examined"
```

Categories: **Q-S** study design & statistics · **Q-A** outcome ascertainment · **Q-G** genetics ·
**Q-R** repository & governance.

---

## Q-S — Study design and statistics

### Q-S1 — What is the index date (time zero)?
- **Priority:** 🔴
- **Status:** OPEN
- **Why it matters:** Time zero defines *everything*: who is eligible, which measurements count as
  "baseline", how long each person is followed, and whether the study is biased before a single model
  is fitted. It is the most consequential unmade decision in the project.
- **The options:**
  1. **First date at which all PREVENT inputs are available.** Natural, and it guarantees a complete
     covariate vector. But it is defined *by looking at the data*, and a person only has such a date
     if they survived, event-free, long enough to accumulate one — the textbook recipe for
     ***immortal time bias***. It also silently selects for people with dense EHR contact (A-006).
  2. **Enrollment in All of Us.** Clean, exogenous, identical in spirit to a trial's randomisation
     date. But PREVENT inputs are frequently missing at enrollment, which converts the problem into a
     large missing-data problem instead of a bias problem.
  3. **A fixed calendar date** (e.g. 2018-01-01) for everyone enrolled by then. Removes the
     data-driven element entirely; discards everyone who joined later.
  4. **Age as the time scale**, with left truncation at the age of first eligibility. Epidemiologically
     the most defensible for a lifetime-risk disease — age *is* the dominant hazard — but it requires
     handling delayed entry correctly (see GLOSSARY: *left truncation*).
- **Leaning:** (2) or (4), weakly. The instinct to reach for (1) is exactly the instinct that produces
  the bias, and the fact that it is the most convenient option should raise suspicion, not comfort.
- **To resolve:** an advisor conversation (H-003) plus a descriptive analysis: for each candidate,
  how many people are eligible, how much follow-up do they contribute, and how much of PREVENT is
  missing at that moment? **Quantify the cost before choosing.**
- **Deadline:** before cohort construction (T-002). Nothing downstream is trustworthy until this is
  fixed, and it must not be revisited after outcomes are seen.

### Q-S2 — If PREVENT is miscalibrated in All of Us, is the offset model still valid?
- **Priority:** 🔴
- **Status:** OPEN
- **Why it matters:** This is **the single most dangerous failure mode of the study** (A-008). The
  primary model (D-006) fixes PREVENT's linear predictor at coefficient 1. If PREVENT is systematically
  wrong in this population — and it very likely is, having been derived elsewhere on trial-quality
  outcomes — then the residual it leaves behind is *not* pure biological residual risk. It contains
  PREVENT's calibration error. A genetic term added to that model can soak up the error and come out
  significant while carrying no genetic information whatsoever. We would publish a false positive and
  it would look beautiful.
- **The options:**
  1. **Offset the published LP anyway** (M1) and report M2 (refit) alongside. Answers the literal
     question "beyond PREVENT as published", which is what a clinician deploys.
  2. **Offset a *recalibrated* LP** — estimate the slope `β` in M0' first, then offset `β·LP`. Answers
     "beyond PREVENT, fairly applied to this population". Arguably the more honest baseline, but it is
     no longer PREVENT-as-published.
  3. **Report both, and treat agreement between them as the evidence.** If `γ` is significant under
     both, the finding is robust to the calibration question. If it is significant only under (1),
     that is a strong hint we are fitting miscalibration.
- **Leaning:** (3), fairly confidently. It costs one extra model and buys the ability to tell a real
  effect from an artefact — and it converts the project's biggest threat into a reported sensitivity
  analysis.
- **To resolve:** stage 5 of DESIGN §5 (T-007) has to run first; the answer depends on *how bad* the
  miscalibration turns out to be. A negative control also settles it cheaply: put a **genetically
  null** term (e.g. burden in a gene with no plausible lipid/CAD role) into M1. If it comes out
  significant, the offset is absorbing miscalibration and (1) alone is unusable.
- **Deadline:** before the primary analysis (T-009). Freeze the choice *before* seeing `γ`.

### Q-S3 — Which NRI cut-points, and does NRI belong in the paper at all?
- **Priority:** 🟡
- **Status:** PROPOSED ANSWER (secondary endpoint only — D-007)
- **Why it matters:** NRI is biased toward declaring improvement, and it is sensitive to arbitrary
  risk-category boundaries: move the cut-points and the "improvement" moves with them. Reviewers ask
  for it anyway.
- **The options:** the clinical ACC/AHA treatment thresholds (5%, 7.5%, 20% ten-year risk) — defensible
  because they map to real decisions; or a category-free continuous NRI — avoids arbitrary bins but is
  even more prone to overstating improvement.
- **Leaning:** report the **clinical thresholds**, pre-specified and frozen, explicitly labelled
  secondary, with decision-curve analysis (which answers the same clinical question without the bias)
  as the one we actually argue from.
- **To resolve:** pre-register the cut-points in D-007 before any outcome model is fitted.
- **Deadline:** before T-009.

### Q-S4 — Is there enough follow-up and are there enough events to answer the question?
- **Priority:** 🔴
- **Status:** OPEN
- **Why it matters:** A rare-variant burden effect on residual risk is, a priori, a *small* effect
  being sought in a *subset* of people who carry the variants at all. If All of Us yields too few
  incident ASCVD events, the study is **underpowered**, and an underpowered null is not a negative
  result — it is *no result*, dressed as one. The distinction matters enormously for what we may claim
  (A-010, DESIGN §9).
- **The options:** not really options — a fact to be measured. But the *response* to the fact has
  options: broaden the endpoint (Q-A1), extend the horizon from 10y to 30y risk, restrict to a
  pre-specified high-yield gene set to preserve power (Q-G1), or report the study as a
  precision-of-estimate exercise rather than a hypothesis test.
- **To resolve:** describe the follow-up distribution and count observed events, then compute power for
  a plausible effect size **before** fitting anything. This is cheap and must not be skipped.
- **Deadline:** before T-008. If the answer is "underpowered", the design changes, and it is far
  better to learn that now than after the genetic pipeline is built.

### Q-S5 — Do genetic effects violate the proportional hazards assumption?
- **Priority:** 🟠
- **Status:** OPEN
- **Why it matters:** The Cox model assumes a covariate's effect is constant over time. Genetic effects
  on ASCVD are widely reported to be **stronger at younger ages** — a familial hypercholesterolemia
  carrier's excess hazard is most visible at 45, less so at 75, when everyone's risk is high. If that
  holds, a single hazard ratio `γ` averages a real early effect with a null late one, **biasing the
  test toward the null** and risking a false negative.
- **The options:** test and report a time-varying coefficient; restrict to a time horizon (e.g.
  10-year, matching PREVENT's own); or stratify the analysis by age band.
- **Leaning:** check Schoenfeld residuals as a matter of course; if violated, report a
  time-restricted C-index and a time-varying `γ` rather than pretending the assumption holds.
- **To resolve:** Schoenfeld residual test in T-009. This is a diagnostic, not a judgement call — run
  it and follow it.
- **Deadline:** part of T-009's validation contract; cannot be deferred past the primary result.

---

## Q-A — Outcome ascertainment

### Q-A1 — What exactly counts as an incident ASCVD event?
- **Priority:** 🔴
- **Status:** OPEN — **needs an advisor** (H-003)
- **Why it matters:** The outcome definition is the dependent variable. Everything — power, effect
  size, comparability to PREVENT's own derivation — hangs on it. PREVENT was derived against a
  specific composite (CVD death, non-fatal MI, non-fatal stroke, and in its broader form heart
  failure). **If our outcome is not the outcome PREVENT predicts, then PREVENT's linear predictor is
  not a valid offset for it**, and the entire construction in D-006 is undermined.
- **The options:**
  1. **Match PREVENT's composite exactly.** The only choice that keeps the offset coherent. Requires
     capturing fatal events, which means death data and cause of death, which EHR handles poorly.
  2. **Hard ASCVD only** (MI + ischemic stroke + coronary death). Cleaner to ascertain from codes;
     fewer events; no longer exactly PREVENT's target.
  3. **Broaden to any coronary event including revascularisation** (the existing notebook's `codes_df`
     already unions ICD conditions and CPT procedures — this is effectively what it captures today).
     More events, better power, but revascularisation is a *treatment decision*, not purely a disease
     event, and it is confounded by healthcare access.
- **Leaning:** (1) in principle, with (2) as the pragmatic fallback — but this genuinely needs an
  epidemiologist. Note the existing notebook already implements something like (3), so this is not a
  greenfield choice: **it is a decision about whether to change what is already there.**
- **To resolve:** advisor (H-003), plus a count of how many events each definition yields — this
  interacts directly with the power question (Q-S4).
- **Deadline:** before cohort construction (T-002).

### Q-A2 — Must a person have a minimum amount of EHR contact to be eligible?
- **Priority:** 🟠
- **Status:** OPEN
- **Why it matters:** A-006 assumes absence of a code means absence of disease. That assumption is
  weakest for people who barely appear in the EHR: they look healthy because they are *unobserved*,
  not because they are well. This misclassification is **non-random** — it tracks healthcare access,
  insurance, and therefore socioeconomic status and ancestry. In a study whose entire point is a
  genetic signal in an ancestrally diverse cohort, an outcome-ascertainment bias correlated with
  ancestry is not a nuisance; it is a route to a spurious finding (see also A-011).
- **The options:** no requirement (maximise N, accept the misclassification); require ≥N visits or ≥N
  years between first and last EHR contact; or model EHR density explicitly as a covariate.
- **Leaning:** impose a **minimum follow-up window** and report the analysis with and without it as a
  sensitivity. The fixture already contains a participant with a CAD code and *zero* visits
  (`1000024`, defect A6), which breaks censoring outright — proof the degenerate case is real.
- **To resolve:** describe the distribution of visit counts and follow-up duration; check whether it
  differs by genetic ancestry. If it does, this is 🔴, not 🟠.
- **Deadline:** before T-002.

---

## Q-G — Genetics

### Q-G1 — Pre-specified gene set, or exome-wide?
- **Priority:** 🔴
- **Status:** OPEN
- **Why it matters:** This determines whether the study is **confirmatory** or **discovery**, and it
  sets the multiple-testing burden (DESIGN §6.3). Exome-wide (~20,000 genes) needs Bonferroni
  ≈ 2.5 × 10⁻⁶ and, given Q-S4's likely event count, may simply have no power to clear it. A
  pre-specified lipid/CAD set (`LDLR`, `APOB`, `PCSK9`, `LPA`, `APOA5`, `ANGPTL3/4`, …) has a trivial
  correction and far better power — but it can only *confirm* known biology, and the finding is
  correspondingly less exciting.
- **The options:** pre-specified set (powered, confirmatory, safe); exome-wide (discovery, likely
  underpowered); or **both, hierarchically** — the pre-specified set as the primary endpoint, the
  exome-wide scan reported as exploratory and explicitly not corrected for as if primary.
- **Leaning:** the hierarchical option. It gets a defensible primary test *and* preserves the chance of
  discovery, provided the hierarchy is declared in advance rather than chosen once the p-values are in.
- **To resolve:** the power calculation from Q-S4 largely decides this. Freeze the gene list in a
  config file, committed, before any outcome is touched.
- **Deadline:** **before outcomes are examined.** This is the classic garden-of-forking-paths
  decision; making it after seeing results invalidates the p-value regardless of what the number says.

### Q-G2 — Which MAF threshold and which functional mask?
- **Priority:** 🟠
- **Status:** OPEN
- **Why it matters:** "Rare variant burden" is not one thing — it is a family of definitions, and the
  answer changes with the definition. MAF < 1% vs < 0.1%; loss-of-function only vs LoF + missense
  predicted damaging vs all coding. Each combination is a different exposure, and quietly trying
  several and reporting the best one is p-hacking with extra steps.
- **The options:** the conventional defaults are MAF < 1% (low-frequency) and MAF < 0.1% (rare), with
  masks of (a) high-confidence LoF (LOFTEE), (b) LoF + damaging missense (REVEL ≥ 0.5), (c) all coding.
- **Leaning:** pre-specify **one primary** (likely MAF < 1%, LoF + damaging missense — the mask with
  the best prior of carrying real effect) and report the rest as a **pre-declared sensitivity grid**
  (DESIGN §5, stage 8), so that the full set of results is visible rather than the best of them.
- **To resolve:** a decision, recorded as a D-entry, frozen in config before analysis.
- **Deadline:** before outcomes are examined. Same forking-paths logic as Q-G1.

### Q-G3 — How do we test the genetic half offline?
- **Priority:** 🟠
- **Status:** OPEN
- **Why it matters:** `fixture/` gives the phenotyping ETL a laptop-testable substrate, and that has
  already paid for itself — it caught two real bugs (A-002, and the `any_chol_med` survey defect).
  **There is no equivalent for the genomic half.** Without one, every line of variant-QC and
  gene-burden code is written blind and first executed against controlled-tier data in the cloud, where
  it is slow and expensive to debug and where a silent bug (a wrong allele orientation, an off-by-one
  in a mask) produces plausible-looking numbers rather than an error.
- **The options:** a synthetic VCF/PLINK fileset with known carriers and a ground-truth burden matrix
  (mirrors what `fixture/` does for phenotypes, and is the natural extension); a small public reference
  (e.g. 1000 Genomes chr22) with a *simulated* phenotype; or Hail's own test data.
- **Leaning:** extend `fixture/` with a synthetic variant fileset carrying a **planted signal** — a
  handful of `LDLR` LoF carriers given deliberately high LDL. Then A-009's positive control (burden in
  `LDLR` must associate with LDL) becomes an *offline test that must pass*, not a hope pinned on the
  real data.
- **To resolve:** a design decision plus implementation (T-008's prerequisite).
- **Deadline:** before T-008 is written, not after it fails.

---

## Q-R — Repository and governance

### Q-R1 — May this repository be public?
- **Priority:** 🟠
- **Status:** OPEN — **needs a human** (H-006)
- **Why it matters:** All of Us controlled-tier policy governs what may leave the Workbench. Code and
  aggregate results generally may; participant-level data absolutely may not. The repository currently
  contains a notebook committed **with outputs produced against real controlled-tier data** (A-012),
  which means the question is not academic.
- **To resolve:** read the All of Us Data Use Agreement and confirm with the lab / RAB. Until then,
  **treat the repository as if it were about to become public**, which is the only safe default.
- **Deadline:** before any push to a public remote.

### Q-R2 — What must be stripped from the committed notebook before it can be shared?
- **Priority:** 🔴 (governance)
- **Status:** OPEN — **highest-urgency non-scientific item** (A-012, H-006, T-012)
- **Why it matters:** `LDLR Get phenotypes.ipynb` is ~180 KB precisely *because* it carries its cell
  outputs, and those outputs came from the real CDR. If any of them contain row-level prints, small
  cell counts, dates of birth, or person identifiers, then committing them was already a data-policy
  violation, and pushing them publicly compounds it. This is not a hypothetical risk — it is a thing
  that is presently true in the repository and has not yet been checked.
- **The options:** strip all outputs (`nbconvert --clear-output`) and commit the cleaned notebook —
  safe, loses the record of what the code produced; or audit every output cell and redact selectively —
  preserves useful evidence, but is only as good as the audit; or keep the history rewritten
  (`git filter-repo`) if anything identifiable is found — the only real remedy once it is in history.
- **Leaning:** **audit first (T-012), then strip outputs by default.** The audit is what tells us
  whether history also needs rewriting, and that answer must be known before any public push. Note that
  removing the file in a *new* commit does not remove it from history.
- **To resolve:** T-012 — a cell-by-cell read of the notebook's outputs. This is mechanical and can be
  done now; it is not blocked on anyone.
- **Deadline:** **before the first push to any remote that is not private.**

---

## Resolved

*(none yet — when a question is resolved, move it here with a link to the D-entry that settled it,
rather than deleting it. The record of what was once uncertain is part of the project's memory.)*
