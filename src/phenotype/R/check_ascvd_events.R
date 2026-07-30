# check_ascvd_events.R — the Workbench acceptance check for ASCVD event ascertainment. T-015.
#
# WHAT THIS IS FOR
#
# You run this in the All of Us Workbench and paste the output back out of the environment, so the
# code can be checked against real data by someone who cannot see the data. Every number it prints is
# therefore built to be PARTICIPANT-SAFE by construction, not by remembering to be careful:
#
#   * AGGREGATES ONLY — counts, rates, and year-level distributions. No person_id is ever printed, no
#     exact date, no row-level value.
#   * SMALL-CELL SUPPRESSION — any count in 1..19 prints as "<20" (H-006). A count of 0 prints as 0,
#     because "this code matched nothing" is a fact about our code list, not about a participant.
#   * NO FREE TEXT FROM THE DATA except vocabulary `concept_name`s, which are vocabulary metadata
#     (published in the OMOP/Athena dictionaries) and not participant data.
#
# The checks are LAYERED, in the order that tells failures apart -- the same discipline that saved
# months on the genomic-flag finding: "0 events", "wrong code list", and "no data provisioned" look
# identical from a single number, and only a layered check distinguishes them.
#
#   Layer 1  RESOLVE   — does each code prefix in the config match anything in the vocabulary at all?
#   Layer 2  CAPTURE   — which distinct codes does the definition ACTUALLY pull, with counts? This is
#                        what settles the CPT "929" over-capture question with evidence.
#   Layer 3  ICD9 GAP  — how many ASCVD-shaped rows sit in ICD9CM, which the config does not match?
#   Layer 4  EVENTS    — per-class person counts and first-event YEAR distribution.
#   Layer 5  INVARIANT — internal consistency assertions that must hold whatever the data says.
#
# RUN IT:
#   source("src/phenotype/R/run_sql.R")
#   source("src/phenotype/R/extract_ascvd_events.R")
#   source("src/phenotype/R/check_ascvd_events.R")
#   con <- connect_cdr()
#   check_ascvd_events(con)          # prints the report; paste the whole block back

suppressPackageStartupMessages({ library(dplyr) })

.SUPPRESS_THRESHOLD <- 20L

#' Small-cell suppression. Counts of 1..19 are not reported (H-006).
.sup <- function(n) {
  n <- as.numeric(n)
  ifelse(is.na(n), "NA", ifelse(n == 0, "0",
    ifelse(n < .SUPPRESS_THRESHOLD, paste0("<", .SUPPRESS_THRESHOLD), format(n, big.mark = ",",
                                                                            trim = TRUE))))
}

.rule <- function(title) cat("\n", strrep("=", 78), "\n", title, "\n", strrep("=", 78), "\n", sep = "")

