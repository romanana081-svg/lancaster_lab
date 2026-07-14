# ASSUMPTIONS.md

**Every assumption belongs here. None may be hidden inside code.**

If you write a line of code that only works because something is true, and that something is not
guaranteed, it is an assumption — write it down here and link to it from the code with a comment
like `# A-004`.

Why this matters: the assumptions in an epidemiological pipeline are where wrong answers come from.
They are almost never wrong in a way that raises an error; they are wrong in a way that quietly
shifts an estimate. The only defence is to enumerate them, so a reviewer can attack them.

**Risk key:** 🔴 could change the study's conclusion · 🟠 could bias a result · 🟡 could cost data or
convenience · ⚪ bookkeeping

**Template**

```
## A-0NN — <statement, in one sentence, as a claim that could be false>
- Risk: 🔴/🟠/🟡/⚪
- Status: UNVERIFIED | VERIFIED | REFUTED | ACCEPTED-AS-LIMITATION
- Where it bites:   the code/analysis that depends on it
- Why we assume it: the justification
- How to test it:   the concrete check that would confirm or refute it
- If it's wrong:    the consequence
```

---

## Inherited from the existing phenotyping notebook

These were not chosen by this project — they are baked into `LDLR Get phenotypes.ipynb` and are
inherited the moment we reuse it (D-002). They are listed first because they are the easiest to
adopt without noticing.

### A-001 — A person's **earliest** recorded measurement is the right one to use
- **Risk:** 🔴
- **Status:** UNVERIFIED
- **Where it bites:** every "Format" section of the notebook —
  `group_by(person_id) %>% filter(date == min(date))`. It sets LDL, triglycerides, and BMI.
- **Why we assume it:** the earliest value is closest to a "baseline, pre-treatment" state, and using
  a later value risks conditioning on treatment or on disease that has already begun.
- **How to test it:** compare the distribution of earliest-vs-median-vs-closest-to-index values; check
  how many people's earliest lipid panel predates their first statin.
- **If it's wrong:** the "baseline" value may be measured *after* treatment started, or years before
  the index date, biasing PREVENT's inputs. **For a prediction study, the correct anchor is the value
  at the index date, not the earliest value ever recorded** — so this assumption is probably *wrong
  for our purposes* even though it was right for the original LDLR study. Resolving this is part of
  T-003 and Q-S1.

### A-002 — Same-day duplicate measurements can be broken arbitrarily
- **Risk:** 🟠
- **Status:** **REFUTED as safe — confirmed non-deterministic**
- **Where it bites:** `distinct(person_id, .keep_all = TRUE)` after the `min(date)` filter.
- **Why we assume it:** duplicates on the same day were presumed to be near-identical.
- **How to test it:** done. The synthetic fixture (person `1000006`) has same-day LDL values of 130,
  131, 132. The generated SQL has **no `ORDER BY`**, so which row survives is arbitrary and can
  differ between runs. The fixture's answer key therefore asserts *membership* (`one_of:130|131|132`),
  not a value.
- **If it's wrong:** results are not bit-reproducible. **This must be fixed with an explicit
  deterministic tie-break** (e.g. order by value, or take the mean of same-day values) before any
  analysis is published. Tracked in T-005.

### A-003 — Only `unit_source_value == 'mg/dL'` rows are usable lipid measurements
- **Risk:** 🟠
- **Status:** UNVERIFIED
- **Where it bites:** the unit filter in each measurement cleaning block.
- **Why we assume it:** All of Us unit strings are inconsistent; restricting to one unit avoids
  mixing scales.
- **How to test it:** `group_by(unit_source_value) %>% summarize(n = n())` on the full measurement
  table and count how many rows (and *people*) are discarded.
- **If it's wrong:** the filter is **case-sensitive and exact**, so `mg/dl`, `MG/DL`, and
  `mg/dL ` (trailing space) are silently dropped. A person whose *only* lipid panel is recorded as
  `mg/dl` vanishes from the analysis entirely, with no warning. The fixture reproduces this
  (defect A1). Mitigation: normalise units, and convert mmol/L rather than discarding it.

### A-004 — Physiologic bounds: LDL and triglycerides `>1 & <1000 mg/dL` (LDL further `<400`), BMI `>14 & <60`
- **Risk:** 🟡
- **Status:** UNVERIFIED
- **Where it bites:** the outlier filters in each cleaning block.
- **Why we assume it:** values outside these are almost certainly data-entry errors.
- **How to test it:** count and inspect the excluded rows; check whether excluded people differ
  systematically from included ones.
