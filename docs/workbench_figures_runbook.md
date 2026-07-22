# Runbook — generate the cohort figures in the All of Us Workbench

Step-by-step to produce the demographic figures for the slide deck from **real** CDR data. The script
(`src/figures/cohort_overview.R`) is already validated offline against the fixture; this runs it at
scale. **Do this in an R environment inside the Workbench** (RStudio or an R notebook), repo cloned.

Everything here reads data; nothing writes to the CDR. Cost is a handful of BigQuery queries (the same
ones the extractor already runs), so it is cheap — but confirm the billing project first (H-004).

---

## 0. One-time per session — be at the repo root and confirm the env reached R

```r
setwd("~/lancaster_lab")                 # adjust to where you cloned it
Sys.getenv("WORKSPACE_CDR")              # must be non-empty, e.g. "wb-...-2408.C2025Q4R6"
Sys.getenv("GOOGLE_PROJECT")             # must be non-empty (your billing project)
# If WORKSPACE_CDR is empty in R but set in the Terminal:
#   Sys.setenv(WORKSPACE_CDR = "...", GOOGLE_PROJECT = "...")
```

If `ggplot2` is not already installed in the Workbench image:

```r
install.packages("ggplot2")              # dplyr + DBI + bigrquery are already present in the Workbench
```

## 1. Load the pipeline + the figure code

```r
source("src/phenotype/R/run_sql.R")         # connect_cdr()
source("src/phenotype/R/extract_prevent.R") # extract_prevent_panel(); auto-sources egfr.R
source("src/phenotype/R/extract_smoking.R") # extract_smoking(), attach_smoking()
source("src/ascvd/prevent/run_prevent.R")   # run_prevent()  (needs the AHA PREVENT package)
source("src/figures/cohort_overview.R")     # make_cohort_figures()
```

If the official AHA package is not installed yet (only needed for the **risk** figure):

```r
# remotes::install_github("AHA-DS-Analytics/PREVENT")
```

## 2. Open the connection and generate the six figures

```r
con <- connect_cdr()                          # BigQuery, picked from WORKSPACE_CDR
df  <- make_cohort_figures(con, outdir = "figures")
# -> writes 6 PNGs to ./figures/ and returns the scorable cohort data.frame (invisibly, as df)
```

You will get, in `./figures/`:

| File | What it shows |
|---|---|
| `01_age_hist.png` | age distribution (30–79) |
| `02_age_by_sex.png` | age distribution split by sex |
| `03_sex_breakdown.png` | male vs female counts + % |
| `04_race_breakdown.png` | race / ethnicity counts + % |
| `05_risk10_hist.png` | 10-year ASCVD risk distribution (base model) |
| `06_missingness.png` | participants missing each PREVENT input (the attrition driver) |

Every figure is captioned with its **N**, so a slide never shows a bar without a denominator. The
cohort here is the **scorable panel** (complete inputs, known sex) — the 216,167-type number.

## 3. Sanity-check the numbers BEFORE trusting the figures

```r
nrow(df)                                   # scorable N — should be ~216K
summary(df$age); median(df$age)            # age in [30,79]; median ~58
table(df$sex)                              # both levels, no NA (missing-sex already excluded)
sort(table(df$race), decreasing = TRUE)    # race distribution
if ("prevent_base_10yr_ASCVD" %in% names(df))
  summary(df$prevent_base_10yr_ASCVD)      # risk distribution, plausible single digits to ~30%
attr(df, "missingness")                    # per-input NA counts across the whole panel
```

If `nrow(df)` is wildly off from ~216K, stop and check the extractor before believing the plots.

### Optional — a more accurate risk figure with real smoking

`make_cohort_figures()` scores with the smoking **placeholder** (FALSE for everyone), so `05_risk10`
is a slight underestimate. To score with real survey smoking instead:

```r
panel  <- extract_prevent_panel(con)
smk    <- extract_smoking(con, question_concept_ids = 1585860L)   # confirmed "Smoke Frequency"
scored <- run_prevent(attach_smoking(panel, smk))
summary(scored$prevent_base_10yr_ASCVD[scored$complete_panel])
```

(The demographic figures 01–04 and 06 do not depend on smoking, so `make_cohort_figures()` is fine for
those as-is.)

## 4. Get the PNGs out so we can review them here

Copy them to the workspace bucket, then download from the bucket browser (or the Jupyter file tree):

```r
system(paste0("gsutil -m cp ./figures/*.png ", Sys.getenv("WORKSPACE_BUCKET"), "/figures/"))
```

Then download the six PNGs to your laptop and **upload them into this chat**. I'll review each one
(labels, geometry, whether the story reads) before any of them goes on a slide — that's the check you
asked for. Nothing goes into the deck until you've seen it and okayed it.

---

**Note on aggregate outputs:** every count here is far above the small-cell suppression threshold, so
the figures are safe to bring out of the Workbench. If any future breakdown produces a cell < 20,
suppress it before export (H-006 pattern).
