# GLOSSARY.md

**This file exists to teach.** Every technical term used anywhere in this repository is defined here,
for someone who has never seen it before.

Each entry follows the same shape:

> **What it is** · **Why it matters here** · **How it's used in this project** · **Common mistakes**
> · **Where it appears** · **Reading**

Jump to: [Data & infrastructure](#1-data--infrastructure) · [Epidemiology](#2-epidemiology--study-design) ·
[Prediction models](#3-prediction-models) · [Model evaluation](#4-how-we-judge-a-prediction-model) ·
[Survival analysis](#5-survival-analysis) · [Genetics](#6-genetics)

---

## 1. Data & infrastructure

### OMOP CDM (Observational Medical Outcomes Partnership Common Data Model)
**What it is.** A standard way of reshaping any hospital's messy electronic health record into a
fixed set of tables with fixed column names: `person`, `condition_occurrence`, `measurement`,
`drug_exposure`, `visit_occurrence`, and so on. Every clinical fact becomes a row pointing at a
numeric **concept ID** drawn from a shared vocabulary.

**Why it matters here.** It is why the same analysis code can, in principle, run on All of Us, the
UK Biobank, or a hospital system — you write against the model, not against one institution's schema.

**How it's used.** All 13 SQL queries in `fixture/build/queries/` are OMOP queries. "Get me everyone
with a myocardial infarction" becomes "get me every `condition_occurrence` row whose
`condition_source_concept_id` is in this list of 94 numbers."

**Common mistakes.**
- Confusing `*_concept_id` (the *standard*, harmonised concept — usually SNOMED) with
  `*_source_concept_id` (the *original* code the hospital actually billed — ICD-9/ICD-10). They are
  different columns with different numbers, and picking the wrong one silently returns nothing.
- Assuming a concept ID means what its name suggests. Always check the vocabulary.

**Where it appears.** `FORMAT.md` §3; `sql/`; the entire R phenotyping half.

**Reading.** *The Book of OHDSI*, chapters 4–6 — free at <https://ohdsi.github.io/TheBookOfOhdsi/>.

---

### All of Us / CDR / Controlled Tier
**What it is.** *All of Us* is an NIH program enrolling a million-plus US participants, deliberately
oversampling groups historically underrepresented in biomedical research. The **CDR** (Curated Data
Repository) is a periodic snapshot of all that data in OMOP form; we use **v7**. The **Controlled
Tier** is the access level that includes genomic data and full dates — it requires training,
institutional agreement, and **all analysis must happen inside the Researcher Workbench**, a cloud
environment. Data cannot be downloaded.

**Why it matters here.** It is both the reason the study is possible (a quarter-million sequenced
genomes with linked EHR) and the reason it is awkward (nothing runs on your laptop, so we built a
synthetic stand-in — `fixture/`).

**Common mistakes.** Pasting real results — even a table of counts — into a public place. Aggregate
results have small-cell suppression rules. When in doubt, do not export it.

**Where it appears.** Everywhere. `DESIGN.md` §8 is the governance rule.

---

### srWGS (short-read whole genome sequencing)
**What it is.** Sequencing the whole genome in short fragments (~150 bases) and reassembling. Unlike
a genotyping *array*, which only checks a pre-chosen set of ~1 million common positions, sequencing
observes positions no one chose in advance — including variants seen in only one person.

**Why it matters here.** **Rare-variant analysis is impossible with array data.** Arrays are designed
around common variants; the rare ones we care about are simply not on the chip. The srWGS subset
(~245,000 people in CDR v7) *is* the analysis cohort, which is why every query filters on
`has_whole_genome_variant = 1`.

**Where it appears.** The cohort gate in all 13 SQL queries; `A-007`.

---

### Concept ID / vocabulary / `cb_criteria`
**What it is.** A concept ID is an integer naming a clinical idea (`3028288` = "LDL cholesterol").
`cb_criteria` is an All of Us-specific table storing the *hierarchy* — so that selecting "ischemic
heart disease" can automatically pull in all its child codes.

**Common mistakes.** The hierarchy walk in the generated SQL depends on `cb_criteria.path`,
`full_text`, `is_standard`, and `is_selectable` all being right. **Get one wrong and the query
returns zero rows with no error message.** This is the loudest silent failure in the codebase, and it
is exactly why the fixture runs the notebook's real SQL rather than mocking the dataframes (D-003).

---

## 2. Epidemiology & study design

### ASCVD (atherosclerotic cardiovascular disease)
**What it is.** Disease caused by plaque building up in arteries: heart attack (myocardial
infarction), coronary heart disease death, and stroke. (Peripheral artery disease is atherosclerotic
too, and whether to include it is an open question here.)

**Why it matters here.** It is the outcome. Everything hinges on defining it exactly — see Q-A1,
which is blocked on the advisor.

**Common mistakes.** Silently mixing definitions. "ASCVD" in one paper may include heart failure;
PREVENT's headline endpoint is *total CVD* (ASCVD **plus** heart failure), with ASCVD as a sub-outcome.
If our outcome definition does not match the PREVENT equation we use, the comparison is meaningless.

---

### Incident vs. prevalent disease
**What it is.** **Prevalent** = the person already has the disease when the study clock starts.
**Incident** = they develop it during follow-up.

**Why it matters here.** This is the difference between a valid study and an invalid one. A
prediction model predicts the *future*. Someone who had a heart attack in 2015 cannot "develop" one
during 2020–2025 follow-up. Including them makes the model look prophetic because it is really just
detecting disease that already happened.

**How it's used.** PREVENT is a **primary prevention** model: it is only defined for people *without*
prior CVD. So we must find and exclude prevalent cases — which is exactly what the notebook's
`# Get censored ages` section (still marked IN PROGRESS) is for. That section is load-bearing.

**Common mistakes.** Assuming the earliest diagnosis code is the true disease onset. EHR data begins
when the person joined the health system, not when they got sick. A code appearing in 2019 might be
someone's *twentieth* year with the disease.

**Where it appears.** `DESIGN.md` §2; `A-006`; Q-A1; Q-A2.

---

### Immortal time bias
**What it is.** A bias created when the study design guarantees survival for some stretch of time.
If you define time zero as "the first visit where all lab values are available", then everyone in
your cohort by construction survived long enough to have that visit — you have built survival into
the entry criterion.

**Why it matters here.** Our index date is not yet defined (Q-S1), and the naive choice ("first visit
with complete PREVENT inputs") is exactly this trap.

**Common mistakes.** Using information from *after* time zero to decide who enters the cohort or when
their clock starts. The rule: **an eligibility criterion may only use information available at or
before time zero.**

---

### Censoring
**What it is.** We stop observing someone before we see the outcome — they moved away, the study
ended, or they died of something else. We know they were event-free *up to* that point, and nothing
after.

**Why it matters here.** Almost everyone in the cohort is censored; only a minority have events.
Survival analysis exists precisely to use censored people's partial information instead of throwing
them away.

**Common mistakes.** Treating censoring as if it were "no event" (this systematically underestimates
risk). Assuming censoring is **non-informative** — i.e. that leaving the study is unrelated to being
about to have a heart attack. In EHR data that assumption is shaky: people who stop showing up may be
sicker, or may be healthier.

**Where it appears.** `DESIGN.md` §2; the notebook's `CAD_censored_date` logic.

---

### Competing risk
**What it is.** An event that makes the outcome of interest impossible. Death from cancer is a
competing risk for heart attack: once it happens, you cannot subsequently have one.

**Why it matters here.** The cohort is 30–79 years old and followed for years; non-CVD death is
common. Standard Cox models treat competing deaths as ordinary censoring, which **overestimates**
the absolute risk of ASCVD.

**How it's used.** Fine–Gray subdistribution models are the planned sensitivity analysis (DESIGN.md
§5, stage 8).

**Reading.** Austin & Fine, "Introduction to the analysis of survival data in the presence of
competing risks", *Circulation* 2016.

---

## 3. Prediction models

### PREVENT (AHA Predicting Risk of CVD EVENTs)
**What it is.** The American Heart Association's 2023/2024 risk equations (Khan SS et al.,
*Circulation* 2024). Given age, sex, total cholesterol, HDL-C, systolic blood pressure,
antihypertensive use, diabetes, current smoking, BMI, and eGFR, it predicts 10-year and 30-year risk
of cardiovascular disease. Optional extensions add HbA1c, urine albumin-creatinine ratio, and a
social deprivation index.

**Why it matters here.** It is the baseline (D-004). The whole study asks whether genetics adds
anything **on top of** PREVENT.

**Notable properties.** It deliberately **removed race** as an input (its predecessor, the Pooled
Cohort Equations, included it as if it were biological). It **added kidney function**, making it a
harder baseline to beat.

**Common mistakes.**
- Applying it to people who already have CVD. It is a *primary prevention* model.
- Applying it outside ages 30–79.
- Assuming it is calibrated in your population. It almost certainly is not (A-008), and checking is
  mandatory here.

**Where it appears.** `src/aou_ascvd/prevent/`; T-006; D-004; D-006.

---

### Linear predictor, and using it as an *offset*
**What it is.** A risk model computes a weighted sum: `LP = β₁·age + β₂·cholesterol + …`. That sum is
the **linear predictor** — one number per person, on the log-hazard scale, summarising everything the
model knows.

An **offset** is a term in a regression whose coefficient is *fixed at 1* rather than estimated. It
tells the model: "take this as given; do not touch it; explain what is left."

**Why it matters here.** This is *the* methodological idea of the project. To ask "does genetics add
anything beyond PREVENT?", you fit:

```
hazard(t) = h₀(t) · exp( offset(LP_PREVENT) + γ · G_genetic )
```

and test whether `γ = 0`. Because the PREVENT part is frozen, `γ` measures purely what genetics
explains **beyond** it. That is a literal formalisation of "residual risk".

**Common mistakes.** The tempting alternative — refit a model with genetics *and* all the clinical
variables, then compare C-statistics to PREVENT's — silently **re-estimates the clinical
coefficients**, so it answers "is a freshly-fitted model better?" rather than "does genetics add
information?". It flatters the new variable and is a common flaw in weak papers.

**Where it appears.** `DESIGN.md` §1.3 and §6; D-006.

---

## 4. How we judge a prediction model

These three are *different questions*, and conflating them is the most common error in the
prediction-model literature.

### Discrimination — "can it tell them apart?"
**What it is.** Given one person who has an event and one who doesn't, does the model give the first
a higher risk? Measured by the **C-index** (concordance) or **AUC**. 0.5 = coin flip; 1.0 = perfect.

**Common mistakes.** **Expecting ΔC-index to move.** It is famously insensitive: adding a genuinely
useful predictor to an already-good model often changes C by 0.005 or less. A small ΔC is **not**
evidence that the predictor is useless — that inference is a false negative waiting to happen. This
is precisely why D-007 requires reporting calibration and clinical utility as well.

---

### Calibration — "are the numbers right?"
**What it is.** Of the people the model says have a 10% risk, do about 10% actually have events?
Measured by calibration slope and intercept, the **ICI** (integrated calibration index), and
calibration plots by risk decile.

**Why it matters here.** A clinician acts on the *absolute number* ("your 10-year risk is 12%, let's
start a statin"). A model can discriminate beautifully and still be systematically wrong about
absolute risk — and then it is dangerous.

**Common mistakes.** Reporting only the C-index and never checking calibration. This is extremely
common and it is how miscalibrated models reach clinics.

**And the specific danger here:** if PREVENT is miscalibrated in All of Us (A-008) and we do not
detect and handle it, the genetic term in the offset model can quietly absorb that miscalibration and
look significant while carrying no genetic information at all. That is the study's most dangerous
failure mode.

---

### NRI (Net Reclassification Improvement)
**What it is.** Of the people who had events, how many did the new model move *up* a risk category?
Of those who didn't, how many moved *down*? NRI combines these into one number.

**Why it matters here.** Reviewers will ask for it.

**Common mistakes.** Trusting it. NRI is **biased toward declaring improvement** — even a random,
meaningless variable tends to produce a positive NRI — and it depends entirely on arbitrary
risk-category cut-points. For this reason it is explicitly a *secondary*, pre-specified endpoint
(D-007), never the headline.

**Reading.** Kerr KF et al., "Net reclassification indices for evaluating risk-prediction
instruments: a critical review", *Epidemiology* 2014.

---

### Decision-curve analysis (net benefit)
**What it is.** Instead of asking "is the model accurate?", it asks "**if we actually used it to make
treatment decisions, would patients be better off?**" It plots net benefit across the range of
threshold probabilities a clinician might act on, and compares against "treat everyone" and "treat
no one".

**Why it matters here.** It is the only one of the three that answers the question a clinician has.
A new predictor that improves the C-index by 0.003 and changes nobody's treatment is not a clinical
advance.

**Reading.** Vickers AJ & Elkin EB, *Medical Decision Making* 2006.

---

## 5. Survival analysis

### Cox proportional hazards model
**What it is.** The workhorse model for time-to-event data. It models the *hazard* — the
instantaneous rate of having an event, given you have not had one yet — as a baseline hazard
multiplied by `exp(linear predictor)`. Crucially, it never has to specify the baseline hazard's
shape, which is why it is so widely used.

**Why it matters here.** It is the model in which the incremental-value test is run (D-006).

**Common mistakes.** Forgetting the **proportional hazards assumption** — that a covariate's effect
is constant over time. Genetic effects on ASCVD are often *stronger at younger ages*, which would
violate it. Check with Schoenfeld residuals; if violated, use time-varying effects or report a
time-restricted C-index. Tracked as Q-S5.

---

### Left truncation / delayed entry
**What it is.** People enter the study at different ages, and only after already surviving
event-free to that age. Someone entering at 65 has already "won" 65 years of not having a heart
attack. If age is the time scale, the model must account for the fact that they were not under
observation before then.

**Why it matters here.** All of Us participants enroll as adults at widely varying ages. Ignoring
this biases estimates.

---

## 6. Genetics

### MAF (minor allele frequency); common / low-frequency / rare
**What it is.** How often the less-common version of a variant appears in a population. Conventional
bands: **common** ≥ 5%, **low-frequency** 1–5%, **rare** < 1% (and "ultra-rare" < 0.1%).

**Why it matters here.** The project title says "low-frequency variants", but the exact MAF threshold
is a real scientific choice that changes power, the multiple-testing burden, and the biology being
captured. It is **not yet decided** (Q-G2) and must be frozen before outcomes are examined.

**Common mistakes.** Using a MAF computed in the wrong reference population. All of Us is ancestrally
diverse; a variant that is rare in Europeans may be common in another group, and using a
European-derived MAF will misclassify it.

---

### Burden test / SKAT / SKAT-O
**What it is.** Individually, a variant carried by 3 people out of 245,000 has no statistical power —
there is nothing to test. So we **aggregate**: collapse all the rare variants in a gene into one
score per person, and test *the gene*.

- **Burden test** — sums variants in a gene. Powerful **if they all push the same direction**;
  it cancels itself out if some raise risk and others lower it.
- **SKAT** — a variance-component test that tolerates mixed directions. Loses power when they *are*
  all one direction.
- **SKAT-O** — adaptively combines the two, so you do not have to guess in advance. Usually the
  default.

**How it's used.** SKAT-O for gene discovery; a directional burden score as the scalar `G` term in
the offset model, since that model needs one number per person (D-008).

**Common mistakes.** Skipping the **positive control**. If your `LDLR` burden score does not
associate with LDL cholesterol, your genetic pipeline is broken — and nothing downstream can be
believed. This check is mandatory in T-008 (A-009).

**Reading.** Lee S, Abecasis GR, Boehnke M, Lin X, "Rare-variant association analysis: study designs
and statistical tests", *AJHG* 2014.

---

### Functional mask / annotation
**What it is.** A rule for deciding which variants in a gene count. Common masks: **pLoF** (predicted
loss of function — nonsense, frameshift, splice); **pLoF + damaging missense**; **all coding**.

**Why it matters here.** The mask *is* the hypothesis. A pLoF mask asks "does breaking this gene
matter?" A permissive mask dilutes true signal with neutral variants. Choosing the mask after seeing
results is a form of p-hacking, so it must be pre-specified (Q-G1).

---

### SAIGE / SAIGE-GENE+ / REGENIE
**What it is.** Software for biobank-scale association testing. They solve two problems that break
naive regression at this scale: **relatedness** (biobanks contain relatives, violating the
independence assumption) and **case-control imbalance** (a few thousand cases among hundreds of
thousands of controls makes standard tests give wrong p-values).

**Why it matters here.** All of Us contains related individuals and our outcome will be rare. This is
tracked in A-011.

---

### PRS (polygenic risk score)
**What it is.** A weighted sum of thousands to millions of **common** variants, each with a tiny
effect.

**Why it matters here.** It is the *contrast* to this project. PRS captures common-variant polygenic
risk; we are asking about **rare, large-effect** variants. A useful secondary analysis is whether the
two are complementary — but a PRS is not the exposure of this study.

**Common mistakes.** PRS performance degrades badly when applied across ancestries, because the
weights are usually derived from European-ancestry studies. In an ancestrally diverse cohort like
All of Us, that is a serious and well-documented equity problem.

---

### Population stratification
**What it is.** Ancestry correlates with both allele frequencies and disease rates, for social and
historical reasons that are not causal. Left uncorrected, this manufactures associations that are not
real.

**Why it matters here.** All of Us is deliberately ancestrally diverse — which is one of its greatest
scientific strengths *and* makes this risk larger than in a homogeneous biobank.

**How it's handled.** Principal components as covariates, and/or a mixed model (SAIGE) that accounts
for genetic relatedness. Checked with genomic inflation (λ_GC) and QQ plots. See A-011.
