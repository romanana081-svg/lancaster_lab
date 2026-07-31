# Workbench runbook — pipeline check + demographics & incidence figures

**Run this top to bottom in the All of Us Workbench.** Step 2 produces a text file you paste back for
review; Step 3 produces the figures.

Supersedes the figure steps in [`workbench_figures_runbook.md`](workbench_figures_runbook.md)
(demographics only, and written before smoking was required).

### What changed on 2026-07-30 — read this before comparing to older numbers

1. **Smoking is now REQUIRED.** Participants with no survey smoking answer are **dropped**, not scored
   as non-smokers. Smoking is a PREVENT input and D-013 already excludes anyone missing an input
   rather than imputing it, so this is the consistent reading of a decision already made — but it is
   the single largest exclusion in the pipeline (39.8% survey coverage on the 2026-07-21 run, so the
   scorable panel goes roughly **216,167 → ~84,176**). Every figure caption now states the rule.
2. **`bp_tx` is no longer a placeholder.** It was FALSE for everyone; it is now driven by the AHA's
   published classes of blood-pressure medication (`configs/prevent_concepts.yaml`), listed by
   ingredient **name** and resolved against the CDR vocabulary at runtime. **Step 2 §1 verifies the
   resolution actually worked** — if the names don't resolve, `bp_tx` silently reverts to FALSE for
   everyone, which is the exact failure this replaced.
3. **ASCVD event ascertainment exists** (`extract_ascvd_events.R`) — first event date, class
   (acute / chronic / revascularisation), prevalent-vs-incident against a baseline.

Both changes move predicted risk **up** relative to the Thursday deck. Don't compare the two sets of
numbers without saying so.

---

## Step 0 — setup (once per session)

**Pull in the Workbench TERMINAL, not from R.** The repo is private over HTTPS, so git prompts for
credentials — and a prompt fired from R's `system()` has nowhere to appear, so it just hangs. That is
what happened to the original clone (JOURNAL 2026-07-20); it looks like "pulling forever" but it is
blocked on auth.

```bash
cd ~/lancaster_lab && git pull        # <- Terminal tab, not the R console
```

Then, in R:

```r
setwd("~/lancaster_lab")

Sys.getenv("WORKSPACE_CDR")              # must be non-empty
Sys.getenv("GOOGLE_PROJECT")             # must be non-empty
# If empty in R but set in the Terminal:
#   Sys.setenv(WORKSPACE_CDR = "...", GOOGLE_PROJECT = "...")

source("src/phenotype/R/run_sql.R")
source("src/phenotype/R/egfr.R")
source("src/phenotype/R/extract_prevent.R")
source("src/phenotype/R/extract_smoking.R")
source("src/phenotype/R/extract_ascvd_events.R")
source("src/phenotype/R/check_ascvd_events.R")
source("src/phenotype/R/workbench_report.R")
source("src/ascvd/prevent/run_prevent.R")

con <- connect_cdr()
```

---

## Step 1 — pick the two dates (a real decision, not a parameter)

```r
DBI::dbGetQuery(con, "SELECT MAX(condition_start_date) AS max_cond FROM condition_occurrence")
```

- **`end_of_followup`** — the CDR cutoff. Everyone event-free is censored here. Derive it; don't guess.
- **`landmark`** — baseline T0, applied to **everyone identically**. Late enough that most people have
  data before it, early enough to leave follow-up after it. A landmark cannot create immortal-time
  bias, because entry doesn't require having survived long enough to accumulate a panel.

---

## Step 2 — the pipeline report → **paste this file back**

```r
path <- workbench_report(con)     # writes reports/workbench_report_<date>.txt
```

Open that file and paste its **entire** contents back. It is aggregate-only, small-cell suppressed at
`<20`, no `person_id`s, no exact dates — safe to bring out of the Workbench whole.

**Read these four things before moving on:**

| § | What to check | Bad answer |
|---|---|---|
| 1 | `resolution source : names` and ~50+ ingredients resolved | `fixture_ids`, or a long UNRESOLVED list, or <20 resolved → `bp_tx` is under-counted |
| 2 | `bp_tx` prevalence in the mid-tens of percent | single digits → resolution failed; >60% → the list over-captures |
| 3 | smoking coverage, and what requiring it costs | a much lower coverage than 39.8% → check the survey question |
| 5 | Layer 1 all `yes`; Layer 5 all `PASS` | any `*** NO ***` here is real (unlike on the fixture, whose 208-row vocabulary makes several fail harmlessly) |

### Two known defects the report measures rather than guesses

