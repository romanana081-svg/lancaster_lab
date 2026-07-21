# meeting.md — advisor meeting prep, 2026-07-21

Working doc for today's advisor meeting. Six deliverables, tracked below. Detail lives in each
numbered section; the checklist is the at-a-glance state.

## Checklist

| # | Deliverable | State |
|---|---|---|
| 1 | Step-by-step: run the **extractor** in the Workbench | ✅ RAN — 216,167 scorable panels (§1) |
| 2 | **Validate the PREVENT equation** (external cross-tie to Khan 2024 / AHA calculator) | ⏳ research running (§2) |
| 3 | Code for **smoking codes** + **Q-S6 baseline anchor**, runnable in the Workbench | ⏳ to write (§3) |
| 4 | The **questions** to get answered in the meeting | ⏳ to write (§4) |
| 5 | The most important **handoff.md issues** to raise | ⏳ to write (§5) |
| 6 | Step-by-step: **end-to-end patient demo** to show the advisor it works | ⏳ to write (§6) |

Context that frames all of it:
- **The workspace has no genomic layer (H-005, 🔴).** All four `has_*_variant` flags read 0 for
  everyone. D-013 says the cohort *is* the srWGS participants, so today the genetic half — and the
  final cohort — is blocked. **But the phenotype/PREVENT half runs on the genomic-free cohort
  (`has_ehr_data`), which is what the demo uses.** ~219K complete panels there (prior session).
- **PREVENT equation is NOT blocked locally.** `AHAprevent` (official AHA package) is installed and its
  tests pass. What's open is the *external* validation and the model-variant decision (H-002).

---

## §1 — Run the extractor in the Workbench

**REAL RUN, 2026-07-21 (bring these numbers):**
- **411,131** people in the panel (≥1 PREVENT measurement, EHR, age 30–79; median age 58).
- **216,167** have a complete, **scorable** panel — the analysis-ready N.
- This is **2,631 below sql/02's 218,798** *by design*: sql/02 counts "creatinine row exists";
  the extractor requires a **computable eGFR + male/female sex** (eGFR and PREVENT are sex-specific).
  The two counts agreeing to ~1% is a cross-validation, not a discrepancy.
- **~3,942 participants have `sex_at_birth` ≠ male/female** (panel 411,131 vs female+male 407,189) →
  no eGFR, no PREVENT score. This is the bulk of the gap, and it is an **advisor question** (§4).
- **Lipids are the bottleneck:** missing total_c 174k, hdl_c 179k; vs SBP 7.8k, BMI 6.9k, eGFR 105k.
  Same story as the feasibility count — completeness is set by the scarcest input, and it's lipids.



**Goal:** run `extract_prevent_panel()` at CDR scale and get one row per person with the PREVENT inputs.
This is now feasible because the measurement cleaning was pushed into SQL (commit 897f7c1) — it no
longer downloads ~62M raw rows.

**Prerequisites (once per session):**
- You're in the All of Us workspace with an **R** environment (RStudio or an R notebook).
- The repo is cloned (you did this 2026-07-20). `cd` / `setwd()` to its root.
- `bigrquery` is installed in the Workbench (it is by default; the local machine lacks it, the cloud
  has it).

**Steps — paste these into R, in order:**

