# workbench_report.R — ONE command that checks the whole pipeline and writes a pasteable report.
#
# THE POINT: you run this in the All of Us Workbench; it writes a plain-text file you copy out and
# paste back to whoever is working on the code. That person cannot see the data, so every number here
# is built to be PARTICIPANT-SAFE BY CONSTRUCTION rather than by remembering to be careful:
#
#   * AGGREGATES ONLY — counts, medians, rates, year-level distributions.
#   * SMALL-CELL SUPPRESSION — any count in 1..19 prints as "<20" (H-006). Zero prints as 0, because
#     "this code matched nothing" is a fact about our code list, not about a participant.
#   * NO person_ids, NO exact dates, NO row-level values, NO free text from participant records.
#     Vocabulary concept names ARE printed — those are published dictionary metadata.
#
# RUN IT:
#   source("src/phenotype/R/workbench_report.R")
#   con  <- connect_cdr()
#   path <- workbench_report(con)      # prints, and writes reports/workbench_report_<date>.txt
#
# Then open that file and paste its contents back.

#' Run every check and write a pasteable report.
#'
#' @param con      open DBI connection.
#' @param outfile  where to write. NULL = reports/workbench_report_<Sys.Date()>.txt
#' @param require_smoking  score the cohort with smoking REQUIRED (default TRUE, set 2026-07-30):
#'   participants with no survey smoking answer are DROPPED rather than scored as non-smokers.
#' @param run_events  include the ASCVD event ascertainment check (needs extract_ascvd_events.R).
#' @return the path written, invisibly.
workbench_report <- function(con, outfile = NULL, require_smoking = TRUE, run_events = TRUE) {
  if (is.null(outfile)) {
    if (!dir.exists("reports")) dir.create("reports", recursive = TRUE)
    outfile <- file.path("reports", sprintf("workbench_report_%s.txt", Sys.Date()))
  }
  con_out <- file(outfile, open = "wt")
  # Tee everything to BOTH the console and the file, so you see it run AND get a file to paste.
  sink(con_out, split = TRUE)
  on.exit({ sink(); close(con_out) }, add = TRUE)

  sup <- function(n) {
    n <- suppressWarnings(as.numeric(n))
    ifelse(is.na(n), "NA", ifelse(n == 0, "0",
      ifelse(n < 20, "<20", format(n, big.mark = ",", trim = TRUE))))
  }
  rule <- function(t) cat("\n", strrep("=", 78), "\n", t, "\n", strrep("=", 78), "\n", sep = "")

  cat("ALL OF US — PREVENT / ASCVD PIPELINE REPORT\n")
  cat("generated : ", format(Sys.time(), "%Y-%m-%d %H:%M"), "\n", sep = "")
  cat("CDR       : ", Sys.getenv("WORKSPACE_CDR", "<unset — running offline?>"), "\n", sep = "")
  cat("R         : ", R.version.string, "\n", sep = "")
  cat("smoking   : ", if (require_smoking) "REQUIRED (no answer => EXCLUDED)" else
                      "NOT required (placeholder FALSE for everyone)", "\n", sep = "")
  cat("\nAll counts small-cell suppressed at <20. No person_ids, no exact dates.\n")
  cat("SAFE TO PASTE THIS WHOLE FILE.\n")

  # ============================================================== 1. bp_tx resolution
  rule("1 — bp_tx: do the AHA antihypertensive names resolve in THIS CDR?")
  cat("bp_tx stopped being a placeholder on 2026-07-30. It is now driven by the AHA's published\n")
  cat("classes of blood-pressure medication, listed BY INGREDIENT NAME in prevent_concepts.yaml and\n")
  cat("resolved against this CDR's vocabulary. If names do not resolve, bp_tx is silently FALSE for\n")
  cat("everyone -- which is exactly the failure this section exists to catch.\n\n")
  bp <- tryCatch(resolve_antihypertensive_ingredients(con, strict = FALSE),
                 error = function(e) { cat("*** ERROR: ", conditionMessage(e), "\n", sep = ""); NULL })
  if (!is.null(bp)) {
    cat("resolution source : ", bp$source,
        if (bp$source == "fixture_ids") "  *** OFFLINE SCAFFOLDING — NOT VALID ON REAL DATA ***" else "",
        "\n", sep = "")
    cat("ingredients resolved : ", length(bp$ingredient_ids), "\n", sep = "")
    cat("names UNRESOLVED     : ", length(bp$unresolved), "\n", sep = "")
    if (length(bp$unresolved))
      cat("  -> ", paste(head(bp$unresolved, 30), collapse = ", "),
          if (length(bp$unresolved) > 30) " ..." else "", "\n",
          "  These are spelled differently in this CDR (or absent). Fix them in the config.\n", sep = "")
    if (bp$source == "names" && length(bp$ingredient_ids) < 20)
      cat("\n*** WARNING: fewer than 20 ingredients resolved. The AHA list has ~60 names; a number\n",
          "    this low means resolution is mostly failing and bp_tx will be badly under-counted.\n", sep = "")
  }

  # ============================================================== 2. the panel
  rule("2 — the PREVENT panel")
  panel <- extract_prevent_panel(con)
  n_panel <- nrow(panel)
  cat("people with >=1 PREVENT measurement (EHR, age 30-79, sex known): ", sup(n_panel), "\n", sep = "")
  cat("complete panel (5 measurements + demographics)                 : ",
      sup(sum(panel$complete_panel)), "\n", sep = "")
  cat("\nper-input missingness (of the panel):\n")
  miss <- sapply(c("sbp", "total_c", "hdl_c", "egfr", "bmi", "a1c"), function(k) sum(is.na(panel[[k]])))
  print(data.frame(input = names(miss), n_missing = sup(miss),
                   pct = sprintf("%.1f%%", 100 * miss / n_panel)), row.names = FALSE)
  cat("\nbinary inputs (prevalence in the panel):\n")
  print(data.frame(
    input = c("bp_tx (AHA antihypertensive)", "statin", "dm (A1c>=6.8 AND med)"),
    n     = sup(c(sum(panel$bp_tx), sum(panel$statin), sum(panel$dm))),
    pct   = sprintf("%.1f%%", 100 * c(mean(panel$bp_tx), mean(panel$statin), mean(panel$dm)))),
    row.names = FALSE)
  cat("\nSANITY: in a US EHR cohort aged 30-79, bp_tx in the mid-tens of percent is plausible.\n")
  cat("Single digits => resolution failed. >60% => the list is capturing far more than BP treatment.\n")
  cat("NB bp_tx measures 'on a BP-lowering drug', NOT 'treated for hypertension': beta blockers,\n")
  cat("loop diuretics and CCBs are also given for arrhythmia, heart failure and angina.\n")

  # ============================================================== 3. smoking
  rule("3 — smoking coverage (and what requiring it costs)")
  smk_ok <- exists("extract_smoking", mode = "function")
  if (!smk_ok) {
    cat("extract_smoking.R not sourced — skipping. source() it and re-run.\n")
  } else {
    smk    <- extract_smoking(con)
    panel2 <- attach_smoking(panel, smk)
    cat("participants with a usable smoking answer : ", sup(sum(panel2$has_smoking_answer)),
        sprintf("  (%.1f%% of panel)", 100 * mean(panel2$has_smoking_answer)), "\n", sep = "")
    cat("current smokers among those answering     : ",
        sup(sum(panel2$smoking, na.rm = TRUE)),
        sprintf("  (%.1f%% of answerers)",
                100 * mean(panel2$smoking[panel2$has_smoking_answer], na.rm = TRUE)), "\n", sep = "")
    cat("\nTHE COST OF REQUIRING SMOKING (the decision made 2026-07-30):\n")
    cat("  complete panel, smoking NOT required : ", sup(sum(panel2$complete_panel)), "\n", sep = "")
    cat("  complete panel, smoking REQUIRED     : ", sup(sum(panel2$complete_panel_smoking)), "\n", sep = "")
    lost <- sum(panel2$complete_panel) - sum(panel2$complete_panel_smoking)
    cat("  => dropped for having no answer      : ", sup(lost),
        sprintf("  (%.1f%% of the complete panel)", 100 * lost / max(1, sum(panel2$complete_panel))),
        "\n", sep = "")
    cat("\nThis is the single largest exclusion in the pipeline. Whoever presents these figures\n")
    cat("should say which N they are on.\n")
    if (require_smoking) panel <- panel2
  }

  # ============================================================== 4. scored risk
  rule("4 — PREVENT risk on the analysis cohort")
  if (!exists("run_prevent", mode = "function") || !requireNamespace("AHAprevent", quietly = TRUE)) {
    cat("run_prevent.R not sourced or AHAprevent not installed — skipping.\n")
  } else {
    keep <- if (require_smoking && "complete_panel_smoking" %in% names(panel))
              panel$complete_panel_smoking else panel$complete_panel
    scored <- run_prevent(panel[keep, , drop = FALSE])
    rc <- intersect(c("prevent_base_10yr_ASCVD", "risk10"), names(scored))
    cat("scored participants: ", sup(nrow(scored)), "\n", sep = "")
    if (length(rc)) {
      v <- scored[[rc[1]]]; v <- v[!is.na(v)]
      cat("scored with a non-NA 10-yr risk: ", sup(length(v)), "\n\n", sep = "")
      if (length(v) >= 20) {
        q <- stats::quantile(v, c(.1, .25, .5, .75, .9))
        print(data.frame(statistic = c("p10","p25","median","p75","p90"),
                         risk_pct  = sprintf("%.2f%%", q)), row.names = FALSE)
        cat("\nSANITY: a median 10-yr ASCVD risk somewhere around 3-8% is typical for this age range.\n")
        cat("A median near 0 or above 25% means an input is wrong (units, eGFR, or a binary flag).\n")
      }
    }
  }

  # ============================================================== 5. events
  if (run_events && exists("check_ascvd_events", mode = "function")) {
    rule("5 — ASCVD event ascertainment")
    cat("(full layered check follows — see check_ascvd_events.R for what each layer distinguishes)\n")
    tryCatch(check_ascvd_events(con),
             error = function(e) cat("*** ERROR in check_ascvd_events(): ", conditionMessage(e), "\n", sep = ""))
  } else if (run_events) {
    rule("5 — ASCVD event ascertainment")
    cat("check_ascvd_events.R not sourced — skipping. source() it and re-run.\n")
  }

  rule("END — paste this whole file back")
  cat("written to: ", outfile, "\n", sep = "")
  invisible(outfile)
}
