# 01_check.R — "does this look right?" ONE call, in the Workbench, output safe to paste back.
#
# RUN IT:
#   setwd("~/lancaster_lab")
#   source("src/workbench/01_check.R")
#   run_check()
#
# It writes reports/check_<date>.txt and prints the same thing. **Paste the whole file back.**
#
# ------------------------------------------------------------------------------------------------
# WHY THIS EXISTS AND WHY IT COMES FIRST
#
# The person reading the output cannot see the data. That is not a limitation to work around, it is
# the entire design constraint: this file has to carry enough signal to tell a working pipeline from
# a broken one, while containing nothing that could identify a participant.
#
# It is also the cheap half. 02_deliverables.R fits models, draws figures, and builds the tables —
# and every one of those can produce a beautiful, plausible, WRONG artifact if an upstream code list
# silently resolved to nothing. Running this first costs a few queries and catches exactly that class
# of failure, which is the class that does not announce itself.
#
# WHAT MAKES THE OUTPUT SAFE TO PASTE (by construction, not by remembering):
#   * aggregates only — counts, medians, rates, year-level distributions;
#   * small-cell suppression at 20 (H-006): any count in 1..19 prints as "<20";
#   * no person_ids, no exact dates, no row-level values, no free text from participant records.
#   Vocabulary concept names ARE printed. Those are published dictionary metadata, not participant
#   data, and they are the thing that makes a wrong code list visible.
#
# WHAT IT DOES *NOT* DO: no figures, no models, no tables, nothing written to the bucket. If this
# looks right, run 02_deliverables.R. If it does not, fix it here — everything downstream inherits
# whatever is wrong at this stage.
# ------------------------------------------------------------------------------------------------

.chk_root_ok <- function() file.exists("src/phenotype/R/run_sql.R")

#' One call: connect, check the whole pipeline, write a pasteable report.
#'
#' @param con  an open DBI connection, or NULL to open (and close) one.
#' @param outfile  where to write. NULL = reports/check_<date>.txt
#' @param require_smoking  score the cohort with smoking REQUIRED (default TRUE). Participants with
#'   no survey answer are DROPPED rather than scored as non-smokers. This is the consistent reading
#'   of D-013 (missing PREVENT inputs are excluded, not imputed) and it is expensive — smoking survey
#'   coverage was 39.8% on the 2026-07-21 run. Set FALSE only to measure what the rule costs.
#' @return the path written, invisibly.
run_check <- function(con = NULL, outfile = NULL, require_smoking = TRUE) {
  if (!.chk_root_ok())
    stop("run_check(): working directory is not the repo root (no src/phenotype/R/run_sql.R here).
  In the Workbench:  setwd(\"~/lancaster_lab\")
  Current wd: ", getwd(), call. = FALSE)

  # workbench_report() calls the extractors but does not source them — it is written to be called
  # from a session that already has them. Reuse `.SURV_SOURCES` (defined in survival_curves.R) rather
  # than keeping a second copy of the list here: two lists of source files drift, and the symptom is
  # `could not find function` for whichever one was forgotten. Sourcing that file only defines
  # functions; the `survival` package gate lives in source_survival_deps(), which this does not need.
  source("src/figures/survival_curves.R")
  for (p in .SURV_SOURCES) source(p)
  source("src/phenotype/R/check_ascvd_events.R")
  source("src/phenotype/R/workbench_report.R")

  if (is.null(con)) {
    con <- connect_cdr()
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  }
  if (is.null(outfile)) {
    if (!dir.exists("reports")) dir.create("reports", recursive = TRUE)
    outfile <- file.path("reports", sprintf("check_%s.txt", Sys.Date()))
  }

  path <- workbench_report(con, outfile = outfile, require_smoking = require_smoking)

  # The report is long. Without this, "does it look right?" means reading 200 lines and guessing
  # which ones matter — so the five questions that actually decide it are named here, in the order
  # a failure propagates, with the failure SIGNATURE rather than a vague "check this looks sensible".
  msg <- c(
    "",
    strrep("=", 78),
    "WHAT TO LOOK AT — the five things that decide whether this is right",
    strrep("=", 78),
    "",
    "1. DO THE CODE LISTS RESOLVE?  (report section 1, and the concept-dictionary section)",
    "   Look for: 'names UNRESOLVED' near zero, and a plausible ingredient/code count.",
    "   Failure signature: a resolved count of 0 or a handful. An unresolved code list does NOT",
    "   error — it silently makes the variable FALSE for everyone, and every number downstream is",
    "   then confidently wrong. This is the single most valuable line in the file.",
    "",
    "2. HOW MANY PEOPLE HAVE A COMPLETE PREVENT PANEL?  (panel completeness section)",
    "   Look for: the per-input counts AND the full intersection. The intersection IS the sample",
    "   size (A-016) — D-013 excludes anyone missing any input rather than imputing it.",
    "   Failure signature: one input far below the others. That input is the binding constraint,",
    "   and it is usually smoking (survey-derived) or creatinine, not lipids.",
    "",
    "3. ARE THERE EVENTS, AND ARE THEY THE RIGHT KIND?  (event ascertainment section)",
    "   Look for: a non-zero count in each ASCVD class (acute / chronic / revascularisation), and",
    "   a year distribution that does not start abruptly.",
    "   Failure signature: everything before ~Oct 2015 missing is EXPECTED (ICD10CM only). A single",
    "   code contributing most of the events is not — that is over-capture, usually a CPT.",
    "",
    "4. DOES THE INCIDENCE RATE LAND NEAR THE LITERATURE?  (incidence section)",
    "   Look for: our acute-ASCVD rate against the published 4.15-4.30 per 1000 person-years.",
    "   Roughly 4-12 is plausible here and the reasoning is in docs/prevent_literature_benchmarks.md.",
    "   Failure signature: far BELOW the band = under-ascertainment (we are missing events); far",
    "   ABOVE = prevalent disease leaking in as incident, or revascularisation over-capture.",
    "   This is the number that gates the calibration claim (DESIGN 6.3), so it is not optional.",
    "",
    "5. DOES ANYTHING SAY 'OFFLINE SCAFFOLDING' OR 'PROVISIONAL'?",
    "   Those markers mean a value is a placeholder, not a measurement. They are printed on purpose.",
    "   Failure signature: seeing 'fixture_ids' as a resolution source on a real CDR run — that is",
    "   offline scaffolding and the numbers around it are not valid.",
    "",
    strrep("-", 78),
    sprintf("written to: %s", path),
    "PASTE THE WHOLE FILE BACK. It is aggregate-only and suppressed at 20 by construction.",
    "If all five look right, run:  source(\"src/workbench/02_deliverables.R\"); run_deliverables()",
    strrep("=", 78))
  cat(paste(msg, collapse = "\n"), "\n")
  # Append to the file too, so the pasted text carries its own reading instructions.
  cat(paste(msg, collapse = "\n"), "\n", file = path, append = TRUE)

  invisible(path)
}
