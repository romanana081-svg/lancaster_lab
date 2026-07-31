# literature_benchmarks.R -- is our observed ASCVD incidence in the same universe as the PREVENT
# paper's? VALIDATION layer 3, applied to the OUTCOME rather than to the equation.
#
# WHY THIS EXISTS. test-prevent-published-example.R proves the equation reproduces Khan et al.'s
# printed risks. That says nothing about our EVENTS: the equation could be perfect while the event
# ascertainment counts chronic IHD codes as incident MIs, or misses two-thirds of real events because
# the care happened outside the contributing health system. A survival curve drawn on either would
# look completely normal -- smooth, monotone, plausibly shaped, and wrong. The only cheap defence is
# to compare the RATE against a published rate before anybody reads a curve.
#
# WHAT IT IS NOT. Not a hypothesis test, and not a pass/fail gate on the science. The band in
# configs/config.yaml (literature.expected_ascvd_incidence) is deliberately wide because our cohort is
# older and EHR-selected (rate up) while EHR capture is partial (observed rate down). It answers one
# question: "is this number worth showing to an advisor, or does it need explaining first?"
#
# The reference values come from Khan SS et al., Circulation 2024;149:430-449 (open at PMC10910659),
# transcribed into configs/config.yaml so they are reviewable rather than buried here.

.CONFIG_DEFAULT <- "configs/config.yaml"

#' Read the literature block from config.yaml.
#'
#' @param path path to config.yaml; searched relative to the working directory, then two levels up
#'   (so this works from the repo root and from tests/testthat/).
#' @return the `literature` list.
read_literature_config <- function(path = .CONFIG_DEFAULT) {
  if (!requireNamespace("yaml", quietly = TRUE))
    stop("read_literature_config(): the `yaml` package is required.", call. = FALSE)
  tries <- c(path, file.path("..", path), file.path("..", "..", path))
  hit <- tries[file.exists(tries)]
  if (!length(hit))
    stop(sprintf("read_literature_config(): could not find %s from %s", path, getwd()), call. = FALSE)
  cfg <- yaml::read_yaml(hit[1])
  if (is.null(cfg$literature))
    stop("read_literature_config(): config.yaml has no `literature:` block.", call. = FALSE)
  cfg$literature
}

#' The published PREVENT ASCVD incidence rates, as a tidy frame (for printing next to ours).
prevent_published_rates <- function(path = .CONFIG_DEFAULT) {
  r <- read_literature_config(path)$prevent_paper$ascvd_rate_per_1000py
  data.frame(stratum = names(r), rate_per_1000py = unlist(r, use.names = FALSE),
             stringsAsFactors = FALSE)
}