- **CPT `929` over-captures.** `ascvd_codes.yaml` says `code_prefix: "929"` with the comment
  `92920-92944: PCI`, but `929` also matches 92950 (CPR), 92953 (pacing), 92960 (cardioversion),
  92986+ (valvuloplasty). Confirmed live on the fixture. **Layer 2 gives per-code counts** so the list
  can be pruned against evidence. A test pins the current behaviour so a fix can't land silently.
- **ICD10CM only → pre-2015 events invisible.** All of Us records before ~Oct-2015 are ICD9CM.
  **Layer 3 sizes it.** This changes who counts as *prevalent*, so it changes the cohort.

Optionally confirm the antihypertensive resolution in detail:

```r
print(run_sql_file("sql/06_antihypertensive_discovery.sql", con))
```

---

## Step 3 — the figures

```r
source("src/figures/cohort_overview.R")
source("src/figures/incidence_overview.R")

make_cohort_figures(con, outdir = "figures", require_smoking = TRUE)

make_incidence_figures(con, outdir = "figures",
                       landmark        = as.Date("2018-01-01"),   # your choice from Step 1
                       end_of_followup = as.Date("2022-07-01"),   # the CDR cutoff
                       attach_smoking_status = TRUE)
```

Copy them out:

```r
system(paste0("gsutil -m cp figures/*.png ", Sys.getenv("WORKSPACE_BUCKET"), "/figures/"))
```

### Step 3b — check the incidence against the PREVENT paper BEFORE anyone reads a curve

**Do not skip this and do not put figure 14 on a slide before it passes.** A survival curve built on
mis-ascertained events looks completely normal — smooth, monotone, plausibly shaped, and wrong. The
only cheap defence is comparing the rate to a published rate.

```r
source("src/ascvd/validation/literature_benchmarks.R")

# `status` is the frame from ascvd_status_at() (prevalent people carry event = NA and are correctly
# excluded from the denominator). If make_incidence_figures() built it internally, rebuild it here.
check_incidence_from_status(status, label = "acute ASCVD, landmark 2018-01-01")
```

| Verdict | What it means | What to do |
|---|---|---|
| `PLAUSIBLE` (4–12 /1000 PY) | in line with Khan et al.'s 4.15–4.30, adjusted for our older, EHR-selected cohort | show the curve |
| `LOW` (<4) | under-ascertainment — EHR capture gaps, ICD10CM-only missing pre-2015, or person-time inflated by censoring everyone at the CDR cutoff instead of last contact | say so on the slide; it bounds every downstream claim |
| `HIGH` (>12) | prevalent disease leaking into the at-risk set, `chronic_disease` counted as acute, or the CPT `929` over-capture | Layer 2 per-code counts tell you which |
| `STRUCTURAL DEFECT LIKELY` (<2 or >20) | not a population difference | fix before presenting |

**Expected on this run:** ~6–7 per 1000 PY, ~2,000 events, **2–4% cumulative incidence at 4.5 years**
on a ~70k at-risk set. Full reasoning: [`prevent_literature_benchmarks.md`](prevent_literature_benchmarks.md).

Also worth one line while you are there — the first look at PREVENT's calibration here (T-007):

```r
# If PREVENT were well calibrated, observed 4.5-y incidence ~= 0.45 x mean predicted 10-yr risk.
mean(scored$prevent_base_10yr_ASCVD, na.rm = TRUE) * 0.45   # vs the observed % from the check above
```

then download from the bucket in the Workbench file browser.

### What you get

| File | Anchor-dependent? |
|---|---|
| `01_age_hist`, `02_age_by_sex`, `03_sex_breakdown`, `04_race_breakdown` | no |
| `05_risk10_hist` | covariate values only |
| `06_missingness` (now includes smoking) | no |
| `10_events_by_class` | no |
| `11_acute_by_year` | no |
| `12_age_at_first_acute` | no |
| `13_attrition_to_at_risk` | landmark **date** only |
| `14_cumulative_incidence` | landmark **date** only |
| `15_cumulative_incidence_by_sex` | landmark **date** only |
| `16_observed_by_prevent_risk_PROVISIONAL` | **yes — covariate timing (Q-S6)** |

**Keep this distinction on the slide.** Figures 14/15 use event *dates* and the landmark only —
covariate values never enter, so the unresolved Q-S6 baseline anchor cannot bias them. Figure 16 uses
covariate *values*, which are still the **most-recent** measurement. For someone who had an event that
value can post-date it (statin started, BP treated), so the gradient is indicative, not final. The
caption says so — **don't crop it.**

---

## Step 4 — what to say out loud when the figures go up

