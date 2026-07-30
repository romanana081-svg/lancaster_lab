# incidence_overview.R — ASCVD incidence figures for the lab meeting. T-015.
#
# Companion to cohort_overview.R (which does demographics). This one does EVENTS: how many, of what
# type, when, in whom, and how much the outcome definition changes the answer.
#
# WORKBENCH:
#   source("src/phenotype/R/run_sql.R")
#   source("src/phenotype/R/extract_prevent.R")
#   source("src/phenotype/R/extract_ascvd_events.R")
#   source("src/ascvd/prevent/run_prevent.R")
#   source("src/figures/incidence_overview.R")
#   con <- connect_cdr()
#   make_incidence_figures(con, outdir = "figures", landmark = as.Date("2018-01-01"),
#                          end_of_followup = as.Date("2022-07-01"))   # <- SET THE CDR CUTOFF
#
# OFFLINE (fixture, for layout QA only — the numbers are synthetic):
#   Rscript src/figures/incidence_overview.R
#
# ------------------------------------------------------------------------------------------------
# WHICH FIGURES DEPEND ON THE UNRESOLVED BASELINE ANCHOR (Q-S6), AND WHICH DO NOT
#
# This distinction is the whole reason this file is split the way it is. Do not blur it on a slide.
#
#   ANCHOR-FREE (sound today):
#     1. events by class            — a count of codes; no baseline involved
#     2. first acute event by year  — calendar-time distribution of event dates
#     3. age at first acute event   — event date minus birth year
#     4. attrition to the at-risk set — depends on the landmark DATE only, not on covariate timing
#     5. cumulative incidence after the landmark — a survival curve built from event DATES among
#        people event-free at the landmark. Covariate VALUES never enter, so the Q-S6 placeholder
#        cannot bias it.
#
#   ANCHOR-DEPENDENT (provisional — labelled as such ON the figure):
#     6. observed incidence by PREVENT risk group. This one uses the covariate VALUES, which are
#        currently the most-recent measurement (extract_prevent.R, the Q-S6 placeholder). For a person
#        who had an event, the most-recent value can post-date the event — statin started, BP treated
#        — which biases the gradient in an unknown direction. The figure is still worth showing
#        because it is the shape of the eventual result, but its caption says PROVISIONAL and why.
#        See `first_ascvd_event()` / `ascvd_status_at()` for where the anchor enters as an argument.
# ------------------------------------------------------------------------------------------------

suppressPackageStartupMessages({ library(ggplot2); library(dplyr) })

`%||%` <- function(a, b) if (is.null(a)) b else a

.theme_inc <- function() {
  theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title    = element_text(face = "bold", size = 15),
          plot.subtitle = element_text(color = "grey35"),
          plot.caption  = element_text(color = "grey45", size = 9, hjust = 0),
          axis.title    = element_text(color = "grey25"))
}
.CLASS_FILL <- c(acute_event = "#C44E52", chronic_disease = "#8172B3",
                 revascularisation = "#CCB974")
.ONE <- "#4C72B0"
.PROVISIONAL <- paste("PROVISIONAL — covariate values are the most-recent measurement (Q-S6 baseline",
                      "anchor unresolved),\nso for people with an event they may post-date it.",
                      "Shape is indicative; the gradient is not final.")

