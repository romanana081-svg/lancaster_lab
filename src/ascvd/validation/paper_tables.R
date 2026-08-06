# paper_tables.R — Khan et al.'s Table 1 and Table 4, rebuilt on our cohort, with the paper's own
# numbers in the adjacent columns. T-024.
#
# WORKBENCH (after a survival run):
#   source("src/figures/survival_curves.R")
#   source("src/figures/prevent_calibration.R")
#   source("src/ascvd/validation/paper_tables.R")
#   res <- run_survival_curves()
#   cal <- make_prevent_calibration_figures(res)
#   pt  <- render_paper_tables(res, cal)   # prints both, writes reports/paper_tables_<date>.txt
#
# ------------------------------------------------------------------------------------------------
# WHY THESE TWO TABLES AND NOT ALL FOUR
#
# Tables 2 and 3 are HAZARD RATIOS — the equation's own coefficients, meta-analyzed across 25
# derivation cohorts on the age scale with competing-risk adjustment. Reproducing them means
# RE-DERIVING PREVENT, which is not this study: we run the published equation as published
# (run_prevent.R calls the official AHA implementation). Table 1 (who was studied) and Table 4 (how
# well it performed) are the two a validation can honestly restate.
#
# WHAT EACH ONE IS FOR
#
#   Table 1 exists to explain Table 4 before anyone over-reads it. Our C-statistic will land below
#   the paper's, and most of the reason is in Table 1 rather than in PREVENT: shorter follow-up, a
#   different age spread, a different diabetes prevalence. Showing the performance number without the
#   cohort it came from invites "PREVENT does worse in All of Us", which this analysis cannot support.
#
#   Table 4 is the validation claim itself: discrimination and calibration slope, by sex.
#
# THREE WAYS THE COMPARISON IS NOT LIKE-FOR-LIKE. All three are printed with the tables, because a
# reader who does not know them will read the gap as a finding:
#
#   1. THEIR INTERVAL IS AN IQI ACROSS 21 COHORTS — the spread BETWEEN populations. Ours is a
#      sampling CI within one cohort. Different quantities; the columns are labelled separately and
#      never merged into one "95%" column.
#   2. HORIZON. Their slope regresses 10-year observed on 10-year predicted. Ours uses our horizon
#      for both, after the constant-hazard rescale in prevent_calibration.R.
#   3. COMPETING RISK. Their observed risk is cause-specific, modelling non-CVD death as a competing
#      event. Ours is 1 - Kaplan-Meier with death treated as censoring, because no death table is
#      wired yet. That biases OUR observed risk upward, and therefore our slope upward. It is the
#      single biggest methodological gap in this comparison and it is not a rounding issue.
# ------------------------------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

# The disclosure threshold, resolved AT CALL TIME rather than baked into a default argument.
#
# These functions used to default to `min_cell = .MIN_CELL`, a constant owned by
# export_validation_summary.R. An R default argument is a promise evaluated in the caller's function
# frame when it is first forced -- so that spelling reaches across files for a symbol at CALL time,
# and any session where the constant is not visible in the search path fails with
# `object '.MIN_CELL' not found` at the moment of use, long after the source() that should have
# provided it. The tables then break for a reason that has nothing to do with tables.
#
# Resolving it through a function keeps the single source of truth (export_validation_summary.R's
# value wins when it is loaded) while making these functions callable on their own. The 20-person
# floor is policy, so a lower value found elsewhere is raised rather than honoured.
.PT_MIN_CELL_FLOOR <- 20L
.pt_min_cell <- function() {
  v <- tryCatch(if (exists(".MIN_CELL", inherits = TRUE)) get(".MIN_CELL", inherits = TRUE)
                else .PT_MIN_CELL_FLOOR,
                error = function(e) .PT_MIN_CELL_FLOOR)
  v <- suppressWarnings(as.integer(v))
  if (!length(v) || is.na(v)) v <- .PT_MIN_CELL_FLOOR
  max(v, .PT_MIN_CELL_FLOOR)
}

# Cholesterol only. The paper prints mmol/L; All of Us measures mg/dL. Conversion runs in this
# direction on purpose — OURS is converted up into the paper's units, and the transcribed reference
# block is never rewritten, so every cell in the paper column stays quotable against the printed page.
.CHOL_MGDL_PER_MMOL <- 38.67

.PT_CONFIG_DEFAULT <- "configs/config.yaml"

