# case_cohort_report.R — one command that builds the case-anchored cohort and writes an
# aggregate-only report safe to bring out of the Workbench. D-016 / D-017 / D-019.
#
# SAFETY: every number below is a count, a median, or a percentage over >= 20 people. Counts under 20
# print as "<20" (H-006 small-cell suppression). No person_ids, no exact dates, no per-person rows.
# The whole file can be pasted out.
#
# STRUCTURE, and why it is in this order: Section 1 runs even if no cohort can be built, because
# "zero qualifying cases" and "the code is broken" look identical from an error message. Section 1
# tells them apart -- it reports how many events exist, how many people ever have a complete panel,
# and the DISTRIBUTION OF DAYS between panel-ready and event, which is what decides whether the
# 30-day rule (D-017) costs a little or nearly everything.

.sup <- function(n, min_cell = 20) if (is.na(n)) "NA" else
  if (n > 0 && n < min_cell) "<20" else format(n, big.mark = ",", trim = TRUE)

#' Build the case-anchored cohort and write the report.
#'
#' @param con open DBI connection (BigQuery in the Workbench).
#' @param washout_days D-017. @param ratio controls per case. @param seed reproducibility.
#' @param outdir where to write. @return the path written (invisibly also returns the frames).
case_cohort_report <- function(con, washout_days = 30, ratio = 10, seed = 20260731,
                               outdir = "reports") {
  stopifnot(exists("extract_ascvd_events", mode = "function"),
            exists("build_case_anchored_cohort", mode = "function"))
  if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
  path <- file.path(outdir, sprintf("case_cohort_report_%s.txt", format(Sys.Date())))
  con_out <- file(path, open = "wt")
  say <- function(...) { cat(..., "\n", sep = "", file = con_out, append = TRUE); cat(..., "\n", sep = "") }
  hdr <- function(t) { say(""); say("=== ", t, " ==="); say("") }

  say("CASE-ANCHORED COHORT REPORT   ", format(Sys.time(), "%Y-%m-%d %H:%M"))
  say("params: washout_days=", washout_days, "  ratio=", ratio, ":1  seed=", seed)
  say("outcome: ALL THREE ASCVD classes count as an event (D-016)")
  say("aggregate only; counts <20 shown as <20")

  # ---------------------------------------------------------------------------------------------
  hdr("1. RAW MATERIAL — events, and who could ever be scored")
  events <- extract_ascvd_events(con)
  by_class <- table(events$ascvd_class)
  for (nm in names(by_class)) say(sprintf("  %-20s people with >=1 code : %s", nm, .sup(by_class[[nm]])))

  ready <- DBI::dbGetQuery(con, "
    WITH firsts AS (
      SELECT m.person_id, c.concept_code AS code,
             MIN(CAST(m.measurement_date AS DATE)) AS first_dt
      FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
      WHERE c.vocabulary_id = 'LOINC' AND m.value_as_number IS NOT NULL
        AND c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
      GROUP BY m.person_id, c.concept_code
    )
    SELECT person_id, MAX(first_dt) AS panel_ready_date, COUNT(*) AS n_inputs
    FROM firsts GROUP BY person_id")
  ready$panel_ready_date <- as.Date(ready$panel_ready_date)
  say("")
  say("  people with >=1 of the 5 panel inputs      : ", .sup(nrow(ready)))
  say("  people whose panel EVER becomes complete   : ", .sup(sum(ready$n_inputs == 5)))
  say("  (a person who never has all 5 can be neither a case nor a control)")

  # ---------------------------------------------------------------------------------------------
  hdr("2. THE 30-DAY RULE — what it costs, before it is applied")
  first_any <- first_ascvd_event(events, c("acute_event", "chronic_disease", "revascularisation"))
  m <- match(first_any$person_id, ready$person_id)
  gap <- as.numeric(first_any$event_date - ready$panel_ready_date[m])
  # Build the mask on the FULL vector, then subset once. Subsetting `ready$n_inputs[m]` by a mask
  # derived from `gap` recycles a shorter vector against a longer one and silently mis-selects rows.
  ok <- !is.na(m) & !is.na(gap) & ready$n_inputs[m] == 5
  ok[is.na(ok)] <- FALSE
  gap <- gap[ok]

  say("  people with an event AND an ever-complete panel : ", .sup(length(gap)))
  if (length(gap) >= 20) {
    q <- stats::quantile(gap, c(0.10, 0.25, 0.50, 0.75, 0.90), names = FALSE)
    say(sprintf("  days from panel-complete to event  p10/p25/median/p75/p90 : %.0f / %.0f / %.0f / %.0f / %.0f",
                q[1], q[2], q[3], q[4], q[5]))
    say("  panel completed BEFORE the event        : ",
        sprintf("%s (%.1f%%)", .sup(sum(gap > 0)), 100 * mean(gap > 0)))
    say("  ...and at least ", washout_days, " days before      : ",
        sprintf("%s (%.1f%%)", .sup(sum(gap >= washout_days)), 100 * mean(gap >= washout_days)))
    say("")
    say("  READ THIS ONE: a large negative/small-gap share means the panel and the event arrive in")
    say("  the same clinical episode -- which is exactly the reverse causation D-017 removes, and")
    say("  also exactly what makes the rule expensive. Both facts at once.")
  }

  # ---------------------------------------------------------------------------------------------
  hdr("3. THE COHORT")
  res <- tryCatch(
    build_case_anchored_cohort(con, events, washout_days = washout_days, ratio = ratio, seed = seed),
    error = function(e) { say("  COULD NOT BUILD: ", conditionMessage(e)); NULL })

  if (!is.null(res)) {
    for (i in seq_len(nrow(res$dropped)))
      say(sprintf("  %-52s %s", res$dropped$step[i], .sup(res$dropped$n[i])))
    say("")
    rt <- table(res$cohort$role)
    say("  cases in the cohort     : ", .sup(unname(rt["case"])))
    say("  controls sampled        : ", .sup(unname(rt["control"])))
    say("  risk sets               : ", .sup(length(unique(res$cohort$risk_set_id))))
    say("  controls who later become cases (expected, kept on purpose) : ",
        .sup(sum(res$cohort$becomes_case_later)))
    ctlw <- res$cohort$weight[res$cohort$role == "control"]
    if (length(ctlw) >= 20)
      say(sprintf("  control sampling weight  median %.1f  (range %.1f - %.1f)",
                  stats::median(ctlw), min(ctlw), max(ctlw)))
    say("  risk sets that could not fill the ratio : ",
        .sup(sum(tapply(res$cohort$role == "control", res$cohort$risk_set_id, sum) < ratio)))
  }

  # ---------------------------------------------------------------------------------------------
  hdr("4. PREVENT AT THE ANCHOR — does it score cases above controls?")
  scored <- NULL
  if (!is.null(res)) scored <- tryCatch({
    coh <- attach_panel_at_anchor(con, res$cohort)

    # Demographics + the person-level drug/diabetes flags. NOTE these come from the unanchored panel:
    # statin / bp_tx / dm are "EVER" flags in the current extractor, not as-of-anchor. State that --
    # for a case, an "ever" statin flag can reflect treatment STARTED AFTER the event, which biases
    # toward making cases look treated. It is a known limitation, not a silent one. (TODO: anchor them.)
    base <- extract_prevent_panel(con)
    keep <- c("person_id", "age", "sex", "statin", "bp_tx", "dm", "smoking")
    coh  <- merge(coh, base[, intersect(keep, names(base))], by = "person_id", all.x = TRUE)

    coh$egfr <- egfr_ckd_epi_2021(coh$creatinine, coh$age, coh$sex)
    run_prevent(coh)
  }, error = function(e) { say("  SKIPPED: ", conditionMessage(e)); NULL })

  if (!is.null(scored) && "prevent_base_10yr_ASCVD" %in% names(scored)) {
    sc <- scored[!is.na(scored$prevent_base_10yr_ASCVD), ]
    say("  scorable rows (all inputs present at anchor) : ",
        .sup(nrow(sc)), " of ", .sup(nrow(scored)))
    if (nrow(sc) >= 40) {
      agg <- stats::aggregate(prevent_base_10yr_ASCVD ~ role, sc,
                              function(x) c(n = length(x), mean = mean(x), med = stats::median(x)))
      for (i in seq_len(nrow(agg))) {
        v <- agg[[2]][i, ]
        say(sprintf("  %-8s n=%-8s mean 10yr ASCVD %.2f%%   median %.2f%%",
                    agg$role[i], .sup(v[["n"]]), v[["mean"]], v[["med"]]))
      }
      say("")
      # The one-number version of "does PREVENT work here at all": the probability that a randomly
      # chosen case scores above a randomly chosen control. This IS the C-statistic for a matched
      # sample, and it is the headline of the validation half (T-007).
      cs <- sc$prevent_base_10yr_ASCVD[sc$role == "case"]
      ct <- sc$prevent_base_10yr_ASCVD[sc$role == "control"]
      if (length(cs) >= 20 && length(ct) >= 20) {
        w <- stats::wilcox.test(cs, ct)$statistic
        say(sprintf("  AUC (P[case scores above control]) : %.3f", w / (length(cs) * length(ct))))
        say("  Khan et al. external validation, base model, ASCVD: 0.774 female / 0.736 male.")
        say("  Ours is on a MATCHED sample, so it is comparable for DISCRIMINATION but not for")
        say("  absolute calibration -- that needs the sampling weights (10:1 inflates the event rate).")
      }
    } else say("  too few scorable rows to report a comparison")
  }

  hdr("5. CAVEATS THAT TRAVEL WITH THESE NUMBERS")
  say("  - statin / bp_tx / dm are EVER flags, not as-of-anchor. For a case these can reflect")
  say("    treatment started after the event. Anchoring them is the next fix.")
  say("  - smoking answer coding is PROVISIONAL; bp_tx is PROVISIONAL_AHA_CLASSES.")
  say("  - outcome is ICD10CM-only, so pre-2015 (ICD9) events are invisible; CPT '929' over-captures")
  say("    (92950 CPR, 92960 cardioversion). Both measured by workbench_report() Layers 2-3.")
  say("  - chronic_disease codes date a DIAGNOSIS, not an onset -- partly a measure of care contact.")
  say("")
  say("END OF REPORT — safe to paste out whole.")
  close(con_out)
  message("written: ", path)
  invisible(list(path = path, res = res, scored = scored))
}