#' Assemble everything the incidence figures need, from one connection.
#'
#' @param con  open DBI connection.
#' @param landmark  the baseline date T0, applied to EVERYONE identically. A single calendar landmark
#'   is the anchor that cannot produce immortal-time bias: entry does not require having survived long
#'   enough to accumulate anything. It is passed in rather than defaulted so that no figure is ever
#'   produced without someone choosing it.
#' @param end_of_followup  the CDR cutoff. Everyone event-free is censored here.
#' @param scorable_only  restrict the at-risk set to the complete/scorable PREVENT panel (D-013).
#' @param attach_smoking_status  attach REAL survey smoking via extract_smoking() instead of leaving
#'   the FALSE placeholder. This is a genuine trade and neither answer is free, so it is an explicit
#'   argument rather than a default someone discovers later:
#'     FALSE (default) — everyone keeps smoking = FALSE. The cohort stays at its full size, and
#'                       predicted risk is biased DOWNWARD for every actual smoker.
#'     TRUE            — real smoking status; people with no survey answer become NA and are dropped
#'                       by run_prevent(). Honest, but the scorable panel collapses (216,167 -> 84,176
#'                       on the 2026-07-21 real run, 39.8% coverage). The answer CODING is still
#'                       provisional (prevent_concepts.yaml: ANSWERS_PROVISIONAL).
#'   Whichever is chosen, the figure captions say which, because "predicted risk" means two different
#'   things under the two settings.
#' @return list(events, cohort, at_risk, ages, counts)
build_incidence_frame <- function(con, landmark, end_of_followup, scorable_only = TRUE,
                                 attach_smoking_status = FALSE) {
  stopifnot(exists("extract_ascvd_events", mode = "function"),
            exists("extract_prevent_panel", mode = "function"))
  landmark        <- as.Date(landmark)
  end_of_followup <- as.Date(end_of_followup)
  if (landmark >= end_of_followup)
    stop("build_incidence_frame(): landmark must precede end_of_followup, or nobody has follow-up.",
         call. = FALSE)

  events <- extract_ascvd_events(con)
  panel  <- extract_prevent_panel(con)

  # Real survey smoking, if asked for. Left OFF by default because it shrinks the cohort by ~61% and
  # that shrink must be a decision, not a surprise -- but leaving it off is NOT the safe option, it
  # just moves the error: every actual smoker is then scored as a non-smoker.
  smoking_source <- "placeholder FALSE for everyone (biases predicted risk DOWNWARD)"
  if (isTRUE(attach_smoking_status)) {
    if (!exists("extract_smoking", mode = "function"))
      stop("build_incidence_frame(): attach_smoking_status = TRUE but extract_smoking.R is not
  sourced. source('src/phenotype/R/extract_smoking.R') first.", call. = FALSE)
    smk   <- extract_smoking(con)
    panel <- attach_smoking(panel, smk)
    smoking_source <- sprintf("real survey smoking (answer coding PROVISIONAL); %s of %s scorable have an answer",
                              format(sum(panel$complete_panel_smoking, na.rm = TRUE), big.mark = ","),
                              format(sum(panel$complete_panel, na.rm = TRUE), big.mark = ","))
  }

  # Score PREVENT if the equation and package are available (figure 6 needs it; the rest do not).
  if (requireNamespace("AHAprevent", quietly = TRUE) && exists("run_prevent", mode = "function")) {
    panel <- tryCatch(run_prevent(panel), error = function(e) { warning(conditionMessage(e)); panel })
  }

  # When smoking is attached it becomes a REQUIRED input (decision 2026-07-30): anyone with no survey
  # answer is dropped from the at-risk set entirely, not merely left NA to fall out of the scored
  # figure. Those are different cohorts -- the second would leave non-answerers in the denominator of
  # every incidence rate while excluding them from the risk-group figure, so the two would silently
  # disagree about who was studied.
  keep <- if (!scorable_only) rep(TRUE, nrow(panel))
          else if (isTRUE(attach_smoking_status) && "complete_panel_smoking" %in% names(panel))
            panel$complete_panel_smoking
          else panel$complete_panel
  cohort <- panel[keep, , drop = FALSE]
  cohort$baseline_date <- landmark

  at_risk <- ascvd_status_at(cohort, events, anchor_col = "baseline_date",
                            event_classes = "acute_event", end_of_followup = end_of_followup)

  # Age at first acute event, from year_of_birth (OMOP `person`). Approximate to the year, which is
  # all a histogram needs and all that is safe to show.
  yob <- DBI::dbGetQuery(con, "SELECT person_id, year_of_birth FROM person")
  yob$person_id <- as.numeric(yob$person_id)
  acute <- first_ascvd_event(events, "acute_event")
  acute$year_of_birth <- yob$year_of_birth[match(acute$person_id, yob$person_id)]
  acute$age_at_event  <- as.integer(format(acute$event_date, "%Y")) - acute$year_of_birth

  # The attrition ladder to the at-risk set. Every step is a number someone will ask about.
  counts <- data.frame(
    step = c("PREVENT panel (>=1 input, EHR, 30-79)",
             if (isTRUE(attach_smoking_status))
               "Scorable panel (complete inputs + smoking answer)"
             else "Scorable panel (complete inputs, sex known)",
             "Free of ASCVD at landmark (at-risk set)",
             "Incident acute ASCVD during follow-up"),
    n = c(nrow(panel), nrow(cohort),
          sum(at_risk$ascvd_status %in% c("event_free", "incident")),
          sum(at_risk$ascvd_status == "incident")),
    stringsAsFactors = FALSE)

  list(events = events, cohort = cohort, at_risk = at_risk, acute = acute, counts = counts,
       landmark = landmark, end_of_followup = end_of_followup, smoking_source = smoking_source)
}

#' Observed cumulative incidence after the landmark (Kaplan-Meier complement).
#'
#' Anchor-free in the sense that matters: it uses event DATES and the landmark only. Covariate values
#' never enter, so the Q-S6 placeholder cannot bias it.
.cuminc <- function(at_risk, group = NULL) {
  d <- at_risk[!is.na(at_risk$event) & !is.na(at_risk$followup_days) & at_risk$followup_days >= 0, ]
  if (!nrow(d)) return(NULL)
  f <- if (is.null(group)) survival::Surv(d$followup_days, d$event) ~ 1 else
       stats::as.formula(sprintf("survival::Surv(followup_days, event) ~ %s", group))
  fit <- survival::survfit(f, data = d)
  s <- summary(fit)
  strata <- if (is.null(s$strata)) rep("all", length(s$time)) else
            sub("^[^=]*=", "", as.character(s$strata))
  data.frame(years = s$time / 365.25, cuminc = 100 * (1 - s$surv), strata = strata,
             n_risk = s$n.risk, stringsAsFactors = FALSE)
}

#' Write the incidence figures as PNGs.
#'
#' @return invisibly, the frame list from build_incidence_frame().
make_incidence_figures <- function(con, outdir = "figures", landmark, end_of_followup,
                                  scorable_only = TRUE, attach_smoking_status = FALSE, dpi = 150) {
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
  fr <- build_incidence_frame(con, landmark, end_of_followup, scorable_only, attach_smoking_status)
  save <- function(name, p, w = 7, h = 4.5)
    ggsave(file.path(outdir, name), p, width = w, height = h, dpi = dpi, bg = "white")
  fmt <- function(x) format(x, big.mark = ",", trim = TRUE)

  ev      <- fr$events
  at_risk <- fr$at_risk

  # --- 1. events by class -------------------------------------------------------------------------
  # Three classes, three different scientific meanings. Showing them together is the point: it is the
  # figure that stops "CAD" from being one undifferentiated blob.
  bc <- ev %>% count(ascvd_class) %>% arrange(n)
  bc$ascvd_class <- factor(bc$ascvd_class, levels = bc$ascvd_class)
  save("10_events_by_class.png",
    ggplot(bc, aes(n, ascvd_class, fill = as.character(ascvd_class))) +
      geom_col(width = 0.65) +
      geom_text(aes(label = paste0(" ", fmt(n))), hjust = 0, size = 4) +
      scale_fill_manual(values = .CLASS_FILL, guide = "none") +
      scale_x_continuous(expand = expansion(mult = c(0, 0.22))) +
      labs(title = "People with an ASCVD code, by class",
           subtitle = "Acute = the outcome PREVENT predicts · chronic = prevalent disease · revasc = a treatment decision",
           x = "People with >=1 code in this class", y = NULL,
           caption = "Classes are not mutually exclusive: a person can appear in more than one.\nA first CHRONIC code is a diagnosis date, not an event date (configs/ascvd_codes.yaml).") +
      .theme_inc(), w = 8, h = 4.5)

  # --- 2. first acute event by calendar year ------------------------------------------------------
  acute <- fr$acute
  if (nrow(acute)) {
    yr <- acute %>% mutate(year = as.integer(format(.data$event_date, "%Y"))) %>% count(year)
    save("11_acute_by_year.png",
      ggplot(yr, aes(year, n)) +
        geom_col(fill = .CLASS_FILL[["acute_event"]], width = 0.7) +
        labs(title = "First acute ASCVD event, by calendar year",
             subtitle = "Ascertainment over calendar time — a sharp rise or cliff is usually a data artefact, not epidemiology",
             x = "Year of first acute event", y = "People",
             caption = "ICD10CM only: records before ~Oct-2015 are coded ICD9CM and are currently NOT matched,\nwhich left-truncates the early years. Sized by audit_ascvd_codes() Layer 3.") +
        .theme_inc())

    # --- 3. age at first acute event --------------------------------------------------------------
    aa <- acute[!is.na(acute$age_at_event) & acute$age_at_event > 0 & acute$age_at_event < 110, ]
    if (nrow(aa))
      save("12_age_at_first_acute.png",
        ggplot(aa, aes(age_at_event)) +
          geom_histogram(binwidth = 5, fill = .CLASS_FILL[["acute_event"]], color = "white") +
          labs(title = "Age at first acute ASCVD event",
               subtitle = sprintf("Median %.0f years", median(aa$age_at_event)),
               x = "Age at first acute event (years)", y = "People",
               caption = sprintf("N = %s with a computable age. From year_of_birth, so accurate to the year.",
                                 fmt(nrow(aa)))) +
          .theme_inc())
  }

  # --- 4. attrition to the at-risk set -----------------------------------------------------------
  # The lab-meeting figure: it accounts for every person between "has data" and "contributes an event".
  ct <- fr$counts
  ct$step <- factor(ct$step, levels = rev(ct$step))
  ct$pct  <- 100 * ct$n / ct$n[1]
  save("13_attrition_to_at_risk.png",
    ggplot(ct, aes(n, step)) +
      geom_col(fill = .ONE, width = 0.68) +
      geom_text(aes(label = sprintf(" %s (%.1f%% of panel)", fmt(n), pct)), hjust = 0, size = 3.7) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.32))) +
      labs(title = "From data to events: the incidence analysis set",
           subtitle = sprintf("Landmark baseline %s · follow-up to %s",
                              format(fr$landmark), format(fr$end_of_followup)),
           x = "People", y = NULL,
           caption = paste("Prevalent ASCVD at the landmark (any acute, chronic, or revascularisation code",
                           "on/before it) is EXCLUDED, per D-013.\nA landmark baseline is used because entry",
                           "does not require surviving long enough to accumulate a panel — no immortal time.")) +
      .theme_inc(), w = 8.5, h = 4.2)

  # --- 5. observed cumulative incidence after the landmark ---------------------------------------
  ci <- .cuminc(at_risk)
  if (!is.null(ci) && nrow(ci)) {
    n_at_risk <- sum(at_risk$ascvd_status %in% c("event_free", "incident"))
    n_ev      <- sum(at_risk$ascvd_status == "incident")
    save("14_cumulative_incidence.png",
      ggplot(ci, aes(years, cuminc)) +
        geom_step(color = .CLASS_FILL[["acute_event"]], linewidth = 1.1) +
        scale_y_continuous(labels = function(x) paste0(x, "%")) +
        labs(title = "Observed cumulative incidence of acute ASCVD",
             subtitle = sprintf("From the %s landmark, among those free of ASCVD at that date",
                                format(fr$landmark)),
             x = "Years since landmark", y = "Cumulative incidence",
             caption = sprintf(paste("Kaplan-Meier complement. At risk N = %s, events = %s.",
                                     "Censored at %s.\nThis figure is ANCHOR-FREE: it uses event dates",
                                     "and the landmark only — covariate values never enter,\nso the",
                                     "unresolved Q-S6 anchor cannot bias it. Competing risk of death",
                                     "not yet modelled (no death table wired)."),
                               fmt(n_at_risk), fmt(n_ev), format(fr$end_of_followup))) +
        .theme_inc(), w = 7.5, h = 4.8)

    # by sex — the stratification the advisor asks for every time, and PREVENT is sex-specific
    if ("sex" %in% names(at_risk)) {
      cis <- .cuminc(at_risk, group = "sex")
      if (!is.null(cis) && nrow(cis))
        save("15_cumulative_incidence_by_sex.png",
          ggplot(cis, aes(years, cuminc, color = strata)) +
            geom_step(linewidth = 1.1) +
            scale_color_manual(values = c(female = "#4C72B0", male = "#DD8452"),
                               name = "Sex at birth") +
            scale_y_continuous(labels = function(x) paste0(x, "%")) +
            labs(title = "Observed cumulative incidence, by sex",
                 subtitle = "PREVENT is sex-specific, so this is the stratification that matters first",
                 x = "Years since landmark", y = "Cumulative incidence",
                 caption = "Anchor-free (event dates + landmark only).") +
            .theme_inc(), w = 7.5, h = 4.8)
    }
  }

  # --- 6. observed incidence by PREVENT risk group — PROVISIONAL ---------------------------------
  risk_col <- intersect(c("prevent_base_10yr_ASCVD", "risk10", "prevent_10yr"), names(at_risk))
  if (length(risk_col)) {
    rc <- risk_col[1]
    d  <- at_risk[!is.na(at_risk[[rc]]) & !is.na(at_risk$event), ]
    if (nrow(d) >= 20) {
      # Quintiles rather than deciles: with a modest event count, deciles are noise dressed as detail.
      brk <- unique(stats::quantile(d[[rc]], probs = seq(0, 1, 0.2), na.rm = TRUE))
      if (length(brk) >= 3) {
        d$risk_group <- cut(d[[rc]], breaks = brk, include.lowest = TRUE, labels = FALSE)
        gg <- d %>% group_by(.data$risk_group) %>%
          summarise(n = dplyr::n(), events = sum(.data$event),
                    person_years = sum(.data$followup_days) / 365.25,
                    predicted = mean(.data[[rc]]), .groups = "drop") %>%
          mutate(observed_pct = 100 * .data$events / .data$n,
                 rate_per_1000py = 1000 * .data$events / .data$person_years)
        save("16_observed_by_prevent_risk_PROVISIONAL.png",
          ggplot(gg, aes(factor(risk_group), observed_pct)) +
            geom_col(fill = "#55A868", width = 0.65) +
            geom_point(aes(y = predicted), color = "grey20", size = 2.6) +
            geom_line(aes(y = predicted, group = 1), color = "grey20", linetype = "22") +
            geom_text(aes(label = sprintf("%.1f%%", observed_pct)), vjust = -0.5, size = 3.5) +
            scale_y_continuous(expand = expansion(mult = c(0, 0.18)),
                               labels = function(x) paste0(x, "%")) +
            labs(title = "Observed events vs PREVENT predicted risk, by risk quintile",
                 subtitle = "Bars = observed % with an event · dots = mean PREVENT 10-yr predicted",
                 x = "PREVENT 10-year risk quintile (1 = lowest)", y = "Observed / predicted",
                 caption = paste0(.PROVISIONAL,
                   "\nAlso NOT comparable on the vertical axis yet: observed is over actual follow-up",
                   " (< 10 years), predicted is a 10-year risk.",
                   "\nSmoking: ", fr$smoking_source,
                   "\nbp_tx: placeholder FALSE for everyone (antihypertensive list NEEDS_A_CODE_LIST)",
                   " — also biases predicted risk DOWNWARD.")) +
            .theme_inc(), w = 8, h = 5)
      }
    } else {
      message("skipping figure 16: fewer than 20 scored people with follow-up.")
    }
  } else {
    message("skipping figure 16: no PREVENT risk column (is run_prevent.R sourced and AHAprevent installed?).")
  }

  message(sprintf("incidence figures written to %s/ | at-risk N = %s, incident events = %s",
                  outdir, fmt(fr$counts$n[3]), fmt(fr$counts$n[4])))
  invisible(fr)
}

# --- offline entry point: fixture, for layout QA only ---------------------------------------------
if (sys.nframe() == 0) {
  for (p in c("src/phenotype/R/egfr.R", "src/phenotype/R/extract_prevent.R",
              "src/phenotype/R/extract_ascvd_events.R", "src/ascvd/prevent/run_prevent.R"))
    if (file.exists(p)) source(p)
  fx <- "fixture/db/aou_fixture.duckdb"
  if (!file.exists(fx)) stop("fixture not built: see docs/environment.md")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = fx, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  # The fixture's condition dates run 2009-2021, so a 2015 landmark leaves usable follow-up.
  make_incidence_figures(con, outdir = "reports/figures_fixture_demo",
                         landmark = as.Date("2015-01-01"),
                         end_of_followup = as.Date("2022-01-01"))
}