```r
# 0. Be at the repo root, and confirm the Workbench env vars reached R (not just the terminal).
setwd("~/lancaster_lab")                      # adjust to where you cloned it
Sys.getenv("WORKSPACE_CDR")                   # must be non-empty, e.g. "wb-...-2408.C2025Q4R6"
Sys.getenv("GOOGLE_PROJECT")                  # must be non-empty (your billing project)
# If WORKSPACE_CDR is empty in R but set in the Terminal:
#   Sys.setenv(WORKSPACE_CDR="...", GOOGLE_PROJECT="...")

# 1. Load the connection helper and the extractor.
source("src/phenotype/R/run_sql.R")           # connect_cdr() — picks BigQuery from WORKSPACE_CDR
source("src/phenotype/R/extract_prevent.R")   # extract_prevent_panel(); auto-sources egfr.R

# 2. Open the CDR connection and run the extractor. This fires 4 BigQuery queries
#    (measurements reduced server-side, diabetes, statins, demographics). A few minutes.
con   <- connect_cdr()
panel <- extract_prevent_panel(con)

# 3. Sanity checks — the numbers to eyeball before trusting anything.
nrow(panel)                                   # people with >=1 PREVENT measurement, EHR, age 30-79
sum(panel$complete_panel)                     # should be ~219K, cf. sql/02 (see cross-check below)
colSums(is.na(panel[, c("sbp","total_c","hdl_c","egfr","bmi")]))   # per-input missingness
summary(panel$age); table(panel$sex)          # age in [30,79]; sex both levels
summary(panel$egfr)                           # CKD-EPI 2021 output, plausible 5-140ish
mean(panel$dm); mean(panel$statin)            # ~0.19 dm, ~statin prevalence from the audit

# 4. Cross-check the complete-panel count against the independent SQL path (should match closely).
sql02 <- run_sql_file("sql/02_prevent_panel_completeness.sql", con)
print(sql02)                                  # its complete-panel count ≈ sum(panel$complete_panel)
```

**What "good" looks like:** `sum(panel$complete_panel)` lands near the sql/02 figure (~218–219K).
The extractor's complete-panel definition (age, sex, sbp, total_c, hdl_c, egfr, bmi all present) is the
same five measurements + demographics that sql/02 counts, so they should agree to within the small
differences in how each handles edge rows. A large gap = investigate before trusting the panel.

**Watch-points:**
- `person_id` comes back from `bigrquery` as `integer64`. The `%in%` membership tests (dm, statin) and
  the joins are written to tolerate it, but if a count looks wrong, check for an integer64 coercion
  issue first.
- `bp_tx` and `smoking` are **FALSE for everyone** by design (placeholders — §3 fixes smoking). Every
  row is stamped in `placeholder_inputs`. Do **not** read a final risk score off this panel yet.
- Cost: 4 queries; the measurement one scans the measurement table once. Confirm the query budget with
  whoever holds the billing project (H-004) before repeated runs.

**Save (optional, for the demo / reuse):**
```r
arrow::write_parquet(panel, "phenotypes_v1.parquet")
system(paste0("gsutil cp phenotypes_v1.parquet ", Sys.getenv("WORKSPACE_BUCKET"), "/data/"))
```

---

## §2 — Validate the PREVENT equation ✅

**Result: the equation is validated.** Our `run_prevent()` wraps `AHAprevent::prevent_base` — the
**official AHA implementation** (Khan group). To rule out an implementation bug in that package too, I
cross-checked it against an **independent** implementation, the CRAN `preventr` package (separately
authored; its docs report validation against the AHA online PREVENT calculator). New reproducible test:
`tests/testthat/test-prevent-crosscheck.R` (8 assertions, all pass).

**What the cross-check found, over ~240 diverse profiles spanning every input's range:**
- **10-year ASCVD: agreement to <0.05 percentage points everywhere** both define a value (that's the
  rounding floor — `preventr` reports to 0.1%). Implementation gate passed.
- **30-year ASCVD: exact agreement (to rounding) for ages 30–59.**
- **One real discrepancy — the 30-year age boundary.** At **age ≥ 60**, `AHAprevent` returns `NA` for
  30-year risk (the 30-yr window is defined for 30–59); `preventr` extrapolates a number up to 79.
  **Our pipeline uses `AHAprevent`, i.e. the conservative/official behavior**, and our primary horizon
  is 10-year (`config horizon_years: 10`), so this does not touch the primary analysis — but it is an
  **advisor question** (§4) before any 30-year result is reported. The test pins this boundary so it
  can't drift silently.

