# run_prevent.R — run the AHA PREVENT base equation on the extracted panel. T-016.
#
# Uses the OFFICIAL AHA implementation, AHAprevent::prevent_base (Krishnan, Petito, Huang, Khan;
# AHA-DS-Analytics/PREVENT, GPL-3), published with the equations at
# doi:10.1161/CIRCULATIONAHA.123.067626. It is NOT on CRAN -- install from the AHA repo:
#   remotes::install_github("AHA-DS-Analytics/PREVENT")   (or install.packages(<local clone>, repos=NULL))
#
# This adapter maps THIS project's panel coding onto the AHA function's coding:
#   sex  "female" -> 1, "male" -> 0
#   dm / smoking / bp_tx / statin  logical -> 1L / 0L
#   tc, hdl in mg/dL; sbp mmHg; bmi kg/m^2; egfr from CKD-EPI 2021 (egfr.R) -- which is exactly the
#   eGFR the AHA equation documents (Inker 2021). So the extractor's output feeds straight in.
#
# Output is in PERCENT (e.g. 6.13 means 6.13%), one row per person, columns:
#   prevent_base_10yr_{CVD,ASCVD,HF} and prevent_base_30yr_{CVD,ASCVD,HF}
# `ascvd` is the study's outcome. Rows with any missing/out-of-range input come back NA (the AHA
# function handles this), so incomplete panels do not silently get a bogus score.

#' Run AHA PREVENT (base model) on an extracted panel and append the risk columns.
#'
#' @param panel output of extract_prevent_panel(): needs columns age, sex, sbp, bp_tx, total_c,
#'   hdl_c, statin, dm, smoking, egfr, bmi (person_id and others are carried through).
#' @return `panel` with the six prevent_base_* risk columns cbind-ed on.
run_prevent <- function(panel) {
  if (!requireNamespace("AHAprevent", quietly = TRUE)) {
    stop("run_prevent(): the AHAprevent package is not installed. It is the official AHA PREVENT\n",
         "  implementation and is NOT on CRAN. Install it from the AHA repo, e.g.\n",
         "    remotes::install_github('AHA-DS-Analytics/PREVENT')")
  }
  sex_num <- ifelse(tolower(panel$sex) == "female", 1L,
             ifelse(tolower(panel$sex) == "male",   0L, NA_integer_))
  risk <- AHAprevent::prevent_base(
    sex     = sex_num,
    age     = panel$age,
    tc      = panel$total_c,
    hdl     = panel$hdl_c,
    sbp     = panel$sbp,
    dm      = as.integer(panel$dm),
    smoking = as.integer(panel$smoking),
    bmi     = panel$bmi,
    egfr    = panel$egfr,
    bptreat = as.integer(panel$bp_tx),
    statin  = as.integer(panel$statin))

  # prevent_base returns LIST-columns (as.data.frame(t(...)) inside it), with NA elements stored as
  # logical. Flatten each to a plain numeric vector so the risk columns behave like numbers.
  risk <- as.data.frame(
    lapply(risk, function(col) vapply(col, function(x) as.numeric(x)[1], numeric(1))),
    stringsAsFactors = FALSE)
  cbind(panel, risk)
}
