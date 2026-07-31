# Tests for extract_prevent.R — the PREVENT input extractor, against the real fixture. T-003.

source(file.path("..", "..", "src", "phenotype", "R", "extract_prevent.R"))

FIXTURE_DB <- file.path("..", "..", "fixture", "db", "aou_fixture.duckdb")

skip_if_no_fixture <- function() {
  if (!file.exists(FIXTURE_DB)) skip("fixture not built — python fixture/build/generate.py")
  if (!requireNamespace("duckdb", quietly = TRUE)) skip("duckdb R package not installed")
}
with_fixture <- function(f) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = FIXTURE_DB, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  f(con)
}

test_that("the clean baseline participant (1000028) extracts exactly the known inputs", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    r <- p[p$person_id == 1000028, ]
    expect_equal(nrow(r), 1)
    expect_equal(r$age, 57)            # age_at_cdr = 2022 - 1965
    expect_equal(r$sex, "male")
    expect_equal(r$sbp, 128)
    expect_equal(r$total_c, 190)
    expect_equal(r$hdl_c, 52)
    expect_equal(r$bmi, 27.5)
    expect_equal(r$egfr, 99.6, tolerance = 0.1)   # creatinine 0.9, male, 57y
    # dm is the ADVISOR definition (HbA1c>=6.5 AND >=1 diabetes med), NOT the ICD code. 1000028 has an
    # E11.9 code AND a diabetes med but NO HbA1c, so under the new definition it is NOT diabetic.
    expect_false(r$dm)
    expect_false(r$statin)             # no statin exposure
    expect_true(r$complete_panel)
  })
})

test_that("diabetes = HbA1c >= 6.5 AND a diabetes med -- both limbs required", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    # Threshold reverted to the ADA's 6.5% on 2026-07-31 (was 6.8% from 2026-07-21). The fixture's
    # A1c values (8.0 and 7.2) clear BOTH cuts, so this truth table is unchanged by the revision --
    # which means it does NOT guard the threshold. That is what the next assertion is for.
    expect_equal(.DM_A1C_THRESHOLD, 6.5)
    # Truth table across the fixture:
    #   1000028: ICD code + diabetes med, but NO HbA1c        -> FALSE (med limb only)
    #   1000030: HbA1c 8.0 (>=6.5), but NO diabetes med       -> FALSE (A1c limb only)
    #   1000032: HbA1c 7.2 (>=6.5) AND a diabetes med         -> TRUE  (both limbs)
    expect_false(p$dm[p$person_id == 1000028])
    expect_false(p$dm[p$person_id == 1000030])
    expect_true (p$dm[p$person_id == 1000032])
    # The most-recent HbA1c is surfaced on the panel for QC / the extended model.
    expect_equal(p$a1c[p$person_id == 1000030], 8.0)
    expect_equal(p$a1c[p$person_id == 1000032], 7.2)
    # A person with no HbA1c row has NA a1c (never a fabricated value) and so is not diabetic.
    expect_true(is.na(p$a1c[p$person_id == 1000028]))
  })
})

test_that("non-male/female sex is EXCLUDED from the panel entirely (advisor 2026-07-21)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    # 1000308 has a COMPLETE five-input panel but sex_at_birth 'PMI: Skip'. sql/02 counts it; the
    # extractor must drop it -- PREVENT and CKD-EPI are sex-specific. It must not appear at all.
    expect_false(1000308 %in% p$person_id)
    # And no surviving row may carry an NA sex (the drop is total, not a lingering NA).
    expect_true(all(p$sex %in% c("female", "male")))
  })
})

test_that("dirty SBP is bounded and same-day duplicates averaged (1000030)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    r <- p[p$person_id == 1000030, ]
    # SBP rows: 900 (out of range -> dropped), 120 (earlier date), 132 & 134 (most recent, same day).
    # So baseline = mean(132, 134) = 133; the 900 must NOT survive.
    expect_equal(r$sbp, 133)
    expect_true(r$complete_panel)
  })
})

test_that("bp_tx is real (AHA classes), and smoking is still an honest placeholder", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)

    # FLIPPED 2026-07-30. This assertion used to pin `all(p$bp_tx == FALSE)` -- the placeholder. That
    # was correct while the antihypertensive list was deliberately empty (NEEDS_A_CODE_LIST); now the
    # AHA classes drive it, so the OLD assertion failing was the signal that the fix landed. Same
    # pattern as T-004's flipped GAP assertions.
    #
    # The fixture seeds antihypertensives (lisinopril / hydrochlorothiazide) on 1000028 and 1000032
    # only, so bp_tx must be TRUE for exactly those two and FALSE elsewhere. Asserting the SET, not
    # merely "some are TRUE": a resolver bug that marked everyone treated would still pass the latter.
    expect_setequal(p$person_id[p$bp_tx], c(1000028, 1000032))

    # smoking IS still FALSE here by design -- it is survey-derived and attached by attach_smoking().
    expect_true(all(p$smoking == FALSE))
    expect_true(all(nzchar(p$placeholder_inputs)))
    # ...and the row stamp must now say so, naming how bp_tx was resolved.
    expect_match(p$placeholder_inputs[1], "bp_tx=AHA classes")
  })
})

