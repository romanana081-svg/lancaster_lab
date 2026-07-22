# cohort_overview.R — graphical overview of the PREVENT cohort for the advisor meeting (Thursday).
#
# Produces the demographic figures the advisor asked for: age histogram, age-by-sex, sex breakdown,
# race/ethnicity breakdown, plus the 10-yr ASCVD risk distribution and per-input missingness (the
# attrition story). Runs BOTH in the Workbench (real CDR) and offline against the fixture.
#
# WORKBENCH:
#   source("src/phenotype/R/run_sql.R"); source("src/figures/cohort_overview.R")
#   con    <- connect_cdr()
#   make_cohort_figures(con, outdir = "figures")     # writes PNGs to ./figures/
#
# OFFLINE (fixture, for layout/QA — the numbers are synthetic):
#   Rscript src/figures/cohort_overview.R            # uses fixture/db/aou_fixture.duckdb
#
# NOTE the cohort here is the SCORABLE PREVENT panel (complete_panel == TRUE, sex known). Missing
# smoking is NOT required (that shrink is shown separately). Every figure is captioned with its N so a
# slide never shows a bar without a denominator.

suppressPackageStartupMessages({ library(ggplot2); library(dplyr) })

`%||%` <- function(a, b) if (is.null(a)) b else a

# --- a small, legible, print-safe theme + palette (works in a slide deck) -------------------------
.theme_cohort <- function() {
  theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title    = element_text(face = "bold", size = 15),
          plot.subtitle = element_text(color = "grey35"),
          plot.caption  = element_text(color = "grey45", size = 10),
          axis.title    = element_text(color = "grey25"))
}
.SEX_FILL  <- c(female = "#4C72B0", male = "#DD8452")
.ONE_FILL  <- "#4C72B0"

#' Pull age / sex / race for the scorable cohort and score it, all from one connection.
#'
#' @param con open DBI connection (BigQuery in Workbench, DuckDB fixture offline).
#' @return data.frame with person_id, age, sex, race, and (if AHAprevent present) 10-yr ASCVD risk,
#'   restricted to the scorable panel; plus an attribute "missingness" (per-input NA counts, all rows).
build_cohort_frame <- function(con) {
  stopifnot(exists("extract_prevent_panel", mode = "function"))
  panel <- extract_prevent_panel(con)

  # per-input missingness across EVERYONE in the panel (the attrition story), before restricting.
  miss <- sapply(c("sbp", "total_c", "hdl_c", "egfr", "bmi", "a1c"),
                 function(k) sum(is.na(panel[[k]])))
  miss <- data.frame(input = names(miss), n_missing = as.integer(miss), n_total = nrow(panel))

  race <- DBI::dbGetQuery(con, "SELECT person_id, race FROM cb_search_person")
  scorable <- panel[panel$complete_panel, , drop = FALSE]
  scorable <- dplyr::left_join(scorable, race, by = "person_id")
  scorable$race <- ifelse(is.na(scorable$race) | scorable$race %in%
                            c("None Indicated", "PMI: Skip", "I prefer not to answer"),
                          "Unknown / not reported", scorable$race)

  if (requireNamespace("AHAprevent", quietly = TRUE) &&
      exists("run_prevent", mode = "function")) {
    scorable <- run_prevent(scorable)
  }
  attr(scorable, "missingness") <- miss
  scorable
}

