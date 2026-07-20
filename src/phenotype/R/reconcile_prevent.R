# reconcile_prevent.R — the PREVENT panel feasibility / reconciliation check. T-004 / T-017.
#
# RUN THIS FIRST in the Workbench. It answers, against WHATEVER CDR you are connected to:
#   1. do the PREVENT codes resolve?            (vocabulary)
#   2. do ICD codes sit on the source column?   (structure / the linkage trap)
#   3. how many people have a complete panel?   (coverage = the sample size, D-013)
#
# A code that does not resolve and a code with no data BOTH read as "0% coverage" -- only
# step 1 tells them apart, which is why it runs before step 3. Full write-up and a log to
# fill in against these results: docs/workbench_reconciliation.md
#
# HOW TO RUN (RStudio, in the All of Us R environment):
#   setwd("~/lancaster_lab")                       # or wherever you cloned the repo
#   source("src/phenotype/R/reconcile_prevent.R")  # defines + runs it, prints all three checks
# Offline it runs against the DuckDB fixture instead (connect_cdr() picks the backend by
# WORKSPACE_CDR), so you can dry-run it locally before spending a Workbench query.

if (!file.exists("src/phenotype/R/run_sql.R")) {
  stop("Run this from the repo root. In RStudio: setwd('~/lancaster_lab') ",
       "(or wherever you cloned it), then source() this file again.")
}
source("src/phenotype/R/run_sql.R")   # connect_cdr(), run_sql_file()


#' Run the three-layer PREVENT reconciliation and print it.
#'
#' @param con  an open connection; if NULL, one is opened (BigQuery in the Workbench,
#'             the DuckDB fixture offline) and closed for you.
#' @return invisibly, a list of the three result frames (resolution, linkage, completeness).
reconcile_prevent <- function(con = NULL) {
  close_after <- is.null(con)
  if (close_after) {
    con <- connect_cdr()
    on.exit(DBI::dbDisconnect(con), add = TRUE)
  }

  # --- 1. Vocabulary: do the PREVENT codes resolve? -------------------------
  d01 <- run_sql_file("sql/01_prevent_concept_discovery.sql", con)
  d01$resolves <- ifelse(is.na(d01$concept_id), "FAIL", "ok")
  cat("\n=== 1. Do the PREVENT codes resolve in this CDR? ===\n")
  print(d01[, c("prevent_input", "code", "concept_id", "concept_name", "resolves")],
        row.names = FALSE)
  n_ok <- sum(d01$resolves == "ok"); n_tot <- nrow(d01)
  cat(sprintf("  --> %d of %d codes resolve.%s\n", n_ok, n_tot,
              if (n_ok < n_tot) "  FIX THE FAILs before trusting any count below." else ""))

  # --- 2. Structure: which column do ICD codes live on? ---------------------
  # ICD10CM must be on condition_source_concept_id; the standard column is SNOMED.
  # Query the wrong one for an ICD code and you get zero rows and no error.
  cat("\n=== 2. Linkage check: ICD10CM must sit on condition_source_concept_id ===\n")
  link_sql <- paste(
    "SELECT 'condition_concept_id (standard)' AS column_used, c.vocabulary_id AS vocab, COUNT(*) AS n",
    "FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_concept_id",
    "GROUP BY c.vocabulary_id",
    "UNION ALL",
    "SELECT 'condition_source_concept_id (source)', c.vocabulary_id, COUNT(*)",
    "FROM condition_occurrence co JOIN concept c ON c.concept_id = co.condition_source_concept_id",
    "GROUP BY c.vocabulary_id ORDER BY column_used, n DESC")
  link <- DBI::dbGetQuery(con, link_sql)
  print(link, row.names = FALSE)

  # --- 3. Coverage: the complete-panel feasibility count --------------------
  # D-013 excludes anyone missing any input, so this count IS the sample size (A-016).
  cat("\n=== 3. PREVENT panel completeness (complete panel = the sample size) ===\n")
  d02 <- run_sql_file("sql/02_prevent_panel_completeness.sql", con)
  print(t(d02))

  cat("\nDone. Record these against docs/workbench_reconciliation.md.\n")
  cat("H-006: the resolution table (step 1) is safe to export; the COUNTS (step 3) need\n",
      "       small-cell suppression before they leave the Workbench.\n", sep = "")

  invisible(list(resolution = d01, linkage = link, completeness = d02))
}

# Sourcing this file runs the check immediately (the RStudio "Source" button, or
# source(...) at the console). Assign the result if you want to inspect the frames:
#   res <- reconcile_prevent()
reconcile_prevent()
