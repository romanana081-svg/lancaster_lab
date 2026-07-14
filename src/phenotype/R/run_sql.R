# run_sql.R — run a .sql file against either backend. T-017.
#
# The same SQL runs against the DuckDB fixture offline and BigQuery in the Workbench. That is the
# whole bet of D-003: if the query only ever runs in the cloud, then every bug in it costs a
# round-trip to controlled-tier data to find.
#
# Only the first statement of a file is executed (the rest are commented-out follow-ups, run them
# individually). Statements are split on ';' at end of line.

suppressPackageStartupMessages(library(DBI))

#' Connect to the fixture (offline) or BigQuery (Workbench).
#'
#' Chooses by environment: if WORKSPACE_CDR is set we are in the Workbench, otherwise we are offline.
#' Nothing hard-codes a path — the Workbench injects its own (loop.md, rule 2).
connect_cdr <- function(fixture_path = "fixture/db/aou_fixture.duckdb") {
  cdr <- Sys.getenv("WORKSPACE_CDR")
  if (nzchar(cdr)) {
    if (!requireNamespace("bigrquery", quietly = TRUE)) {
      stop("WORKSPACE_CDR is set (we appear to be in the Workbench) but bigrquery is not installed.")
    }
    message("connect_cdr(): BigQuery — ", cdr)
    return(DBI::dbConnect(bigrquery::bigquery(),
                          project = Sys.getenv("GOOGLE_PROJECT"),
                          dataset = cdr))
  }
  if (!file.exists(fixture_path)) {
    stop("connect_cdr(): no fixture at ", fixture_path,
         "\n  Build it:  python fixture/build/generate.py")
  }
  message("connect_cdr(): DuckDB fixture — ", fixture_path)
  DBI::dbConnect(duckdb::duckdb(), dbdir = fixture_path, read_only = TRUE)
}

#' Strip comments and take the first executable statement from a .sql file.
first_statement <- function(sql_text) {
  lines <- strsplit(sql_text, "\n", fixed = TRUE)[[1]]
  lines <- lines[!grepl("^\\s*--", lines)]          # drop full-line comments
  sql <- paste(lines, collapse = "\n")
  parts <- strsplit(sql, ";", fixed = TRUE)[[1]]
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  if (length(parts) == 0) stop("first_statement(): no executable SQL found")
  parts[1]
}

#' Run a .sql file and return the result.
#'
#' @param path  path to the .sql file
#' @param con   an open connection; if NULL, one is opened and closed for you
run_sql_file <- function(path, con = NULL) {
  if (!file.exists(path)) stop("run_sql_file(): no such file: ", path)
  close_after <- is.null(con)
  if (close_after) {
    con <- connect_cdr()
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  }
  sql <- first_statement(paste(readLines(path, warn = FALSE), collapse = "\n"))
  DBI::dbGetQuery(con, sql)
}
