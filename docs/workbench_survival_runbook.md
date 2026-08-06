# Workbench runbook — survival curves (preliminary)

**Goal:** Kaplan–Meier curves for incident ASCVD, plus the numbers behind them, in one call.
**Time:** ~10–20 minutes of wall clock, most of it the panel query.

This is the *preliminary* run — enough for a lab meeting, explicitly not the final analysis. The four
things that make it preliminary are listed in **Step 5** and are printed automatically with the
readout, so they cannot be left off the slide by accident.

> **Which cohort is this?** The **landmark** cohort — one shared baseline date, everyone's clock
> starts together. That is what a survival curve requires. It is **not** the case-anchored cohort
> (D-019, `risk_set_sampling.R`), which has no common time origin and answers a different question
> ("does PREVENT rank cases above controls?"). Both are live; don't mix them on one slide.

---

## Step 0 — pull the code (Workbench **Terminal** tab, not the R console)

The repo is private over HTTPS, so `git` prompts for credentials — and a prompt fired from R's
`system()` has nowhere to appear, so it just hangs. This has already cost one session.

```bash
cd ~/lancaster_lab && git pull
```

---

## Step 1 — run it

In the **R console**:

```r
setwd("~/lancaster_lab")
source("src/figures/survival_curves.R")

res <- run_survival_curves()
```

That is the whole run. With no arguments it:

1. **derives `end_of_followup`** from the CDR (max date across condition / procedure / measurement)
   rather than letting anyone guess it — a wrong cutoff silently rescales every rate;
2. **chooses the landmark** by walking 1-January candidates newest-first and taking the first that
   leaves ≥ 2 years of follow-up *and* ≥ 200 people with a complete panel — and **prints every
   candidate it tried**, so the choice is reviewable, not magic;
3. builds the at-risk set with smoking **required** and the 30-day panel-to-event rule (D-017);
4. writes the figures;
5. prints the cumulative-incidence tables and checks the rate against the published PREVENT rate;
6. writes `figures/survival_readout_<date>.txt` and copies the PNGs to the workspace bucket.

**To override the dates** (do this if you have a reason — the defaults are defensible, not sacred):

```r
res <- run_survival_curves(landmark        = as.Date("2018-01-01"),
                           end_of_followup = as.Date("2022-07-01"))
```

If `survival` is not installed here: `install.packages("survival")`, then re-run.

---

## Step 2 — read four things off the console before you trust any curve

| Section | What good looks like | What to do if it's wrong |
|---|---|---|
| `=== 1. dates ===` | landmark leaves 3–5 y of follow-up; `complete` in the tens of thousands | if `complete` is a few hundred, the landmark is too early — the panel is built **as of** that date |
| `=== 3. attrition ===` | the drop from "PREVENT panel" → "Scorable panel" is the smoking cost (~61%) | a much bigger drop → check `extract_smoking()` |
| `=== 4. ===` | cumulative incidence rising smoothly; `n_risk` still large at the last horizon | `n_risk` collapsing → follow-up is shorter than the horizons you asked for |
| `=== 5. ===` | acute check says **`PLAUSIBLE`** | see the verdict table below — **do not put figure 14 on a slide until this passes** |

### The literature check is the load-bearing one

A survival curve built on mis-ascertained events looks completely normal — smooth, monotone,
plausibly shaped, and wrong. Comparing the rate to a published rate is the only cheap defence.

| Verdict | Meaning | Action |
|---|---|---|
| `PLAUSIBLE` (4–12 /1000 PY) | in line with Khan et al.'s 4.15–4.30, adjusted for our older EHR-selected cohort | show the curve |
| `LOW` (<4) | under-ascertainment (EHR gaps, ICD10CM-only, inflated person-time) | say so on the slide; it bounds every downstream claim |
| `HIGH` (>12) | prevalent disease leaking in, or the CPT `929` over-capture | Layer 2 per-code counts say which |
| `STRUCTURAL DEFECT LIKELY` (<2 or >20) | not a population difference | fix before presenting |

Note the **broad** outcome is deliberately reported as `NOT COMPARABLE`. That is correct behaviour,
not a failure: the published rate is a hard-outcome rate, so only the acute-only curve can be checked
against it. Both are printed so nobody has to remember which is which.

---

## Step 3 — the figures

| File | What it shows | Anchor-dependent? |
|---|---|---|
| `13_attrition_to_at_risk.png` | every person between "has data" and "contributes an event" | landmark **date** only |
| **`14_cumulative_incidence.png`** | **the main curve** — KM complement, all ASCVD | landmark date only |
| **`15_cumulative_incidence_by_sex.png`** | same, split by sex (PREVENT is sex-specific) | landmark date only |
| **`17_..._broad_vs_acute.png`** | the D-016 outcome decision made visible — same at-risk set, two definitions | landmark date only |
| `16_observed_by_prevent_risk_PROVISIONAL.png` | observed vs predicted by risk quintile | **yes — Q-S6.** Caption says so; **don't crop it** |
| `10`–`12` | events by class, by year, age at first event | no |