# Two dependencies, neither of which this file should own a copy of: the disclosure helpers live with
# the validation summary (a second copy would be a second thing to keep at 20), and the config reader
# lives with the literature benchmarks.
#
# Source them if they are not already loaded. The Workbench flow reaches this file AFTER
# run_survival_curves(), which sources both — but `source("src/ascvd/validation/paper_tables.R")` on
# its own is the obvious thing to type, and without this it failed with `could not find function
# "read_literature_config"`, which points at the wrong file entirely.
local({
  need <- list(
    c(".sup",                    "src/ascvd/validation/export_validation_summary.R"),
    c("read_literature_config",  "src/ascvd/validation/literature_benchmarks.R"))
  for (n in need) {
    if (exists(n[1], mode = "function")) next
    cand <- c(n[2], file.path("..", n[2]), file.path("..", "..", n[2]))
    hit  <- cand[file.exists(cand)]
    if (!length(hit))
      stop(sprintf("paper_tables.R: could not find %s (searched from %s). Set the working directory
  to the repo root.", n[2], getwd()), call. = FALSE)
    source(hit[1])
  }
})

# ---- reading the transcribed reference ----------------------------------------------------------

#' The paper's Table 1, as a long frame.
#'
#' @return data.frame(key, stat, column, value1, value2, value3) where `column` is one of
#'   derivation_female / derivation_male / validation_female / validation_male, and the value slots
#'   hold [mean, sd], [median, lo, hi], a percentage, or a count depending on `stat`.
paper_table1_reference <- function(path = .PT_CONFIG_DEFAULT) {
  lit <- read_literature_config(path)
  t1  <- lit$prevent_paper$table1
  if (is.null(t1))
    stop("config.yaml has no literature.prevent_paper.table1 block.", call. = FALSE)
  cols <- c("derivation_female", "derivation_male", "validation_female", "validation_male")
  out <- list()
  emit <- function(stat, key, cells) {
    for (i in seq_along(cols)) {
      v <- cells[[i]]
      out[[length(out) + 1]] <<- data.frame(
        key = key, stat = stat, column = cols[i],
        value1 = as.numeric(v[1]),
        value2 = if (length(v) > 1) as.numeric(v[2]) else NA_real_,
        value3 = if (length(v) > 2) as.numeric(v[3]) else NA_real_,
        stringsAsFactors = FALSE)
    }
  }
  for (k in names(t1$count))      emit("count",      k, as.list(unlist(t1$count[[k]])))
  for (k in names(t1$pct))        emit("pct",        k, as.list(unlist(t1$pct[[k]])))
  for (k in names(t1$mean_sd))    emit("mean_sd",    k, t1$mean_sd[[k]])
  for (k in names(t1$median_iqi)) emit("median_iqi", k, t1$median_iqi[[k]])
  do.call(rbind, out)
}

#' The paper's Table 4 rows for one outcome, as a frame.
#'
#' @param outcome "ascvd" (ours), "cvd", or "hf".
#' @return data.frame(sex, c_statistic, c_iqi_lo, c_iqi_hi, slope, slope_iqi_lo, slope_iqi_hi,
#'   n_events, pce_c, pce_slope, delta_c)
paper_table4_reference <- function(outcome = c("ascvd", "cvd", "hf"), path = .PT_CONFIG_DEFAULT) {
  outcome <- match.arg(outcome)
  lit <- read_literature_config(path)
  t4  <- lit$prevent_paper$table4
  if (is.null(t4))
    stop("config.yaml has no literature.prevent_paper.table4 block.", call. = FALSE)
  rows <- lapply(c("female", "male"), function(sx) {
    b <- t4$base_model[[paste0(outcome, "_", sx)]]
    if (is.null(b)) return(NULL)
    p <- t4$pce_comparison[[paste0(outcome, "_", sx)]]
    # Note the key: delta C carries a 95% CI, not the IQI every other interval in this block uses.
    d <- t4$delta_c_prevent_minus_pce_95ci[[paste0(outcome, "_", sx)]]
    data.frame(
      sex = sx,
      c_statistic = b$c_statistic[[1]], c_iqi_lo = b$c_statistic[[2]], c_iqi_hi = b$c_statistic[[3]],
      slope = b$calibration_slope[[1]], slope_iqi_lo = b$calibration_slope[[2]],
      slope_iqi_hi = b$calibration_slope[[3]],
      n_events = b$n_events %||% NA_real_,
      pce_c     = if (is.null(p)) NA_real_ else p$c_statistic[[1]],
      pce_slope = if (is.null(p)) NA_real_ else p$calibration_slope[[1]],
      delta_c   = if (is.null(d)) NA_real_ else as.numeric(d[[1]]),
      n_participants = t4$n_participants[[sx]] %||% NA_real_,
      n_cohorts = t4$n_cohorts %||% NA_real_,
      stringsAsFactors = FALSE)
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}

# ---- the calibration slope ----------------------------------------------------------------------

#' Calibration slope: regress observed risk on predicted risk across groups of predicted risk.
#'
#' The paper defines it as "the slope of the observed versus predicted risk by decile", i.e. an
#' ordinary least-squares fit through the decile points of a calibration plot. Slope 1 with intercept
#' 0 is perfect; the PCEs score ~0.5 on the same scale in the paper's Table 4, which is the ruler that
#' makes our number mean anything.
#'
#' UNWEIGHTED, deliberately. Deciles hold equal numbers by construction, so weighting by n changes
#' almost nothing when the groups are deciles — but it changes a LOT if a caller passes 5 groups on a
#' skewed risk distribution, and a slope that silently depends on the grouping is worse than one that
#' is plainly defined. If you weight, say so on the figure.
#'
#' BOTH AXES MUST BE AT THE SAME HORIZON. `calibration_table()` supplies `predicted_horizon` (the
#' 10-year risk rescaled) alongside `observed_pct` for exactly this reason. Regressing observed
#' 2-year risk on predicted 10-YEAR risk yields a slope near 0.2 that looks like catastrophic
#' over-prediction and is pure units error.
#'
#' @param cal_tbl output of calibration_table() — needs stratum, predicted_horizon, observed_pct, n.
#' @param min_groups refuse to fit below this many points. Three points through a straight line is
#'   not a calibration slope, it is a rumour.
#' @return data.frame(stratum, n_groups, slope, se, lower, upper, intercept, r_squared, n, events)
calibration_slope <- function(cal_tbl, min_groups = 5) {
  if (is.null(cal_tbl) || !nrow(cal_tbl)) return(NULL)
  need <- c("stratum", "predicted_horizon", "observed_pct")
  miss <- setdiff(need, names(cal_tbl))
  if (length(miss))
    stop(sprintf("calibration_slope(): missing column(s): %s. Expected calibration_table() output.",
                 paste(miss, collapse = ", ")), call. = FALSE)

  out <- lapply(split(cal_tbl, cal_tbl$stratum), function(g) {
    g <- g[is.finite(g$predicted_horizon) & is.finite(g$observed_pct), , drop = FALSE]
    if (nrow(g) < min_groups) return(NULL)
    fit <- stats::lm(observed_pct ~ predicted_horizon, data = g)
    co  <- summary(fit)$coefficients
    if (!"predicted_horizon" %in% rownames(co)) return(NULL)
    est <- co["predicted_horizon", "Estimate"]; se <- co["predicted_horizon", "Std. Error"]
    tcrit <- stats::qt(0.975, df = stats::df.residual(fit))
    data.frame(stratum = g$stratum[1], n_groups = nrow(g),
               slope = est, se = se, lower = est - tcrit * se, upper = est + tcrit * se,
               intercept = unname(co["(Intercept)", "Estimate"]),
               r_squared = summary(fit)$r.squared,
               n = sum(g$n), events = sum(g$events),
               stringsAsFactors = FALSE)
  })
  res <- do.call(rbind, Filter(Negate(is.null), out))
  if (is.null(res)) return(NULL)
  rownames(res) <- NULL
  res
}

# ---- Table 1 ------------------------------------------------------------------------------------

#' Format mean (SD) at the paper's own precision, and at the SAME precision on both sides.
#'
#' The paper prints "53 (13)" for age and "5.0 (0.8)" for cholesterol — integers for the large
#' quantities, one decimal for the small ones. Reproducing that is not cosmetic in a side-by-side:
#' printing our age as "58.0 (12.8)" beside their "53 (13)" invites reading a precision difference as
#' a measurement difference, and at width 11 the longer form silently TRUNCATED to "123.0 (16.0",
#' which is a cell that has lost a digit without saying so.
#'
#' The SD takes its digits from the MEAN, so the two halves of a cell never disagree about precision.
.pt_mean_sd_fmt <- function(m, s) {
  if (!is.finite(m)) return("-")
  d <- if (abs(m) < 20) 1L else 0L
  sprintf("%.*f (%.*f)", d, m, d, if (is.finite(s)) s else NA_real_)
}
.pt_mean_sd <- function(x, n_min, min_cell) {
  x <- x[is.finite(x)]
  if (length(x) < min_cell || n_min < min_cell) return("-")
  .pt_mean_sd_fmt(mean(x), stats::sd(x))
}
#' Percentages at the paper's precision — two significant figures, same rule as the mean cells.
#' Reproduces their printed column exactly: 78, 23, 14, but 8.0, 6.0, 2.6, 5.8.
.pt_fmt_num <- function(v) if (!is.finite(v)) "-" else
  if (abs(v) < 20) sprintf("%.1f", v) else sprintf("%.0f", v)

.pt_pct <- function(flag, min_cell) {
  flag <- flag[!is.na(flag)]
  # Suppress on the NUMERATOR too: "0.4%" of 5,000 is 20 people, but "0.1%" is 5, and the percentage
  # hands that count straight back. Denominator-only suppression misses this.
  k <- sum(as.logical(flag))
  if (!length(flag) || length(flag) < min_cell || (k > 0 && k < min_cell)) return("-")
  .pt_fmt_num(100 * k / length(flag))
}

#' Our cohort in the shape of the paper's Table 1.
#'
#' @param res  the list from run_survival_curves(), or a bare at-risk data.frame.
#' @param events_from "acute" (the paper's hard outcome — the comparable one) or "broad" (D-016).
#'   Only affects the event-count rows; the covariate rows come from the same at-risk set either way.
#' @param min_cell disclosure threshold.
#' @return data.frame of formatted character columns, with a `notes` attribute.
make_paper_table1 <- function(res, events_from = c("acute", "broad"), min_cell = .pt_min_cell(),
                              path = .PT_CONFIG_DEFAULT) {
  events_from <- match.arg(events_from)
  fr <- if (is.data.frame(res)) NULL else (res$frame %||% res)
  ar <- if (is.data.frame(res)) res else fr$at_risk
  if (is.null(ar)) stop("make_paper_table1(): could not find the at-risk frame.", call. = FALSE)
  # The paper's Table 1 describes the people who contribute to the analysis, so ours must too:
  # prevalent and short-interval exclusions carry event = NA and are already out of every rate.
  ar <- ar[!is.na(ar$event), , drop = FALSE]
  if (!nrow(ar)) stop("make_paper_table1(): the at-risk set is empty.", call. = FALSE)
  ar_acute <- if (!is.null(fr) && !is.null(fr$at_risk_acute))
                fr$at_risk_acute[!is.na(fr$at_risk_acute$event), , drop = FALSE] else NULL

  ref <- paper_table1_reference(path)
  pv  <- function(key, col, slot = "value1") {
    r <- ref[ref$key == key & ref$column == col, , drop = FALSE]
    if (!nrow(r)) NA_real_ else r[[slot]][1]
  }
  ref_cell <- function(key, col) {
    r <- ref[ref$key == key & ref$column == col, , drop = FALSE]
    if (!nrow(r)) return("-")
    switch(r$stat[1],
           count      = format(r$value1[1], big.mark = ",", trim = TRUE, scientific = FALSE),
           pct        = .pt_fmt_num(r$value1[1]),
           mean_sd    = .pt_mean_sd_fmt(r$value1[1], r$value2[1]),
           median_iqi = sprintf("%.0f (%.0f-%.0f)", r$value1[1], r$value2[1], r$value3[1]),
           "-")
  }

  sexes <- c("female", "male")
  ours  <- lapply(sexes, function(sx) ar[!is.na(ar$sex) & ar$sex == sx, , drop = FALSE])
  names(ours) <- sexes
  n_sex <- vapply(ours, nrow, integer(1))

  # Each row: label, key in the reference block, and a function of one sex's rows -> formatted cell.
  # Keeping the OUR-side computation next to the reference key is what stops a row from quietly
  # comparing our diabetes to their smoking after an edit.
  ms  <- function(f) function(g, sx) .pt_mean_sd(f(g), n_sex[[sx]], min_cell)
  pc  <- function(f) function(g, sx) .pt_pct(f(g), min_cell)
  na_ <- function(why) function(g, sx) "-"

  spec <- list(
    list("N participants",              "n_participants",
         function(g, sx) .sup(nrow(g), min_cell)),
    list("Datasets contributing",       "n_cohorts",
         function(g, sx) "1"),
    list("Age, y",                      "age",           ms(function(g) g$age)),
    # Race is in the CDR but not on the panel: extract_prevent_panel() selects the PREVENT inputs and
    # PREVENT is race-free by design. The paper's rows are carried with our side blank, so the gap is
    # VISIBLE rather than silently dropped — All of Us is far less White than their cohorts, and that
    # belongs in the room even when we cannot fill the cell.
    list("White, %",                    "race_white",    na_("not on the panel")),
    list("Black, %",                    "race_black",    na_("not on the panel")),
    list("Hispanic, %",                 "race_hispanic", na_("not on the panel")),
    list("Asian, %",                    "race_asian",    na_("not on the panel")),
    list("Other/unknown, %",            "race_other",    na_("not on the panel")),
    list("Systolic BP, mm Hg",          "sbp",           ms(function(g) g$sbp)),
    list("Total cholesterol, mmol/L",   "total_c",
         ms(function(g) g$total_c / .CHOL_MGDL_PER_MMOL)),
    list("Non-HDL-C, mmol/L",           "non_hdl_c",
         ms(function(g) (g$total_c - g$hdl_c) / .CHOL_MGDL_PER_MMOL)),
    list("HDL-C, mmol/L",               "hdl_c",
         ms(function(g) g$hdl_c / .CHOL_MGDL_PER_MMOL)),
    list("BMI, kg/m2",                  "bmi",           ms(function(g) g$bmi)),
    list("eGFR, mL/min/1.73m2",         "egfr",          ms(function(g) g$egfr)),
    list("Diabetes, %",                 "diabetes",      pc(function(g) g$dm)),
    list("Current smoking, %",          "smoking",       pc(function(g) g$smoking)),
    list("Antihypertensive tx, %",      "bp_tx",         pc(function(g) g$bp_tx)),
    list("Statin tx, %",                "statin",        pc(function(g) g$statin)),
    list("HbA1c if diabetes, %",        "hba1c_dm",
         ms(function(g) g$a1c[which(g$dm)])),
    list("HbA1c if no diabetes, %",     "hba1c_nondm",
         ms(function(g) g$a1c[which(!g$dm)])),
    list("UACR, mg/g",                  "uacr",          na_("not extracted")),
    list("SDI decile",                  "sdi_decile",    na_("not extracted")),
    list("Follow-up, y",                "followup_years",
         ms(function(g) g$followup_days / 365.25)),
    list("ASCVD events",                "events_ascvd",
         function(g, sx) {
           src <- if (events_from == "acute" && !is.null(ar_acute))
                    ar_acute[!is.na(ar_acute$sex) & ar_acute$sex == sx, , drop = FALSE] else g
           .sup(sum(src$event == 1L, na.rm = TRUE), min_cell)
         }),
    list("Total CVD events",            "events_cvd",    na_("HF not ascertained")),
    list("HF events",                   "events_hf",     na_("HF not ascertained")),
    list("Deaths",                      "deaths",        na_("death table not wired")))

  rows <- lapply(spec, function(s) {
    label <- s[[1]]; key <- s[[2]]; fn <- s[[3]]
    data.frame(
      characteristic     = label,
      ours_female        = fn(ours$female, "female"),
      ours_male          = fn(ours$male,   "male"),
      paper_deriv_female = ref_cell(key, "derivation_female"),
      paper_deriv_male   = ref_cell(key, "derivation_male"),
      paper_valid_female = ref_cell(key, "validation_female"),
      paper_valid_male   = ref_cell(key, "validation_male"),
      stringsAsFactors = FALSE)
  })
  tab <- do.call(rbind, rows)

  # If a future panel carries race, filling those rows is a mapping decision (All of Us collects
  # race and ethnicity separately; the paper's five categories are a different taxonomy), so it stays
  # a deliberate edit rather than something this function guesses at.
  if ("race" %in% names(ar))
    message("make_paper_table1(): `race` is on the at-risk frame but is not mapped to the paper's ",
            "five categories — those rows are left blank rather than guessed.")

  attr(tab, "notes") <- c(
    sprintf("Ours: the AT-RISK set (prevalent and 30-day exclusions removed), N = %s female / %s male.",
            .sup(n_sex[["female"]], min_cell), .sup(n_sex[["male"]], min_cell)),
    sprintf("Event row counts the %s outcome. %s",
            if (events_from == "acute") "ACUTE (hard) outcome, the paper's" else "BROAD D-016",
            if (events_from == "acute") "Comparable to their ASCVD row."
            else "NOT comparable to their ASCVD row — chronic dx and revascularisation count here."),
    "Cholesterol converted mg/dL -> mmol/L at 38.67 for comparability; our source values are mg/dL.",
    "Race: PREVENT is race-free and the panel does not carry race, so their race rows have no counterpart here.",
    "UACR and SDI are not extracted (they are novel-predictor inputs, not base-model inputs).",
    "Total CVD and HF events: we ascertain ASCVD only, so those rows are theirs alone.",
    "Deaths: no death table is wired, which is also why our KM treats death as censoring.",
    sprintf("Counts under %d are suppressed, and statistics derived from a suppressed count are blanked.",
            min_cell))
  attr(tab, "n_by_sex") <- n_sex
  tab
}

# ---- Table 4 ------------------------------------------------------------------------------------

#' Our discrimination and calibration in the shape of the paper's Table 4.
#'
#' @param res the list from run_survival_curves() (used only for labelling).
#' @param cal the list from make_prevent_calibration_figures(). Required — this table IS its numbers.
#' @return data.frame of formatted character columns, with `notes` and `raw` attributes.
make_paper_table4 <- function(res, cal, min_cell = .pt_min_cell(), path = .PT_CONFIG_DEFAULT) {
  if (is.null(cal))
    stop("make_paper_table4(): `cal` is required — run make_prevent_calibration_figures(res) first.
  Without it there is no C-statistic and no calibration table to take a slope from.", call. = FALSE)
  if (is.null(cal$concordance_by_sex) && is.null(cal$calibration_by_sex))
    stop("make_paper_table4(): `cal` has neither concordance_by_sex nor calibration_by_sex. PREVENT
  probably did not score anyone (AHAprevent missing, or an incomplete panel input).", call. = FALSE)

  ref   <- paper_table4_reference("ascvd", path)
  slope <- calibration_slope(cal$calibration_by_sex)
  cc    <- cal$concordance_by_sex

  get1 <- function(d, sx) if (is.null(d)) NULL else {
    r <- d[d$stratum == sx, , drop = FALSE]; if (nrow(r)) r[1, ] else NULL
  }

  # One row per METRIC, with a column pair per sex — the paper's own orientation. The alternative
  # (one row per sex, thirteen columns) does not fit a page and forces the interval columns away from
  # the estimates they belong to, which is how a CI ends up read as an IQI.
  cell <- lapply(c("female", "male"), function(sx) {
    c_row <- get1(cc, sx); s_row <- get1(slope, sx)
    p     <- ref[ref$sex == sx, , drop = FALSE]
    ev    <- if (!is.null(c_row)) c_row$events else if (!is.null(s_row)) s_row$events else NA_real_
    sup   <- .is_sup(ev, min_cell)
    list(
      ours = c(
        n          = if (!is.null(c_row)) .sup(c_row$n, min_cell) else "-",
        events     = .sup(ev, min_cell),
        c          = if (is.null(c_row) || sup) "-" else sprintf("%.3f", c_row$c_index),
        c_int      = if (is.null(c_row) || sup) "-"
                     else sprintf("%.3f-%.3f", c_row$lower, c_row$upper),
        slope      = if (is.null(s_row) || sup) "-" else sprintf("%.2f", s_row$slope),
        slope_int  = if (is.null(s_row) || sup) "-"
                     else sprintf("%.2f-%.2f", s_row$lower, s_row$upper),
        pce_c      = "-",
        pce_slope  = "-",
        cohorts    = "1",
        horizon    = format(cal$horizon_years %||% NA)),
      paper = c(
        n          = if (!nrow(p)) "-" else format(p$n_participants, big.mark = ",", trim = TRUE,
                                                   scientific = FALSE),
        events     = if (!nrow(p)) "-" else format(p$n_events, big.mark = ",", trim = TRUE,
                                                   scientific = FALSE),
        c          = if (!nrow(p)) "-" else sprintf("%.3f", p$c_statistic),
        c_int      = if (!nrow(p)) "-" else sprintf("%.3f-%.3f", p$c_iqi_lo, p$c_iqi_hi),
        slope      = if (!nrow(p)) "-" else sprintf("%.2f", p$slope),
        slope_int  = if (!nrow(p)) "-" else sprintf("%.2f-%.2f", p$slope_iqi_lo, p$slope_iqi_hi),
        pce_c      = if (!nrow(p)) "-" else sprintf("%.3f", p$pce_c),
        pce_slope  = if (!nrow(p)) "-" else sprintf("%.2f", p$pce_slope),
        cohorts    = if (!nrow(p)) "-" else format(p$n_cohorts),
        horizon    = "10"))
  })
  names(cell) <- c("female", "male")

  # The interval rows name WHICH interval they carry on the row itself. A "95%" header spanning both
  # would be false for the paper's column, and this is the confusion most likely to survive into a
  # slide: their spread is between cohorts, ours is sampling error within one.
  metric_rows <- list(
    c("N analysed",                 "n"),
    c("Events",                     "events"),
    c("C-statistic",                "c"),
    c("  ours 95% CI | paper IQI",  "c_int"),
    c("Calibration slope",          "slope"),
    c("  ours 95% CI | paper IQI",  "slope_int"),
    c("PCEs: C-statistic",          "pce_c"),
    c("PCEs: calibration slope",    "pce_slope"),
    c("Cohorts contributing",       "cohorts"),
    c("Horizon, y",                 "horizon"))

  tab <- do.call(rbind, lapply(metric_rows, function(m) data.frame(
    metric       = m[1],
    ours_female  = unname(cell$female$ours[m[2]]),
    paper_female = unname(cell$female$paper[m[2]]),
    ours_male    = unname(cell$male$ours[m[2]]),
    paper_male   = unname(cell$male$paper[m[2]]),
    stringsAsFactors = FALSE)))

  # One note per element, each a single string: .pt_render() wraps them to the table width, and a
  # note pre-broken into manual continuation lines gets re-wrapped into orphans.
  attr(tab, "notes") <- c(
    sprintf("Outcome: %s. Horizon: %s year(s) — theirs is 10.",
            cal$outcome %||% "unknown", format(cal$horizon_years %||% NA)),
    paste("OUR interval is a 95% CI within one cohort. THEIR interval is the IQI across 21 cohorts,",
          "i.e. the spread between populations. Different quantities; do not read one as the other."),
    sprintf(paste("Calibration slope = OLS slope of observed on predicted across groups of predicted",
                  "risk, both at the same horizon (predicted rescaled 10y -> horizon). Fitted on %s",
                  "group(s) per sex."),
            if (is.null(slope)) "0" else paste(unique(slope$n_groups), collapse = "/")),
    paste("The PCE rows are the paper's, on the paper's cohorts. They are the ruler: ~0.5 is what a",
          "badly calibrated slope looks like on this scale, ~1.05 is what a good one looks like."),
    paste("Their observed risk models the competing risk of non-CVD death; ours is 1-KM with death",
          "treated as censoring, which biases our observed risk — and so our slope — UPWARD."),
    paste("A C-statistic below theirs is expected here (shorter follow-up, narrower age range,",
          "noisier EHR outcomes all compress C) and is not by itself evidence that PREVENT performs",
          "worse."))
  attr(tab, "raw") <- list(concordance = cc, slope = slope, reference = ref)
  tab
}

# ---- rendering ----------------------------------------------------------------------------------

# Fixed-width, NOT print(data.frame). A seven-column frame is wider than the console, and R's print
# wraps it by splitting the columns into blocks -- the second block arriving with no `characteristic`
# column, so no row can be identified. In a file whose whole purpose is to be pasted somewhere else,
# that is not a cosmetic problem.
.pt_pad <- function(x, w) formatC(substr(as.character(x), 1, w), width = -w, flag = " ")
.pt_row <- function(vals, w) sub("\\s+$", "", paste(mapply(.pt_pad, vals, w), collapse = " "))

#' A group header spanning several columns, e.g. OURS over (female, male).
.pt_group_header <- function(labels, spans) .pt_row(labels, spans)

.T1_W <- c(25, 11, 11, 11, 11, 11, 11)
.T4_W <- c(30, 15, 15, 15, 15)

.pt_render_table1 <- function(tab) {
  span2 <- sum(.T1_W[2:3]) + 1
  c(.pt_group_header(c("", "OURS (at-risk)", "PAPER derivation", "PAPER validation"),
                     c(.T1_W[1], span2, span2, span2)),
    .pt_row(c("characteristic", "female", "male", "female", "male", "female", "male"), .T1_W),
    .pt_row(rep("", 7), .T1_W),
    vapply(seq_len(nrow(tab)), function(i) .pt_row(unlist(tab[i, ]), .T1_W), character(1)))
}

.pt_render_table4 <- function(tab) {
  span2 <- sum(.T4_W[2:3]) + 1
  c(.pt_group_header(c("", "FEMALE", "MALE"), c(.T4_W[1], span2, span2)),
    .pt_row(c("", "ours", "paper", "ours", "paper"), .T4_W),
    .pt_row(rep("", 5), .T4_W),
    vapply(seq_len(nrow(tab)), function(i) .pt_row(unlist(tab[i, ]), .T4_W), character(1)))
}

.pt_render <- function(body, title, subtitle = NULL, notes = NULL) {
  # Wrap the notes to the table's own width. A caveat that runs past the edge gets re-wrapped by
  # whatever the text is pasted into, and the clause that goes missing is the last one -- which in
  # every note here is the part that says what the number means.
  wrapped <- if (is.null(notes)) NULL else
    unlist(lapply(notes, function(x) strwrap(x, width = 98, initial = "  ", prefix = "    ")))
  c(strrep("=", 98), title, if (!is.null(subtitle)) subtitle, strrep("=", 98), body,
    if (!is.null(notes)) c("", "notes:", wrapped))
}

#' Print both tables and write them where they can be copy-pasted out of the Workbench.
#'
#' Aggregate-only and small-cell-suppressed by the same rules as export_validation_summary() — but
#' read the output before pasting it. The suppression enforces the numeric rule it knows about; it
#' cannot tell you whether a combination of cells is disclosive in context.
#'
#' @return invisibly, list(table1, table4, text, path).
render_paper_tables <- function(res, cal = NULL, outdir = "reports", events_from = "acute",
                                min_cell = .pt_min_cell(), path = .PT_CONFIG_DEFAULT) {
  t1 <- make_paper_table1(res, events_from = events_from, min_cell = min_cell, path = path)
  t4 <- tryCatch(make_paper_table4(res, cal, min_cell = min_cell, path = path),
                 error = function(e) { message("Table 4 skipped: ", conditionMessage(e)); NULL })

  lm_ <- if (is.data.frame(res)) NULL else res$landmark
  eof <- if (is.data.frame(res)) NULL else res$end_of_followup
  hdr <- if (!is.null(lm_))
    sprintf("All of Us landmark cohort, %s -> %s (%.2f y)", format(lm_), format(eof),
            as.numeric(eof - lm_) / 365.25) else "All of Us landmark cohort"

  txt <- c(
    sprintf("PAPER-COMPARABLE TABLES  %s", format(Sys.Date())),
    "Khan SS et al., Circulation 2024;149:430-449 — Tables 1 and 4, rebuilt on our cohort.",
    hdr, "",
    .pt_render(.pt_render_table1(t1), "TABLE 1 — Baseline characteristics",
               "cholesterol in mmol/L to match the paper (our source values are mg/dL)",
               attr(t1, "notes")),
    "",
    if (!is.null(t4))
      .pt_render(.pt_render_table4(t4), "TABLE 4 — Model performance, ASCVD, base PREVENT model",
                 "ours: one cohort, 95% CI  |  paper: 21 validation cohorts, median and IQI",
                 attr(t4, "notes"))
    else c(strrep("=", 98), "TABLE 4 — not produced (no calibration object)",
           "  run make_prevent_calibration_figures(res) first; it needs AHAprevent and a scored panel.",
           strrep("=", 98)),
    "",
    "Tables 2 and 3 of the paper are hazard ratios from the derivation cohorts. Reproducing them",
    "would mean re-deriving PREVENT rather than validating it, so they are deliberately absent.")

  cat(paste(txt, collapse = "\n"), "\n")
  out_path <- NULL
  if (!is.null(outdir)) {
    if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
    out_path <- file.path(outdir, sprintf("paper_tables_%s.txt", format(Sys.Date())))
    writeLines(txt, out_path)
    message("\nwritten to ", out_path, "  <- paste this back")
  }
  invisible(list(table1 = t1, table4 = t4, text = txt, path = out_path))
}