#' Write the cohort-overview figures as PNGs.
#'
#' @param con    open DBI connection.
#' @param outdir directory for the PNGs (created if needed).
#' @param dpi    resolution (150 is crisp on a slide without huge files).
#' @return (invisibly) the cohort data.frame.
make_cohort_figures <- function(con, outdir = "figures", dpi = 150) {
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
  df   <- build_cohort_frame(con)
  n    <- nrow(df)
  save <- function(name, p, w = 7, h = 4.5)
    ggsave(file.path(outdir, name), p, width = w, height = h, dpi = dpi, bg = "white")

  cap <- function() sprintf("Scorable PREVENT panel (complete inputs, known sex). N = %s", format(n, big.mark = ","))

  # 1. Age distribution -----------------------------------------------------------------------------
  save("01_age_hist.png",
    ggplot(df, aes(age)) +
      geom_histogram(binwidth = 2, fill = .ONE_FILL, color = "white") +
      scale_x_continuous(breaks = seq(30, 80, 10)) +
      labs(title = "Age at CDR", subtitle = "PREVENT is validated for ages 30–79",
           x = "Age (years)", y = "Participants", caption = cap()) +
      .theme_cohort())

  # 2. Age by sex -----------------------------------------------------------------------------------
  save("02_age_by_sex.png",
    ggplot(df, aes(age, fill = sex)) +
      geom_histogram(binwidth = 2, position = "identity", alpha = 0.6, color = "white") +
      scale_fill_manual(values = .SEX_FILL, name = "Sex at birth") +
      scale_x_continuous(breaks = seq(30, 80, 10)) +
      labs(title = "Age distribution by sex", x = "Age (years)", y = "Participants",
           caption = cap()) +
      .theme_cohort())

  # 3. Sex breakdown --------------------------------------------------------------------------------
  sx <- df %>% count(sex) %>% mutate(pct = n / sum(n))
  save("03_sex_breakdown.png",
    ggplot(sx, aes(reorder(sex, -n), n, fill = sex)) +
      geom_col(width = 0.6) +
      geom_text(aes(label = sprintf("%s\n(%.0f%%)", format(n, big.mark = ","), 100 * pct)),
                vjust = -0.2, size = 4) +
      scale_fill_manual(values = .SEX_FILL, guide = "none") +
      scale_y_continuous(expand = expansion(mult = c(0, 0.18))) +
      labs(title = "Sex at birth", subtitle = "PREVENT + CKD-EPI are sex-specific; other/unknown excluded",
           x = NULL, y = "Participants", caption = cap()) +
      .theme_cohort(), w = 6, h = 4.5)

  # 4. Race / ethnicity -----------------------------------------------------------------------------
  rc <- df %>% count(race) %>% mutate(pct = n / sum(n)) %>% arrange(n)
  rc$race <- factor(rc$race, levels = rc$race)
  save("04_race_breakdown.png",
    ggplot(rc, aes(n, race)) +
      geom_col(fill = .ONE_FILL, width = 0.7) +
      geom_text(aes(label = sprintf(" %s (%.0f%%)", format(n, big.mark = ","), 100 * pct)),
                hjust = 0, size = 3.6) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
      labs(title = "Race / ethnicity", subtitle = "All of Us is deliberately diverse — a first-class design fact",
           x = "Participants", y = NULL, caption = cap()) +
      .theme_cohort(), w = 7.5, h = 4.5)

  # 5. 10-yr ASCVD risk (only if scored) ------------------------------------------------------------
  if ("prevent_base_10yr_ASCVD" %in% names(df)) {
    rr <- df[!is.na(df$prevent_base_10yr_ASCVD), ]
    save("05_risk10_hist.png",
      ggplot(rr, aes(prevent_base_10yr_ASCVD)) +
        geom_histogram(bins = 40, fill = "#55A868", color = "white") +
        labs(title = "10-year ASCVD risk (PREVENT base model)",
             subtitle = sprintf("Median %.1f%%", median(rr$prevent_base_10yr_ASCVD)),
             x = "10-year ASCVD risk (%)", y = "Participants",
             caption = sprintf("Scored participants. N = %s. bp_tx placeholder = slight underestimate.",
                               format(nrow(rr), big.mark = ","))) +
        .theme_cohort())
  }

  # 6. Per-input missingness (the attrition driver) -------------------------------------------------
  miss <- attr(df, "missingness")
  miss <- miss %>% mutate(pct = n_missing / n_total) %>% arrange(n_missing)
  miss$input <- factor(miss$input, levels = miss$input)
  save("06_missingness.png",
    ggplot(miss, aes(n_missing, input)) +
      geom_col(fill = "#C44E52", width = 0.7) +
      geom_text(aes(label = sprintf(" %s (%.0f%%)", format(n_missing, big.mark = ","), 100 * pct)),
                hjust = 0, size = 3.6) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
      labs(title = "Missing PREVENT inputs (why the panel shrinks)",
           subtitle = "Completeness is set by the scarcest input — lipids in the real CDR",
           x = "Participants missing this input", y = NULL,
           caption = sprintf("Among all panel members (>=1 measurement). N = %s",
                             format(miss$n_total[1], big.mark = ","))) +
      .theme_cohort(), w = 7.5, h = 4.5)

  message(sprintf("wrote 6 figures to %s/ (cohort N = %s)", outdir, format(n, big.mark = ",")))
  invisible(df)
}

# --- offline entry point: run against the fixture when invoked as a script ------------------------
if (sys.nframe() == 0) {
  root <- tryCatch(dirname(dirname(dirname(normalizePath(sys.frame(1)$ofile)))), error = function(e) ".")
  for (p in c("src/phenotype/R/egfr.R", "src/phenotype/R/extract_prevent.R",
              "src/ascvd/prevent/run_prevent.R"))
    if (file.exists(p)) source(p)
  fx <- "fixture/db/aou_fixture.duckdb"
  if (!file.exists(fx)) stop("fixture not built: python fixture/build/generate.py")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  make_cohort_figures(con, outdir = "reports/figures_fixture_demo")
}