#' Audit what the ASCVD outcome definition resolves to and actually captures.
#'
#' Layers 1-3. Separated from the event counts because these are questions about OUR CODE LIST, and
#' they are the ones that need answering before any event count means anything.
audit_ascvd_codes <- function(con, codes_path = .ASCVD_CODES_DEFAULT) {
  def   <- load_ascvd_codes(codes_path)
  codes <- def$codes

  # ---- Layer 1: does each prefix match ANY concept in the vocabulary? -----------------------------
  # A prefix that matches nothing is the silent-empty-phenotype failure mode: the query succeeds, the
  # phenotype is empty, and the number at the end of the pipeline is wrong but plausible.
  resolve <- do.call(rbind, lapply(seq_len(nrow(codes)), function(i) {
    q <- sprintf("SELECT COUNT(*) AS n_concepts FROM concept
                  WHERE vocabulary_id = '%s' AND concept_code LIKE '%s%%'",
                 codes$vocabulary_id[i], codes$code_prefix[i])
    data.frame(code_prefix = codes$code_prefix[i], class = codes$class[i],
               vocabulary_id = codes$vocabulary_id[i],
               n_concepts = as.numeric(DBI::dbGetQuery(con, q)$n_concepts),
               stringsAsFactors = FALSE)
  }))
  resolve$resolves <- ifelse(resolve$n_concepts > 0, "yes", "*** NO ***")

  # ---- Layer 2: what does the definition actually CAPTURE, code by code? -------------------------
  # Concept names come from the vocabulary, so they are safe to print; the person counts are
  # suppressed. This table is the evidence for pruning the code list (e.g. whether "929" is dragging
  # in CPR and cardioversion alongside PCI).
  cond_codes <- codes[codes$vocabulary_id %in% c("ICD10CM", "ICD9CM"), , drop = FALSE]
  proc_codes <- codes[codes$vocabulary_id %in% c("CPT4", "ICD10PCS"), , drop = FALSE]

  capture <- list()
  if (nrow(cond_codes)) {
    capture$condition <- DBI::dbGetQuery(con, sprintf("
      SELECT c.vocabulary_id, c.concept_code, c.concept_name,
             %s AS ascvd_class,
             COUNT(*) AS n_rows, COUNT(DISTINCT o.person_id) AS n_people
      FROM condition_occurrence o
      JOIN concept c ON c.concept_id = o.condition_source_concept_id
      WHERE c.vocabulary_id IN (%s) AND (%s)
      GROUP BY 1, 2, 3, 4
      ORDER BY n_people DESC, c.concept_code",
      .ascvd_class_case_sql(cond_codes),
      paste(sprintf("'%s'", unique(cond_codes$vocabulary_id)), collapse = ", "),
      .ascvd_prefix_filter_sql(cond_codes)))
  }
  if (nrow(proc_codes)) {
    capture$procedure <- DBI::dbGetQuery(con, sprintf("
      SELECT c.vocabulary_id, c.concept_code, c.concept_name,
             %s AS ascvd_class,
             COUNT(*) AS n_rows, COUNT(DISTINCT p.person_id) AS n_people
      FROM procedure_occurrence p
      JOIN concept c ON c.concept_id = p.procedure_source_concept_id
      WHERE c.vocabulary_id IN (%s) AND (%s)
      GROUP BY 1, 2, 3, 4
      ORDER BY n_people DESC, c.concept_code",
      .ascvd_class_case_sql(proc_codes),
      paste(sprintf("'%s'", unique(proc_codes$vocabulary_id)), collapse = ", "),
      .ascvd_prefix_filter_sql(proc_codes)))
  }

  # ---- Layer 3: size the ICD9CM gap ------------------------------------------------------------
  # The config is ICD10CM; All of Us EHR records before ~Oct-2015 are ICD9CM. This counts the
  # ASCVD-shaped ICD9 codes we are currently NOT matching, so the decision to add them (or to accept
  # the left-truncation) is made against a number. ICD9: 410 acute MI, 411 other acute IHD,
  # 412 old MI, 413 angina, 414 chronic IHD, 433/434 cerebral occlusion/infarct, 440 atherosclerosis.
  icd9 <- tryCatch(
    DBI::dbGetQuery(con, "
      SELECT c.concept_code, c.concept_name,
             COUNT(*) AS n_rows, COUNT(DISTINCT o.person_id) AS n_people
      FROM condition_occurrence o
      JOIN concept c ON c.concept_id = o.condition_source_concept_id
      WHERE c.vocabulary_id = 'ICD9CM'
        AND (c.concept_code LIKE '410%' OR c.concept_code LIKE '411%'
          OR c.concept_code LIKE '412%' OR c.concept_code LIKE '413%'
          OR c.concept_code LIKE '414%' OR c.concept_code LIKE '433%'
          OR c.concept_code LIKE '434%' OR c.concept_code LIKE '440%')
      GROUP BY 1, 2 ORDER BY n_people DESC"),
    error = function(e) NULL)

  list(resolve = resolve, capture = capture, icd9 = icd9, excluded = def$excluded)
}

#' The full participant-safe acceptance report. Print this and paste it back.
#'
#' @param con         open DBI connection (BigQuery in the Workbench, DuckDB fixture offline).
#' @param codes_path  the outcome definition config.
#' @param max_codes   how many rows of the capture table to print per source (the tail is long and
#'                    uninformative; the count of what was truncated is always reported).
#' @return invisibly, a list of the underlying frames (UNSUPPRESSED -- for use inside the Workbench
#'   only; only the printed output is safe to bring out).
check_ascvd_events <- function(con, codes_path = .ASCVD_CODES_DEFAULT, max_codes = 40L) {
  aud <- audit_ascvd_codes(con, codes_path)

  cat("ASCVD EVENT ASCERTAINMENT — acceptance check (T-015)\n")
  cat("All counts small-cell suppressed at <", .SUPPRESS_THRESHOLD,
      "; no person_ids, no exact dates. Safe to paste out.\n", sep = "")

  # ------------------------------------------------------------------ Layer 1
  .rule("LAYER 1 — does every code prefix RESOLVE in the vocabulary?")
  cat("A prefix matching 0 concepts is how a phenotype becomes silently empty.\n\n")
  r <- aud$resolve
  print(data.frame(prefix = r$code_prefix, class = r$class, vocab = r$vocabulary_id,
                   n_concepts = r$n_concepts, resolves = r$resolves), row.names = FALSE)
  if (any(r$n_concepts == 0)) {
    cat("\n*** ", sum(r$n_concepts == 0), " prefix(es) resolve to NOTHING. ***\n", sep = "")
    # This line matters: the same output means two different things depending on where it ran, and
    # confusing them wastes a meeting. On the fixture, a non-resolving prefix is a FIXTURE GAP (its
    # `concept` table holds ~208 seeded rows); in the real CDR it is a genuine finding about the
    # code list. Telling those apart is the whole point of running a layered check.
    cat("  If this ran against the FIXTURE: expected -- its vocabulary is ~208 seeded rows, so\n",
        "  I63 / I70 / I73 / Z95 / CABG are simply not seeded. Not a code-list problem.\n",
        "  If this ran against the REAL CDR: a real finding. Those codes pull NOTHING, and any\n",
        "  count below is missing them silently. Fix the config before trusting anything.\n", sep = "")
  }

  # ------------------------------------------------------------------ Layer 2
  .rule("LAYER 2 — what the definition ACTUALLY captures, code by code")
  cat("This is the table that settles whether the code list is too broad or too narrow.\n")
  cat("Concept names are vocabulary metadata (safe); person counts are suppressed.\n")
  for (src in names(aud$capture)) {
    cap <- aud$capture[[src]]
    cat("\n-- ", toupper(src), " (", nrow(cap), " distinct codes captured) --\n", sep = "")
    if (!nrow(cap)) { cat("   NOTHING CAPTURED. If Layer 1 resolved, this is a linkage failure:\n")
                      cat("   check that the source concept column is the one being joined.\n"); next }
    show <- head(cap[order(-cap$n_people), , drop = FALSE], max_codes)
    print(data.frame(vocab = show$vocabulary_id, code = show$concept_code,
                     class = show$ascvd_class,
                     name = substr(show$concept_name, 1, 46),
                     n_people = .sup(show$n_people)), row.names = FALSE)
    if (nrow(cap) > max_codes)
      cat("   ... and ", nrow(cap) - max_codes, " more codes not shown.\n", sep = "")
    cat("   class totals (distinct codes): ",
        paste(sprintf("%s=%d", names(table(cap$ascvd_class)), as.integer(table(cap$ascvd_class))),
              collapse = "  "), "\n", sep = "")
  }

  # ------------------------------------------------------------------ Layer 3
  .rule("LAYER 3 — the ICD9CM gap (codes we are NOT matching)")
  cat("The config is ICD10CM-only. Pre-2015 records are ICD9CM, so these rows are currently\n")
  cat("invisible to the outcome. This sizes the left-truncation.\n\n")
  if (is.null(aud$icd9) || !nrow(aud$icd9)) {
    cat("No ICD9CM ASCVD-shaped rows found (either none exist here, or ICD9 is not on the\n")
    cat("source column in this CDR). Either way: nothing is being silently dropped.\n")
  } else {
    show <- head(aud$icd9[order(-aud$icd9$n_people), , drop = FALSE], max_codes)
    print(data.frame(code = show$concept_code, name = substr(show$concept_name, 1, 46),
                     n_people = .sup(show$n_people)), row.names = FALSE)
    cat("\nDistinct ICD9 ASCVD codes present: ", nrow(aud$icd9),
        " | people with >=1 (upper bound, may overlap ICD10): ",
        .sup(sum(aud$icd9$n_people)), " (sum over codes, so an over-count)\n", sep = "")
    cat("=> DECISION NEEDED: add ICD9 prefixes to the config, or accept that follow-up effectively\n")
    cat("   starts ~2015. Do not leave this implicit -- it changes who counts as prevalent.\n")
  }

  # ------------------------------------------------------------------ Layer 4
  .rule("LAYER 4 — events: per-class people, and first-event YEAR")
  ev <- extract_ascvd_events(con, codes_path)
  if (!nrow(ev)) {
    cat("NO EVENTS EXTRACTED. If Layers 1-2 were non-empty, this is a bug in the extractor,\n")
    cat("not a fact about the data.\n")
  } else {
    by_class <- ev %>% group_by(.data$ascvd_class) %>%
      summarise(n_people = dplyr::n(),
                median_codes_per_person = stats::median(.data$n_codes),
                median_dates_per_person = stats::median(.data$n_dates),
                first_year = min(as.integer(format(.data$first_date, "%Y"))),
                last_year  = max(as.integer(format(.data$first_date, "%Y"))),
                .groups = "drop")
    print(data.frame(class = by_class$ascvd_class, n_people = .sup(by_class$n_people),
                     med_codes = by_class$median_codes_per_person,
                     med_dates = by_class$median_dates_per_person,
                     first_yr = by_class$first_year, last_yr = by_class$last_year),
          row.names = FALSE)

    cat("\n-- first ACUTE event by year (the incidence signal; suppressed) --\n")
    acute <- ev[ev$ascvd_class == "acute_event", , drop = FALSE]
    if (nrow(acute)) {
      yr <- as.data.frame(table(year = format(acute$first_date, "%Y")), stringsAsFactors = FALSE)
      print(data.frame(year = yr$year, n_people = .sup(yr$Freq)), row.names = FALSE)
    } else cat("   none\n")

    cat("\n-- outcome definition sensitivity (Q-A1: report BOTH ways) --\n")
    a  <- first_ascvd_event(ev, "acute_event")
    ar <- first_ascvd_event(ev, c("acute_event", "revascularisation"))
    cat("   acute only                  : ", .sup(nrow(a)),  " people\n", sep = "")
    cat("   acute + revascularisation   : ", .sup(nrow(ar)), " people\n", sep = "")
    cat("   any ASCVD code (prevalence) : ",
        .sup(nrow(first_ascvd_event(ev, c("acute_event", "chronic_disease",
                                          "revascularisation")))), " people\n", sep = "")
    if (nrow(a) && nrow(ar)) {
      moved <- sum(ar$event_date[match(a$person_id, ar$person_id)] < a$event_date, na.rm = TRUE)
      cat("   of the acute cases, ", .sup(moved), " have an EARLIER revascularisation date\n", sep = "")
      cat("   (i.e. adding revascularisation moves their event date earlier, not just adds cases)\n")
    }
  }

  # ------------------------------------------------------------------ Layer 5
  .rule("LAYER 5 — invariants (these must hold whatever the data says)")
  inv <- list()
  add <- function(name, ok, detail = "") inv[[length(inv) + 1L]] <<-
    data.frame(check = name, result = if (isTRUE(ok)) "PASS" else "*** FAIL ***",
               detail = detail, stringsAsFactors = FALSE)

  if (nrow(ev)) {
    add("one row per person x class",
        !any(duplicated(ev[, c("person_id", "ascvd_class")])))
    add("n_dates <= n_codes", all(ev$n_dates <= ev$n_codes))
    add("first_date is not NA", !any(is.na(ev$first_date)))
    add("no first_date in the future", all(ev$first_date <= Sys.Date()))
    add("every class is a known class",
        all(ev$ascvd_class %in% c("acute_event", "chronic_disease", "revascularisation")))
    add("acute subset of any-ASCVD",
        all(first_ascvd_event(ev, "acute_event")$person_id %in%
            first_ascvd_event(ev, c("acute_event", "chronic_disease",
                                    "revascularisation"))$person_id))
    add("revascularisation came from procedures",
        all(ev$source_table[ev$ascvd_class == "revascularisation"] == "procedure"),
        "a revasc row sourced from conditions means the vocabulary gate leaked")
    # Deliberately-excluded codes must NOT appear. This is the check that catches someone "helpfully"
    # widening the definition -- haemorrhagic stroke, PE, heart failure are different diseases.
    if (nrow(aud$excluded) && length(aud$capture)) {
      allcap <- do.call(rbind, lapply(aud$capture, function(x) x[, "concept_code", drop = FALSE]))
      leaked <- aud$excluded$code_prefix[vapply(aud$excluded$code_prefix, function(p)
        any(startsWith(allcap$concept_code, p)), logical(1))]
      add("deliberately-excluded codes absent", length(leaked) == 0,
          if (length(leaked)) paste("LEAKED:", paste(leaked, collapse = ", ")) else "")
    }
  } else add("events extracted", FALSE, "nothing to check")

  print(do.call(rbind, inv), row.names = FALSE)
  fails <- sum(vapply(inv, function(x) x$result != "PASS", logical(1)))
  cat("\n", if (fails == 0) "ALL INVARIANTS PASS" else sprintf("*** %d INVARIANT FAILURE(S) ***",
                                                               fails), "\n", sep = "")

  .rule("END — paste everything above back")
  invisible(list(audit = aud, events = ev))
}