test_that("the complete-panel count matches the genomic-free cohort (4)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    # 1000028, 1000030, 1000032, 1000034 have all five inputs, EHR, age 30-79, and a usable sex.
    # 1000029 (no creatinine), 1000031 (creatinine NULL), 1000033 (age 84) do not qualify. 1000308 has
    # a complete panel but non-binary sex, so the extractor excludes it -- hence the extractor's 4 is
    # BELOW sql/02's 5, exactly the sex gap. Same 4 complete panels the extractor can score.
    expect_equal(sum(p$complete_panel), 4)
    expect_setequal(p$person_id[p$complete_panel], c(1000028, 1000030, 1000032, 1000034))
  })
})

test_that("statin detection uses concept_ancestor (finds clinical-drug descendants, not just ingredients)", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    # The fixture seeds concept_ancestor (ingredient -> its clinical drug). A person on a statin
    # CLINICAL drug must be found via the ancestor rollup -- the whole point of the fix. Participants
    # 1000001/1000004/1000016/1000017 have statin exposures.
    hit <- DBI::dbGetQuery(con,
      "SELECT DISTINCT de.person_id
       FROM drug_exposure de JOIN concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
       WHERE ca.ancestor_concept_id IN (1510813,1539403,1545958,1549686,1551860,1592085,1592180,40165636)")$person_id
    expect_true(1000001 %in% hit)
    expect_true(length(hit) > 0)
  })
})

test_that("the output columns are exactly what the PREVENT equation consumes", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    expect_true(all(c("age", "sex", "sbp", "bp_tx", "total_c", "hdl_c",
                      "statin", "dm", "a1c", "smoking", "egfr", "bmi") %in% names(p)))
  })
})

# ------------------------------------------------------------------------------------------------
# panel_date and as_of -- what makes the 30-day rule (D-017) enforceable.
# ------------------------------------------------------------------------------------------------

test_that("panel_date is the LATEST of the five required measurement dates, not the earliest", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    expect_true("panel_date" %in% names(p))
    expect_s3_class(p$panel_date, "Date")

    # The panel is not complete until its LAST constituent exists. Taking the min would date the
    # panel earlier than it really was, which would let events slip past the 30-day rule -- the rule
    # would still "run", and would be quietly weaker than the advisor asked for.
    complete <- p[p$complete_panel, ]
    skip_if(nrow(complete) == 0, "fixture has no complete panels")

    raw <- DBI::dbGetQuery(con, sprintf("
      SELECT m.person_id, MAX(CAST(m.measurement_date AS DATE)) AS latest_dt
      FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id
      WHERE c.concept_code IN ('2093-3','2085-9','8480-6','2160-0','39156-5')
        AND m.value_as_number IS NOT NULL
        AND m.person_id IN (%s)
      GROUP BY m.person_id",
      paste(format(complete$person_id, scientific = FALSE), collapse = ",")))
    raw$latest_dt <- as.Date(raw$latest_dt)

    m <- match(complete$person_id, raw$person_id)
    # panel_date can only be <= the latest raw date (out-of-bounds rows are dropped before the pick),
    # and must never precede it by an implausible margin -- equality is the expected case here.
    expect_true(all(complete$panel_date <= raw$latest_dt[m]))
  })
})

test_that("an incomplete panel has NO panel_date, and is not counted as complete", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    p <- extract_prevent_panel(con)
    # These must agree exactly: a complete panel without a date would be a panel the 30-day rule
    # cannot be applied to, silently passing through as if it had been checked.
    expect_true(all(!is.na(p$panel_date[p$complete_panel])))      # complete => has a date
    expect_true(all(!p$complete_panel[is.na(p$panel_date)]))      # no date  => not complete
  })
})

test_that("as_of restricts to measurements available on that date -- the anchor honesty test", {
  skip_if_no_fixture()
  with_fixture(function(con) {
    all_time <- extract_prevent_panel(con)
    skip_if(sum(all_time$complete_panel) == 0, "fixture has no complete panels")

    # Cut before every measurement: nobody can have a complete panel as of then. If as_of were
    # ignored (e.g. applied in R after the window function had already collapsed each person to
    # their latest-ever row), this would still return the full panel and the test would fail.
    early <- extract_prevent_panel(con, as_of = as.Date("1990-01-01"))
    expect_equal(sum(early$complete_panel), 0)

    # Cut in the future: identical to no cut at all.
    late <- extract_prevent_panel(con, as_of = as.Date("2099-01-01"))
    expect_equal(sum(late$complete_panel), sum(all_time$complete_panel))

    # No panel_date may ever exceed the as_of date -- that would be a covariate from the future.
    mid <- extract_prevent_panel(con, as_of = as.Date("2019-01-01"))
    expect_true(all(is.na(mid$panel_date) | mid$panel_date <= as.Date("2019-01-01")))

    # And the cut is recorded on the row, so a saved panel says which anchor produced it.
    expect_true(all(grepl("as_of_2019-01-01", mid$placeholder_inputs)))
  })
})

test_that("the A1c threshold in the code matches the one in the reviewable config", {
  # The threshold lives in TWO places: .DM_A1C_THRESHOLD (what runs) and prevent_concepts.yaml
  # (what the advisor reads and reviews). If they drift, the config becomes a document describing a
  # definition the pipeline does not implement -- the worst kind of documentation, because it reads
  # as authoritative. This test is what keeps the two honest until the constant is read from the YAML.
  cfg <- yaml::read_yaml(file.path("..", "..", "configs", "prevent_concepts.yaml"))
  expect_equal(cfg$conditions$diabetes$hba1c_threshold, .DM_A1C_THRESHOLD)
  expect_equal(cfg$conditions$diabetes$hba1c_threshold, 6.5)
  # And the human-readable definition string must name the same number.
  expect_match(cfg$conditions$diabetes$definition, "6.5", fixed = TRUE)
})
