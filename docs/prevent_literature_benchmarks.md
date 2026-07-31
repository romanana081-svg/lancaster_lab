# PREVENT literature benchmarks — what our numbers have to look like

**Written 2026-07-30**, ahead of the survival-curve work. Source: Khan SS et al., *Development and
Validation of the American Heart Association's PREVENT Equations*, **Circulation 2024;149(6):430–449**,
doi:10.1161/CIRCULATIONAHA.123.067626.

> **The paper is NOT paywalled.** The full text, including Table 1 and the worked example, is open at
> **PMC10910659**. `meeting.md` §2 and `test-prevent-crosscheck.R` both record that it was paywalled and
> that no worked example could be sourced — that was wrong, and it cost the project its cleanest
> validation gate for a week. Corrected here and at both sources.

The numbers below are transcribed into `configs/config.yaml` under `literature:`, and
`src/ascvd/validation/literature_benchmarks.R` checks a run against them.

---

## 1. The equation is now validated against the published worked example ✅

This is VALIDATION §1 **layer 3** — the external ground truth — and it was the one gate T-016 could not
close. The paper states, in its own text, the risks for one fully specified patient:

> A 50-year-old female, total cholesterol 240 mg/dL, HDL-C 55 mg/dL, no statin, **treated** SBP
> 160 mmHg, no diabetes, BMI 35 kg/m², eGFR 90 mL/min/1.73m².

| Quantity | Published | `run_prevent()` | Δ |
|---|---:|---:|---:|
| 10-yr CVD, non-smoker | 5.4% | **5.43** | +0.03 |
| 10-yr **ASCVD**, non-smoker | 3.6% | **3.64** | +0.04 |
| 10-yr HF, non-smoker | 2.5% | **2.53** | +0.03 |
| 10-yr CVD, smoker | 9.3% | **9.26** | −0.04 |
| 10-yr **ASCVD**, smoker | 6.0% | **5.99** | −0.01 |
| 10-yr HF, smoker | 4.7% | **4.70** | 0.00 |
| 30-yr CVD / ASCVD / HF, non-smoker | 31 / 20 / 19% | **30.67 / 19.86 / 18.48** | −0.33 / −0.14 / −0.52 |
| 30-yr CVD / ASCVD / HF, smoker | 40 / 26 / 26% | **39.76 / 25.91 / 26.09** | −0.24 / −0.09 / +0.09 |

**Eleven of twelve are inside the paper's own rounding.** The twelfth — 30-yr HF for the non-smoker,
18.48 vs a printed 19 — is a rounding boundary: a true value of 18.50 prints as 19, so 0.02 in the
underlying number becomes a whole unit. The smoker's 30-yr HF agrees exactly (26.09 vs 26), which is
what says this is rounding and not a broken HF path. It touches nothing we use: our outcome is
**10-year ASCVD**, and HF is not a study outcome.

Pinned in `tests/testthat/test-prevent-published-example.R` (10 assertions). Tolerance is **0.05pp on
the 10-year block** and 0.6pp on the 30-year block, because the paper prints 10-year risks to 0.1pp and
30-year risks to whole percent. **Do not widen the 10-year tolerance.**

This complements rather than replaces `test-prevent-crosscheck.R`: two packages agreeing proves they
implement the *same* equation; this proves ours matches the *paper*. They fail for different reasons.

---

## 2. The published event rates — the benchmark for our survival curves

From Table 1. Rates are **derived** (events ÷ N × mean follow-up); the paper prints counts, not rates.

| | N | mean FU | ASCVD events | **ASCVD /1000 PY** | CVD events | CVD /1000 PY |
|---|---:|---:|---:|---:|---:|---:|
| Derivation, female | 1,839,828 | 4.8 y | 31,812 | **3.60** | 53,258 | 6.03 |
| Derivation, male | 1,442,091 | 4.6 y | 34,691 | **5.23** | 53,403 | 8.05 |
| Derivation, pooled | 3,281,919 | — | 66,503 | **4.30** | 106,661 | 6.90 |
| Validation, pooled | 3,330,085 | — | 67,902 | **4.15** | 104,854 | 6.41 |

Arithmetic check that these were read off correctly: the two samples sum to **6,612,004 people and
211,515 total CVD events**, which is exactly what the abstract states. A test asserts this.