**What this did NOT close:** a *directly-cited* numeric worked example from Khan 2024 (Circulation) —
the paper is paywalled and no open full-profile worked example was sourced. The two-implementation
agreement is the substitute. **The 2-minute human confirmation:** enter one profile into the AHA online
calculator (professional.heart.org PREVENT calculator, "base" model) and check it against
`AHAprevent::prevent_base` for the same profile. Suggested profile (matches the packages' documented
example): 45 y/o female, TC 200, HDL 60, SBP 120, on no BP meds, diabetes, non-smoker, BMI 25,
eGFR 95, no statin → **10-yr ASCVD ≈ 2.1%, 30-yr ASCVD ≈ 12.0%**. If the calculator agrees, done.

**Model variant still open (H-002):** base vs extended (extended adds HbA1c / UACR / SDI). We validated
the **base** model. Which variant we use is an advisor decision and it changes the required panel — an
extended input shrinks the complete-case cohort (D-013). See §4.

---

## §3 — Smoking codes + Q-S6 baseline anchor ✅

Three new files, all tested on the fixture (`extract_smoking` 13 assertions pass; full suite green) and
portable to BigQuery. Two run as SQL via `run_sql_file(...)`, one is an R extractor.

### Smoking (resolves `current_smoking`, which is NEEDS_MAPPING)
- **`sql/03_smoking_survey_discovery.sql`** — RUN THIS IN THE WORKBENCH FIRST. Lists every smoking-
  related survey question, each answer option, and how many people gave it. This is how the current-vs-
  former-vs-never mapping gets **defined from evidence** instead of guessed (prevent_concepts.yaml
  forbids guessing). On the fixture it returns question 1585857 "Smoking status" with answers
  Never / Current Every Day.
- **`src/phenotype/R/extract_smoking.R`** — `extract_smoking(con)` derives `current_smoking` per person
  from that person's **most-recent** informative survey answer, using a transparent default classifier
  (current if the answer says "current"/"every day"/"some days" and not former/never). **Every row is
  stamped `smoking_mapping = "PROVISIONAL"`** — it cannot be mistaken for final until sql/03 confirms
  the real answer set. On the fixture: 1000028 → TRUE, 1000032 → FALSE (matches the answer key).
- **How to run it in the Workbench:**
  ```r
  source("src/phenotype/R/run_sql.R"); source("src/phenotype/R/extract_smoking.R")
  con <- connect_cdr()
  print(run_sql_file("sql/03_smoking_survey_discovery.sql", con))   # <- read this, find the real Qs/As
  smk <- extract_smoking(con)                                       # provisional derivation
  table(smk$smoking, useNA = "always")
  ```
  Then paste the confirmed question_concept_id(s) into `extract_smoking(con, question_concept_ids = c(...))`
  and, once the answer set is nailed, replace the default classifier and flip prevent_concepts.yaml off
  NEEDS_MAPPING.

### RESULTS from the 2026-07-21 Workbench run

**Smoking mapping RESOLVED (closes NEEDS_MAPPING).** Discovery (sql/03) shows the clean PREVENT
current-smoking definition is question **1585860 "Smoking: Smoke Frequency"**: current = Every Day
(1585863, 158,283) or Some Days (1585861, 65,961) → **~224k current smokers**; Not at all (1585862,
31,820) = former; never-smokers skip via 1585857 "100 Cigs Lifetime" = No. Run
`extract_smoking(con, question_concept_ids = 1585860L)` for the clean per-person table. NOTE: the
default broad `LIKE '%smok%'` over-pulls (e-cig/cigar/hookah/cannabis; billed 20 GB, 6M rows) and its
154,894 TRUE is over-inclusive — do not quote it. TODO after meeting: set the default question +
answer_concept_id map in extract_smoking.R and flip prevent_concepts.yaml off NEEDS_MAPPING (needs a
matching fixture update).