#' Compare an observed incidence rate against the PREVENT literature band.
#'
#' Takes person-time explicitly rather than N x years, because the two differ exactly when it
#' matters: censoring. Passing `n_at_risk * years` when people are censored early overstates
#' person-time and understates the rate -- which is the single most likely way this check gets
#' silently fooled.
#'
#' @param n_events   incident events observed in the at-risk set.
#' @param person_years total follow-up time in the at-risk set (SUM of each person's follow-up).
#' @param n_at_risk  number of people at risk (for the cumulative-incidence line; optional).
#' @param label      what is being checked, e.g. "acute ASCVD, landmark 2018".
#' @param outcome    which outcome definition produced `n_events`. **"acute_event"** is the only one
#'   comparable to the published rate, which counts hard events (nonfatal MI, nonfatal stroke, CV
#'   death). **"broad"** is the D-016 primary outcome (all three classes); for it, the observed rate
#'   is reported but NO verdict is issued, because a first-ever chronic-IHD code is far commoner in
#'   EHR data than a first MI and the comparison would condemn a correct pipeline.
#' @param path       path to config.yaml.
#' @return invisibly, a list with the rate, the verdict, and the band. Prints a readable report.
check_incidence_vs_literature <- function(n_events, person_years, n_at_risk = NA,
                                          label = "acute ASCVD",
                                          outcome = c("acute_event", "broad"),
                                          path = .CONFIG_DEFAULT) {
  outcome <- match.arg(outcome)
  stopifnot(is.numeric(n_events), is.numeric(person_years), length(n_events) == 1)
  if (person_years <= 0)
    stop("check_incidence_vs_literature(): person_years must be > 0. Zero person-time usually means
  follow-up was never computed (every event-free person needs an end_of_followup date).", call. = FALSE)

  lit  <- read_literature_config(path)
  band <- unlist(lit$expected_ascvd_incidence$plausible_band_per_1000py)
  hard <- unlist(lit$expected_ascvd_incidence$investigate_outside)
  ref  <- lit$prevent_paper$ascvd_rate_per_1000py

  rate <- 1000 * n_events / person_years
  verdict <-
    if (outcome == "broad")               "NOT COMPARABLE -- see note"
    else if (rate < hard[1] || rate > hard[2]) "STRUCTURAL DEFECT LIKELY"
    else if (rate < band[1])              "LOW -- probable under-ascertainment"
    else if (rate > band[2])              "HIGH -- probable prevalent/chronic contamination"
    else                                  "PLAUSIBLE"

  cat(sprintf("\n=== incidence vs literature: %s ===\n", label))
  cat(sprintf("  events            : %s\n", format(n_events, big.mark = ",")))
  cat(sprintf("  person-years      : %s\n", format(round(person_years), big.mark = ",")))
  cat(sprintf("  observed rate     : %.2f per 1000 person-years\n", rate))
  if (!is.na(n_at_risk) && n_at_risk > 0)
    cat(sprintf("  cumulative        : %.2f%% over a mean %.1f y of follow-up\n",
                100 * n_events / n_at_risk, person_years / n_at_risk))
  cat(sprintf("  PREVENT published : %.2f (derivation) / %.2f (validation) per 1000 PY\n",
              ref$derivation_pooled, ref$validation_pooled))
  if (outcome == "broad") {
    cat(sprintf("  outcome           : BROAD (D-016: acute + chronic + revascularisation)\n"))
    cat(sprintf("  VERDICT           : %s\n", verdict))
    cat("  note              : the published rate is a HARD-outcome rate (nonfatal MI, nonfatal
                      stroke, CV death). Our broad outcome also counts a first-ever chronic
                      ASCVD diagnosis and a revascularisation, which are much commoner in EHR
                      data -- so a rate several times the published one is EXPECTED here and is
                      not evidence of contamination. Re-run with outcome = 'acute_event' to get
                      a number that can actually be compared.\n")
  } else {
    cat(sprintf("  plausible band    : %.1f - %.1f  (we are older + EHR-selected, so >published)\n",
                band[1], band[2]))
    cat(sprintf("  VERDICT           : %s\n", verdict))
    if (verdict != "PLAUSIBLE") {
      which_side <- if (rate < band[1]) "rationale_low" else "rationale_high"
      cat(sprintf("  most likely cause : %s\n",
                  gsub("\\s+", " ", lit$expected_ascvd_incidence[[which_side]])))
    }
  }
  cat("\n")

  invisible(list(rate_per_1000py = rate, verdict = verdict, band = band,
                 n_events = n_events, person_years = person_years))
}

#' Convenience wrapper: run the check straight off `ascvd_status_at()`'s output.
#'
#' Uses only rows in the AT-RISK set (`event` is 0 or 1). Prevalent participants AND those excluded
#' by the 30-day rule (D-017) both carry `event = NA` by construction and are excluded here for the
#' same reason they are excluded there -- counting them in the denominator would deflate every rate.
#'
#' @param status the frame returned by ascvd_status_at().
#' @param outcome see check_incidence_vs_literature(). Since D-016 made the BROAD outcome the
#'   default in ascvd_status_at(), the default here is "broad" too -- so the common call reports the
#'   right number and declines the wrong comparison, rather than silently making it.
check_incidence_from_status <- function(status, label = "ASCVD",
                                        outcome = c("broad", "acute_event"),
                                        path = .CONFIG_DEFAULT) {
  outcome <- match.arg(outcome)
  need <- c("event", "followup_days")
  miss <- setdiff(need, names(status))
  if (length(miss))
    stop(sprintf("check_incidence_from_status(): missing column(s): %s. Expected the output of
  ascvd_status_at().", paste(miss, collapse = ", ")), call. = FALSE)

  at_risk <- status[!is.na(status$event), , drop = FALSE]
  if (!nrow(at_risk)) stop("check_incidence_from_status(): the at-risk set is empty.", call. = FALSE)

  fu <- at_risk$followup_days
  if (any(is.na(fu)))
    stop("check_incidence_from_status(): at-risk rows with NA follow-up. Person-time cannot be
  summed over them, and dropping them silently would bias the rate.", call. = FALSE)

  check_incidence_vs_literature(
    n_events     = sum(at_risk$event == 1L),
    person_years = sum(fu) / 365.25,
    n_at_risk    = nrow(at_risk),
    label = label, outcome = outcome, path = path)
}