Population: ages **30–79**, primary prevention, **mean age ~52.6**, 56% female. Discrimination in
external validation (base model, ASCVD): **C = 0.774 female, 0.736 male** — that is the target for
T-007, not something we should expect to beat.

**Headline: roughly 4 ASCVD events per 1000 person-years.** Men run ~45% higher than women.

---

## 3. What that implies for our curves — the numbers to check tomorrow

Our cohort differs from the paper's in ways that push in **both** directions, which is why the
acceptance band is wide rather than a point estimate:

| Pushes our rate **UP** | Pushes our observed rate **DOWN** |
|---|---|
| Median age **58** vs the paper's mean 52.6 — ASCVD risk roughly doubles per decade | All of Us EHR capture is partial; care outside the contributing site is invisible (A-006) |
| Complete-panel selection = sustained healthcare contact, so more comorbidity (A-015) | Administrative censoring at the CDR cutoff — **nobody is censored at last contact**, so person-time is overstated and the rate diluted |
| No competing-risk handling: death is treated as censoring, overstating incidence | ICD10CM-only ascertainment misses pre-2015 (ICD9) events |

**Expected band: 4–12 ASCVD events per 1000 person-years**, centred around 6–7. Outside **2–20**,
suspect a structural defect rather than a population difference.

Concretely, for the planned figures (`landmark 2018-01-01 → end_of_followup 2022-07-01`, 4.5 years):

| At-risk N | Rate | Expected events | 4.5-y cumulative incidence |
|---:|---:|---:|---:|
| ~70,000 | 4.0 (published) | ~1,260 | 1.8% |
| ~70,000 | **6.5 (our central expectation)** | **~2,050** | **2.9%** |
| ~70,000 | 12.0 (upper band) | ~3,780 | 5.4% |

At-risk N starts from the **84,176** scorable-with-smoking panel, minus prevalent ASCVD and minus
anyone with no follow-up after the landmark — so ~65–76k is the plausible range, and the *attrition
from 84,176 to the at-risk N is itself a number to report*, not a detail.

**So: `14_cumulative_incidence.png` should reach roughly 2–4% at 4.5 years.** A curve that tops out
near 15% or near 0.3% is not a finding, it is a bug — and the two failure modes are distinguishable:

- **Too high** → prevalent disease leaking into the at-risk set (pre-2015 ICD9 blindness hides the
  prior event, so a long-standing CAD patient looks incident), `chronic_disease` codes being counted as
  acute events, or the known **CPT `929` over-capture** (92950 CPR, 92960 cardioversion are not ASCVD
  events). Layer 2 of `workbench_report()` gives the per-code counts to prove which.
- **Too low** → EHR capture gaps, or person-time inflated by censoring everyone at the CDR cutoff.

**Third check, and the most interesting one:** if PREVENT were well calibrated here, observed 4.5-year
incidence ≈ **0.45 × mean predicted 10-year risk**. Compute both and compare — that is the first real
look at **T-007 / DESIGN stage 5**, the miscalibration question that the whole offset design (D-006)
depends on. Expect PREVENT to *over*-predict against under-ascertained EHR outcomes; the size of the
gap is the result.

---

## 4. How to run the check in the Workbench

After the incidence figures, one extra call:

```r
source("src/ascvd/validation/literature_benchmarks.R")

# `status` is the frame from ascvd_status_at() -- prevalent people carry event = NA and are
# correctly left out of the denominator.
check_incidence_from_status(status, label = "acute ASCVD, landmark 2018-01-01")

# or from raw numbers, if you already have them:
check_incidence_vs_literature(n_events = 2050, person_years = 315000, n_at_risk = 70000)
```

It prints the observed rate, the published rates, the band, a verdict
(`PLAUSIBLE` / `LOW` / `HIGH` / `STRUCTURAL DEFECT LIKELY`), and the most likely cause of a miss.
It is a **smoke alarm, not a hypothesis test** — the answer to a red verdict is "find out why before
the curve goes on a slide", not "the study failed".

Report both the with- and without-revascularisation outcome (`include_revascularisation:
report_both`). The published 4.15–4.30 is a **hard-outcome** rate (MI, stroke, CV death) — closest to
our `acute_event` class, so that is the comparison. Adding revascularisation will legitimately push
our number above the published rate, and saying so is the difference between a benchmark and a coincidence.