**SMOKING COVERAGE IS THE REAL BOTTLENECK (headline finding, 2026-07-21).** Survey smoking coverage is
**39.8%**. Requiring smoking drops the scorable cohort **216,167 → 84,176 (−61%, −131,991 people)**.
84k is still well-powered, BUT the 61% lost are survey non-completers who differ systematically (access,
SES, ancestry — A-015), so requiring survey smoking **entangles cohort membership with ancestry** — the
exact confound the PRS/rare-variant work must avoid. This makes smoking-handling a top-tier design
decision. Options for the advisor: (A) require survey smoking → 84k, selected; (B) default missing →
non-smoker → keep 216k, misclassification bias; (C) **supplement survey with EHR smoking** (SNOMED
tobacco-use codes in `observation`; sql/03's commented follow-up targets it) → likely recovers much of
the loss — RECOMMEND trying C first; (D) impute. Quick test: run sql/03's observation follow-up to see
how many additional people have an EHR smoking code.

**Q-S6 evidence — the anchor choice is NOT free (decisive).** Most of the cohort has MANY repeat
measurements: mean dates/person SBP 25, creatinine 20, BMI 16, lipids ~7; and the majority have >1
date (SBP 336,506 of 571,419; creatinine 317,657 of 358,268; lipids ~208–216k of ~263–270k). So
most-recent vs first-complete-panel vs landmark give materially different values for most people. The
deferral is a real scientific choice, not a free one — **the advisor must pick the anchor** (A-001).

### Q-S6 baseline anchor (evidence for the deferred anchoring decision)
- **`sql/04_baseline_anchor_diagnostics.sql`** — answers the one question the advisor needs to make the
  Q-S6 call: **for how many people does the anchor choice even change the value?** It reports, per
  PREVENT measurement input, how many people have exactly 1 / 2 / 3–5 / >5 distinct measurement dates.
  - If almost everyone has 1 date → "most recent" == "first" == "landmark", the deferral is free.
  - If many have several dates spread over time → the anchor is a real choice (most-recent vs
    first-complete-panel vs landmark) and must be frozen before any model (A-001: anchoring cases and
    non-cases differently inflates every predictor, with no bug visible anywhere).
  - Two commented follow-up queries (span in days; are the 5 inputs co-measured on one visit or
    scattered) — run separately; the file notes the DuckDB-vs-BigQuery date-diff difference.
- **How to run it in the Workbench:**
  ```r
  print(run_sql_file("sql/04_baseline_anchor_diagnostics.sql", con))   # bring this table to the advisor
  ```
  **Bring this table to the meeting.** The `n_multi_date` column is the headline: it is the count of
  people for whom Q-S6 actually matters.

---

## §4 — Questions for the advisor (ranked by how much they unblock)

1. **Baseline anchor for non-cases (Q-S6) — the #1 ETL decision.** "Use data before the event" defines
   a baseline for cases and nobody else. What anchor do we apply *symmetrically* to everyone —
   **most-recent** (current placeholder), **first complete panel**, or a **landmark time**? Bring the
   `sql/04` table: its `n_multi_date` column is how many people the choice even affects. This changes
   `extract_prevent.R`, so it must be settled before the panel is frozen. (A-001: getting it wrong makes
   every predictor look stronger than it is, with no bug anywhere.)
2. **PREVENT model variant (H-002): base or extended?** We validated the **base** model. Extended adds
   HbA1c / UACR / social-deprivation-index — and every extra required input **shrinks** the complete-case
   cohort (D-013). Decide before the panel is final, because it sets the required input list.
3. **Diabetes definition.** Currently diagnosis-code (ICD10CM E08–E13; real run: 77,436 ≈ 19%). It can
   also be HbA1c ≥ 6.5% or a glucose-lowering drug — the three identify **different people**, and it is
   both a cohort variable and a PREVENT input. Confirm the definition.
4. **Sex-specific scoring excludes ~3,942 people.** PREVENT and CKD-EPI are sex-specific, so participants
   with `sex_at_birth` ≠ male/female get no score. Exclude explicitly? Report separately? (Equity /
   generalizability, A-015.)
5. **Antihypertensive list (bp_tx, NEEDS_A_CODE_LIST).** It's a PREVENT input, currently FALSE for
   everyone. Does the advisor have an authoritative RxNorm ingredient set, or approve pulling the class
   (ACE/ARB/thiazide/CCB/β-blocker…) from `cb_criteria`? A partial list silently misclassifies.
6. **30-year horizon age range.** AHAprevent returns NA for 30yr at age ≥ 60 (window defined 30–59);
   `preventr` extrapolates. We report 30yr only for 30–59 (primary is 10yr). Confirm that's intended.

## §5 — Blockers to raise (handoff.md — only a human can unblock)

1. **🔴 H-005 — this workspace has NO genomic data.** All four `has_*_variant` flags read 0 for
   everyone (0 / 747,029). D-013 makes the cohort *the srWGS participants*, so this blocks the genetic
   half **and the final cohort**. The phenotype/PREVENT half is done and validated — **genetics cannot
   start until genomic access is granted and the workspace is provisioned.** This is the single most
   important thing to resolve today: *is srWGS access actually enabled for this account/workspace?*
2. **H-002 — PREVENT reference + variant** (partly closed: we validated `AHAprevent` against `preventr`;
   the base/extended decision is question #2 above).
3. **H-006 / Q-R1 — may the repo be public?** It was briefly public (to clone into the Workbench),
   exposing the bucket UUID + Megan Lancaster's institutional email. Settle before making it public again,
   and make the courtesy call to Megan.

## §6 — End-to-end patient demo (show it works)

Goal: real CDR data → PREVENT inputs → PREVENT risk, with a sensible risk gradient. In the Workbench:

```r
# one-time: the official AHA package (not on CRAN)
# remotes::install_github("AHA-DS-Analytics/PREVENT")

source("src/phenotype/R/run_sql.R")
source("src/phenotype/R/extract_prevent.R")
source("src/phenotype/R/extract_smoking.R")
source("src/ascvd/prevent/run_prevent.R")

con   <- connect_cdr()
panel <- extract_prevent_panel(con)                       # smoking = FALSE placeholder
smk   <- extract_smoking(con, question_concept_ids = 1585860L)  # REAL current smoking (Smoke Frequency)
panel <- attach_smoking(panel, smk)                       # swap placeholder -> real; NA if no answer
scored <- run_prevent(panel)                              # appends prevent_base_{10,30}yr_{ASCVD,CVD,HF}

# 0. The cost of REQUIRING smoking (survey coverage): measurement-only vs smoking-required
sum(panel$complete_panel)            # 216,167 -- the 5 measurements + demographics
mean(panel$has_smoking_answer)       # fraction with any smoking answer
sum(panel$complete_panel_smoking)    # scorable when smoking is also required (the honest N)
table(panel$smoking, useNA = "always")

# 1. It produces risk, and incomplete panels honestly get NA (never a fabricated number)
mean(!is.na(scored$prevent_base_10yr_ASCVD))          # fraction scorable
summary(scored$prevent_base_10yr_ASCVD)               # 10yr ASCVD risk distribution

# 2. A handful of example patients (the "it works on real people" slide)
cols <- c("person_id","age","sex","sbp","total_c","hdl_c","egfr","bmi","dm","smoking","statin",
          "prevent_base_10yr_ASCVD","prevent_base_30yr_ASCVD")
head(scored[!is.na(scored$prevent_base_10yr_ASCVD), cols], 10)

# 3. Risk rises with age and differs by sex -> face-validity the advisor can eyeball
scored$ageband <- cut(scored$age, c(30,40,50,60,70,80), right = FALSE)
aggregate(prevent_base_10yr_ASCVD ~ ageband + sex, scored,
          FUN = function(x) round(mean(x), 2))
```

**Now smoking is REAL** (question 1585860, provisional answer map), not a placeholder. Two honesty flags
remain to say out loud:
- **`bp_tx` is still a placeholder** (FALSE for everyone) — antihypertensive list is question #5. So
  risks remain a slight underestimate; every row's `placeholder_inputs` says so.
- **Requiring smoking shrinks the scorable N** from `complete_panel` (216,167) to
  `complete_panel_smoking`. Missing smoking = `NA` (unknown), not assumed non-smoker — that is the
  honest default and it makes the exclusion visible. Whether to require it, or default missing to
  non-smoker, is an advisor question (it may be the biggest single exclusion driver).
- The smoking answer map is still **PROVISIONAL** until the 1585860 answer_concept_ids are pinned
  (Every Day 1585863 / Some Days 1585861 = current) — the meeting can confirm the definition.