- **If it's wrong:** the LDL `<400` cap **removes exactly the people this study cares most about** —
  untreated familial hypercholesterolemia patients routinely have LDL > 400 mg/dL. Filtering them out
  would systematically delete the strongest rare-variant carriers. 🔴 **This bound must be revisited
  before any genetic analysis** (T-003).

### A-005 — LDL equal to triglycerides in the same row indicates a data defect, and such rows should be dropped
- **Risk:** 🟡
- **Status:** VERIFIED (as a defect; the *handling* is unverified)
- **Where it bites:** the notebook's `### Troubleshooting` cells compute `diff = LDL - Trig` and drop
  `diff == 0`. **Note this filter is applied only in the scratch frame `ldl_trig`, not to the
  `ldl_df`/`trig_df` used in the main join** — so the defective rows may still be in the analysis.
- **How to test it:** count rows where LDL == Trig in the final phenotype table.
- **If it's wrong / unhandled:** contaminated lipid values feed PREVENT.

### A-006 — Absence of an EHR code means absence of disease
- **Risk:** 🔴
- **Status:** ACCEPTED-AS-LIMITATION
- **Where it bites:** every binary phenotype (`CAD_code`, `PAD_code`, `FH_code`, diabetes, smoking…),
  which is set to 0 when no matching code is found.
- **Why we assume it:** EHR data offers no alternative; there is no "confirmed absent" record.
- **How to test it:** cannot be tested internally. Bound it by comparing observed prevalence against
  published population prevalence, and by restricting to people with sufficient EHR density.
- **If it's wrong:** this is **outcome misclassification**, and it is non-random — people with less
  healthcare contact look healthier. It biases risk estimates and can distort the genetic association
  if EHR density correlates with ancestry or socioeconomic status. Mitigation: require a minimum
  number of visits / a minimum follow-up window before a person is eligible (Q-A2).

### A-007 — `has_whole_genome_variant = 1` in `cb_search_person` correctly identifies the srWGS cohort
- **Risk:** 🟡
- **Status:** UNVERIFIED
- **Where it bites:** the cohort gate in all 13 generated SQL queries.
- **How to test it:** cross-check the count against the published CDR v7 srWGS figure (~245,000).
- **If it's wrong:** the analysis cohort is wrong at the root.

---

## Introduced by this project

### A-008 — The AHA PREVENT equations are applicable to the All of Us population
- **Risk:** 🔴
- **Status:** UNVERIFIED — **and we expect it to be partly false**
- **Where it bites:** everything. PREVENT is the baseline (D-004) and its linear predictor is the
  offset in the primary model (D-006).
- **Why we assume it:** it is the current AHA-recommended model and the relevant state of the art.
- **How to test it:** DESIGN.md §5, stage 5 — measure PREVENT's discrimination and calibration in
  All of Us, overall and stratified by sex and genetic ancestry.
- **If it's wrong:** if PREVENT is miscalibrated in All of Us (likely — different population, EHR
  rather than trial-quality outcomes), then **the genetic term in the offset model can absorb that
  miscalibration and appear significant when it carries no genetic information at all.** This is the
  single most dangerous failure mode of the study, and stage 5 exists solely to guard against it.

### A-009 — Gene-level aggregation of rare variants preserves the signal
- **Risk:** 🟠
- **Status:** UNVERIFIED
- **Where it bites:** D-008; the construction of the scalar burden term `G`.
- **Why we assume it:** individual rare variants have no power; aggregation is the standard remedy.
- **How to test it:** positive control — the burden term in `LDLR` should associate with LDL
  cholesterol. **If it does not, the genetic pipeline is broken and no downstream result is
  trustworthy.** This is the designated sanity check for T-008.
- **If it's wrong:** a directional burden score cancels out variants of opposite effect and can
  destroy a real signal (this is why SKAT-O exists).

### A-010 — Follow-up in All of Us is long enough to observe incident ASCVD
- **Risk:** 🔴
- **Status:** UNVERIFIED
- **Where it bites:** the entire survival analysis; the choice of a 10-year vs 30-year PREVENT horizon.
- **How to test it:** describe the distribution of follow-up time and count observed events. Compute
  power for the expected event count.