Figures 14/15/17 use event **dates** and the landmark only — covariate values never enter, so the
unresolved Q-S6 baseline anchor **cannot** bias them. Figure 16 uses covariate **values**, which are
still the most-recent measurement, and for someone who had an event those can post-date it. Keep that
distinction on the slide.

Download from the workspace bucket in the Workbench file browser (the run copies them there), or:

```r
system(paste0("gsutil -m cp figures/*.png ", Sys.getenv("WORKSPACE_BUCKET"), "/figures/"))
```

---

## Step 3b — the figures comparable to the PREVENT validation paper

The paper validates PREVENT with **calibration plots**: predicted risk on x, observed on y, one point
per decile, a 45° reference line, stratified by sex. That is the figure to put beside theirs.

```r
source("src/figures/prevent_calibration.R")
cal <- make_prevent_calibration_figures(res)     # `res` from Step 1
```

| File | What it is |
|---|---|
| `18_km_by_prevent_risk.png` | KM curves by predicted-risk group — the *survival-curve* form. Curves should separate in order; that separation **is** discrimination. |
| `19_calibration_observed_vs_predicted.png` | the paper's figure. Points **below** the diagonal = PREVENT over-predicts. |
| `20_calibration_by_sex.png` | same, faceted by sex — PREVENT is sex-specific and a pooled plot can hide opposite-direction miscalibration. |

Three things this does differently from `16_observed_by_prevent_risk_PROVISIONAL`, each of which
would otherwise manufacture the very over-prediction the figure is testing for:

1. **Observed is Kaplan–Meier, not `events/N`.** A crude proportion counts everyone censored early as
   a non-event, understating observed risk — which reads as over-prediction by PREVENT. Figure 16 uses
   the crude proportion; these do not.
2. **The horizons are matched.** PREVENT predicts 10 years, we observe ~4–5. Predicted is converted to
   the observation horizon by `p_t = 1-(1-p10)^(t/10)`, and both axes are labelled with the horizon.
   Comparing 4.5-year observed to 10-year predicted is a units error that looks like a finding.
3. **Deciles are cut *within* sex** for figure 20, not pooled — a pooled cut puts most women in the low
   deciles and most men in the high ones, so each "decile" becomes mostly one sex.

**Harrell's C is printed alongside** (`cal$concordance`), because the paper reports C-statistics and it
is the one number the horizon mismatch cannot distort — concordance uses only the *ordering* of
predicted risk. When calibration is muddy, C is still clean. Report it.

Defaults worth knowing: `outcome = "acute"` (the paper's outcome is a hard outcome, so this is the
honest comparison — the opposite default from the incidence figures), and the horizon is the largest
whole year that 75% of people actually reach, so the top decile's KM estimate isn't resting on a
handful of people.

If it warns `NO calibration figures written` — nobody has both a PREVENT risk and follow-up. PREVENT
returns `NA` unless *every* input is present, so check `scorable_only` and the `bp_tx` / smoking inputs.

---

## Step 3c — the paper's **tables**, rebuilt on our cohort

The figures answer "does the shape look right". The tables are what a reader actually checks a
validation against, and they are the part of the paper we can restate line for line.

```r
source("src/ascvd/validation/paper_tables.R")
pt <- render_paper_tables(res, cal)               # prints both; writes reports/paper_tables_<date>.txt
```

| Table | What it holds | Ours vs theirs |
|---|---|---|
| **Table 1** — baseline characteristics | age, BP, lipids, BMI, eGFR, diabetes, smoking, treatment, follow-up, events, by sex | our at-risk set beside their derivation **and** external-validation columns |
| **Table 4** — model performance, ASCVD, base model | Harrell's C and the calibration slope, by sex | ours (one cohort, 95% CI) beside theirs (21 cohorts, median + IQI), with the **PCEs** as the ruler |

**Read Table 1 before Table 4, every time.** Our C will land below theirs, and most of the reason is
in Table 1 rather than in PREVENT: shorter follow-up, a different age spread, a different diabetes
prevalence. Showing the performance number without the cohort it came from invites "PREVENT does worse
in All of Us", which this analysis cannot support.

Four things the tables print with themselves, because each one turns a methods difference into an
apparent finding if a reader does not know it:

1. **Their interval is an IQI across 21 cohorts** — the spread *between populations*. Ours is a
   sampling CI inside one cohort. The row labels say which is which; do not merge them into one "95%"
   column.
2. **Their calibration slope is 10-year observed on 10-year predicted.** Ours is both at *our*
   horizon, after the constant-hazard rescale. The `Horizon, y` row carries this.
3. **Their observed risk models the competing risk of non-CVD death.** Ours is `1 - KM` with death
   treated as censoring, because no death table is wired — which biases our observed risk, and so our
   slope, **upward**. This is the largest methodological gap in the comparison.
4. **The PCE rows are theirs, not ours.** They are the scale: ~0.5 is what a badly calibrated slope
   looks like, ~1.05 is what a good one looks like. Our slope means little without both ends.

Rows we cannot fill (race, UACR, SDI, HF events, deaths) are printed **blank on our side with the
paper's value still shown**, so the gap is visible rather than quietly dropped.

**Tables 2 and 3 are deliberately absent.** They are hazard ratios meta-analyzed across the 25
derivation cohorts — reproducing them means *re-deriving* PREVENT, not validating it. We run the
published equation as published. The output file says so, for anyone who opens it outside this repo.

Same disclosure rules as the validation summary: aggregate only, counts under 20 suppressed, and
statistics derived from a suppressed count blanked. Read it before pasting it.

---

## Step 4 — bring the readout out

```r
res$summary_path                 # figures/survival_readout_<date>.txt
```

Open it and paste the contents back. It is aggregate-only — no `person_id`s, no exact dates.
**Check every cell is ≥ 20 before pasting** (H-006 small-cell suppression); the by-sex table at the
earliest horizons is where a small cell would show up.

The tables you'll want on the slide are in there:

```r
res$km          # cumulative incidence at 1-5 y, all ASCVD, with CI
res$km_acute    # the literature-comparable version
res$km_by_sex   # by sex
```

---

## Step 5 — say these four things out loud

They are printed with the readout because a preliminary result presented without them reads as final.

1. **Death is not wired in.** Competing risk is treated as censoring, which **overstates** incidence
   in an older cohort.
2. **ICD10CM only.** All of Us records before ~Oct-2015 are ICD9CM and are not matched, which
   left-truncates the early years and changes who counts as *prevalent*.
3. **Everyone event-free is censored at the CDR cutoff, not at last contact.** Person-time is
   inflated, so the rate is pushed **down**.
4. **Q-S6 (baseline anchor) is open.** Figures 14/15/17 are anchor-free and sound today; figure 16 is
   provisional until it is settled.

Plus the two standing caveats: **smoking is required** (so N is ~84k, not ~216k — state which N each
figure is on), and **`bp_tx` is PROVISIONAL** (it measures "on a BP-lowering drug", not "treated for
hypertension").

---

## If something breaks

| Symptom | Cause / fix |
|---|---|
| `unused argument (min_days_panel_to_event = ...)` | a **stale session**, not a bug in the call. An R session in the Workbench outlives a `git pull`, so functions from an older checkout stay defined and look fine. `run_survival_curves()` now re-sources every time and refuses to run on an old `make_incidence_figures()`, naming the cause. If you see it anyway: `git pull` in the Terminal, then restart R. |
| `make_incidence_figures() is an OLD version` | the guard above, working. The file on disk is behind — pull, and check `git log --oneline -1`. |
| `NOBODY has a complete panel as of the <date> landmark` | landmark too early. `run_survival_curves()` with no `landmark` avoids this automatically — it searches. |
| `choose_landmark(): no candidate landmark yields >= 200 complete panels` | check `derive_end_of_followup()` first; then `sql/02`. Don't just lower `min_n`. |
| `the survival package is not installed` | `install.packages("survival")` |
| `skipping figure 16: no PREVENT risk column` | `AHAprevent` not installed here, or `run_prevent.R` didn't source |
| `skipping figure 16: fewer than 20 scored people` | at-risk set too small — landmark is probably after most people's data |
| figures 14/15/17 missing, no error | zero events in the at-risk set. Check `=== 3. attrition ===` — if "Incident ASCVD" is 0, the outcome codes aren't matching (see the ICD10CM linkage trap). |
| `NEGATIVE follow-up` warning | landmark is after `end_of_followup` |
| counts wrong by a lot | `bigrquery` returns `integer64` — check for a coercion issue first |

---

## Offline (no Workbench)

```bash
Rscript src/figures/survival_curves.R
```

Runs against the DuckDB fixture and writes to `reports/figures_fixture_demo/`. **Layout QA only —
every number is synthetic.** It uses `scorable_only = FALSE` because the fixture has just 4 complete
panels, which is too few to carry an event; that setting would be wrong in the Workbench.
