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
#' Locate the AHA `prevent_base()` implementation, installed or merely sourced.
#'
#' HAVING THE CODE IS NOT HAVING THE PACKAGE. `requireNamespace()` sees only what is on `.libPaths()`,
#' so a clone of the AHA repo sitting in the home directory is invisible to it -- and the old error
#' said "not installed ... install it from the AHA repo" to someone who already had the repo, which
#' reads as nonsense and sends them to re-download what they have.
#'
#' Both routes are legitimate: an installed package is the reproducible one and is what the Workbench
#' should end up with, but `source()`-ing the file (or `devtools::load_all()`) is a perfectly good way
#' to get unblocked, and there is no reason for this adapter to refuse it. Which one was used is
#' REPORTED rather than assumed, because "the equation came from somewhere unspecified" is not a thing
#' to leave implicit in a validation.
#'
#' @param allow_installed FALSE forces the sourced path (used by the tests, which cannot uninstall a
#'   package to exercise the fallback).
#' @return list(fn, src) -- the function, and a human-readable note about where it came from.
.prevent_base_fn <- function(allow_installed = TRUE) {
  if (isTRUE(allow_installed) && requireNamespace("AHAprevent", quietly = TRUE))
    return(list(fn = AHAprevent::prevent_base,
                src = sprintf("AHAprevent %s (installed package)",
                              as.character(utils::packageVersion("AHAprevent")))))
  if (exists("prevent_base", mode = "function"))
    return(list(fn = get("prevent_base", mode = "function"),
                src = "prevent_base() found in the session (SOURCED, not installed)"))
  stop("run_prevent(): cannot find the AHA `prevent_base()` implementation.

  If you already have the AHA code as a FOLDER, it is not installed yet -- requireNamespace() only
  sees packages on .libPaths(). Pick one:

  1. Install it (preferred -- survives a session restart):
       p <- \"~/PREVENT\"                                   # your folder
       list.files(p, recursive = TRUE, pattern = \"^DESCRIPTION$\", full.names = TRUE)
       install.packages(<the folder holding DESCRIPTION>, repos = NULL, type = \"source\")
     If that fails on permissions, install to your own library:
       lib <- Sys.getenv(\"R_LIBS_USER\"); dir.create(lib, recursive = TRUE, showWarnings = FALSE)
       install.packages(<folder>, repos = NULL, type = \"source\", lib = lib)

  2. No DESCRIPTION in the folder? Then it is source files, not a package. Source the file that
     defines prevent_base() and call run_prevent() again -- it will pick it up:
       source(\"<folder>/prevent_base.R\")

  3. remotes::install_github(...) only if the folder is not what you want; note the repo path in
     this file's header 404s as of 2026-08-06, so prefer your local copy.", call. = FALSE)
}

run_prevent <- function(panel, allow_installed = TRUE) {
  impl <- .prevent_base_fn(allow_installed)
  message("run_prevent(): using ", impl$src)
  sex_num <- ifelse(tolower(panel$sex) == "female", 1L,
             ifelse(tolower(panel$sex) == "male",   0L, NA_integer_))
  risk <- impl$fn(
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
  out <- cbind(panel, risk)
  # Which implementation produced these numbers, carried on the data rather than left in a console
  # message that scrolls away. export_validation_summary() and the paper tables can then say it.
  attr(out, "prevent_impl") <- impl$src
  out
}