- **If it's wrong:** too few events → the study is underpowered and a null result is uninformative
  (which is *not* the same as a negative result). **This must be checked before, not after, the
  analysis** — it may change the outcome definition or force a broader endpoint. Q-S4.

### A-011 — Genetic ancestry and relatedness can be adequately handled by covariates and exclusions
- **Risk:** 🟠
- **Status:** UNVERIFIED
- **Where it bites:** the genetic association models.
- **Why we assume it:** standard practice is principal components as covariates plus removal of close
  relatives (or a mixed model, e.g. SAIGE, which handles both).
- **How to test it:** genomic inflation (λ_GC), QQ plots, and a null-variant negative control.
- **If it's wrong:** population stratification produces false-positive associations. All of Us is
  deliberately ancestrally diverse, which makes this a *larger* risk here than in a homogeneous
  biobank — and diversity is one of the main reasons to use All of Us at all.

### A-012 — The committed notebook's cell outputs contain no identifiable participant data
- **Risk:** 🔴 (governance, not science)
- **Status:** ✅ **VERIFIED 2026-07-14 (T-012) — vacuously true: there are no outputs at all**
- **Where it bites:** `LDLR Get phenotypes.ipynb`, and any push to a non-private remote.
- **How it was tested:** parsed the notebook JSON directly, and *every version of it in git history*.
  Result: **291 code cells, all with `outputs: []` and `execution_count: null`.** Zero output bytes,
  in the working tree and in both historical commits (`41791cc`, `832f3e2`). The notebook was
  stripped before it ever entered this repository.
- **The 180 KB has an innocent explanation.** CLAUDE.md asserts the file is large *"because it is
  committed with outputs"*. That is **false**. The size is 101 KB of *source* — the auto-generated
  All of Us SQL strings run to ~6 KB per cell — plus JSON overhead. The premise was wrong, so the
  conclusion drawn from it was too.
- **Consequence:** the repository does **not** carry controlled-tier participant data, and never did.
  The highest-urgency governance blocker is **cleared**. This does not by itself make the repo
  publishable — see A-014, which is what the audit *did* find.

### A-014 — Hardcoded workspace identifiers in the notebook are safe to publish
- **Risk:** 🟠 (governance, not science)
- **Status:** **REFUTED as safe — the identifiers are real, and they are tracked in git**
- **Where it bites:** 13 cells of `LDLR Get phenotypes.ipynb` hardcode the workspace GCS bucket and
  the owner's institutional email:
  `gs://fc-secure-7e84f6f0-9e03-4626-b34e-6dcf5d5f1701/bq_exports/megan.lancaster@researchallofus.org/…`
  The **synthetic fixture replicates those literal paths as directory names**, so the same bucket UUID
  and email are also committed as ~24 tracked file paths under `fixture/bucket/`.
- **What this is and is not.** It is **not** participant data — no controlled-tier content is exposed,
  and A-012 is clean. It *is* a private All of Us workspace identifier plus a named researcher's email,
  published in a public repository. The bucket is access-controlled, so the UUID is not a credential;
  but it is an internal identifier that nothing is gained by publishing, and the email is a real
  person's.
- **How to test it:** done — `T-012`'s scan. Confirmed: 13 source cells, 0 API keys, 0 reported counts
  in markdown.
- **If it's wrong:** low-severity information disclosure, not a data-policy breach. **But the fix is
  entangled:** the notebook's "Format" cells resolve those `gs://` paths *as literals*, and the fixture
  is built to mirror them exactly so the notebook runs unmodified offline (`fixture/README.md`).
  Parameterising the paths therefore means changing the notebook **and** rebuilding the fixture and its
  answer key together — which is why it is a decision (Q-R3), not a tidy-up. It also runs straight into
  the CLAUDE.md rule against silently "fixing" the notebook's load-bearing quirks.

### A-013 — The synthetic fixture is representative enough to validate the ETL
- **Risk:** 🟡
- **Status:** ACCEPTED-AS-LIMITATION
- **Where it bites:** all offline tests (D-003).
- **Why we assume it:** the fixture reproduces the *structure* and the *known defect classes*, not
  the real distributions, and it is 300 people rather than 245,000.
- **If it's wrong:** the fixture can prove code is broken; it cannot prove code is correct on real
  data. It catches structural and logical bugs, not distributional ones. Documented in
  `FORMAT.md` §10.