- **Smoking required → N is ~84k, not ~216k.** State which N each figure is on.
- **`bp_tx` is new and PROVISIONAL** (`status: PROVISIONAL_AHA_CLASSES`). It measures *"on a
  BP-lowering drug"*, **not** *"treated for hypertension"* — beta blockers, loop diuretics and CCBs are
  also prescribed for arrhythmia, heart failure and angina. That over-capture is inherent to the
  PREVENT input, not a bug, but a reviewer will ask.
- **Smoking answer coding is still provisional** (`ANSWERS_PROVISIONAL`) — the question is pinned
  (`1585860`), the current/former/never map is not frozen.
- **No competing-risk handling.** Death isn't wired in, so cumulative incidence treats death as
  censoring, which **overstates** incidence in an older cohort.
- **No genomic layer in this workspace** (H-005, 🔴). Everything here is the genomic-free EHR cohort.
- **Q-S6 (baseline anchor) is still open** — figure 16 stays provisional until it's settled.

---

## If something breaks

| Symptom | Cause |
|---|---|
| `resolution source : fixture_ids` in the Workbench | the AHA names didn't resolve — `bp_tx` is running off two scaffolding IDs. Run `sql/06` and fix the config; do **not** present `bp_tx` from that run. |
| `NONE of the ... ingredient names resolved` error | the CDR spells ingredients differently. `sql/06` Query A shows what it does have. |
| Layer 2 captures nothing but Layer 1 resolved | linkage: ICD10CM is on `condition_source_concept_id`, CPT4 on `procedure_source_concept_id` — not the standard columns (those are SNOMED). |
| `figure 16 skipped: no PREVENT risk column` | `run_prevent.R` not sourced, or `AHAprevent` not installed here. |
| `figure 16 skipped: fewer than 20 scored people` | at-risk set too small — check the landmark isn't after most people's data. |
| `NEGATIVE follow-up` warning | landmark is after `end_of_followup`. |
| counts look wrong by a lot | `bigrquery` returns `integer64`; check for a coercion issue first. |

---

## Step 5 — the CASE-ANCHORED cohort (D-019) — *this is the one to demo*

Every case is anchored at **their own event date − 30 days**. There is no shared landmark. For each
case we sample **10 controls who were event-free at that same instant**, anchored at the same date.

```r
source("src/phenotype/R/extract_ascvd_events.R")
source("src/ascvd/stats/risk_set_sampling.R")
source("src/ascvd/prevent/run_prevent.R")

events <- extract_ascvd_events(con)

res <- build_case_anchored_cohort(con, events,
                                  washout_days = 30,      # D-017
                                  ratio        = 10,      # controls per case
                                  seed         = 20260731)

print(res$dropped)            # cases -> cases with a qualifying panel -> excluded. BRING THIS.
table(res$cohort$role)        # cases vs controls
sum(res$cohort$becomes_case_later)   # controls who have an event later (expected, not a bug)
```

Then attach each person's inputs **as of their own anchor date** and score:

```r
coh <- attach_panel_at_anchor(con, res$cohort)          # one query per 2,000 people
coh$egfr <- egfr_ckd_epi_2021(coh$creatinine, coh$age, coh$sex)   # needs age/sex joined first
scored <- run_prevent(coh)

# the headline slide: does PREVENT score cases higher than controls?
aggregate(prevent_base_10yr_ASCVD ~ role, scored, function(x) round(mean(x, na.rm = TRUE), 2))
```

### What to say about it

- **Controls can become cases later, and are kept.** Each control row represents *person-time at
  risk at that instant*, not "a person who never had an event". Dropping future cases is the classic
  incidence-density-sampling error and biases the result. The flag `becomes_case_later` reports how
  many, so the question is answered rather than dodged.
- **The same person can be a control for more than one case.** Same reason.
- **`weight` is on every row** (eligible ÷ sampled in that risk set). Discrimination (C-index) and the
  offset-Cox test on γ are valid unweighted. **Absolute calibration is not** — a 10:1 sample has ~10×
  the cohort's event rate, so "predicted 8% vs observed 8%" needs the weights. That matters because
  PREVENT's miscalibration in All of Us is exactly what DESIGN stage 5 exists to catch, and what a
  genetic term would otherwise silently absorb.
- **The seed is recorded** (`res$params$seed`). Re-running with it rebuilds the identical cohort.

### The attrition number that will get asked about

`res$dropped` row 3 is **cases excluded because their panel completed less than 30 days before the
event, or never**. In an EHR cohort this may be large — the panel and the event often arrive in the
same clinical episode, which is precisely the reverse causation the rule exists to remove. Report it;
don't bury it. `washout_days = 0` re-runs without the rule, which measures what it cost.
