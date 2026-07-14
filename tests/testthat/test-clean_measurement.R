# Tests for clean_measurement() — T-005.
#
# These pin BOTH the behaviour we want AND the behaviour the notebook currently has, because the
# notebook's behaviour is what the existing (validated) results were produced with. A test that
# encodes a known bug is what stops the bug being fixed by accident, or reintroduced silently
# (VALIDATION.md §2 — the fixture uses the same trick).

source(file.path("..", "..", "src", "phenotype", "R", "clean_measurement.R"))

LIPID_BOUNDS <- list(min = 1, max = 1000)

mm <- function(person_id, value, date, unit = "mg/dL") {
  n <- length(person_id)
  data.frame(
    person_id = person_id,
    value_as_number = value,
    measurement_datetime = as.Date(date),
    unit_source_value = rep(unit, length.out = n),   # so a 0-row frame stays 0-row
    stringsAsFactors = FALSE
  )
}

test_that("keeps each person's earliest record", {
  df <- rbind(
    mm(1, 200, "2015-01-01"),
    mm(1, 150, "2012-05-02"),   # earliest -> this one wins
    mm(2, 120, "2018-03-03")
  )
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(nrow(out), 2)
  expect_equal(out$value[out$person_id == 1], 150)
  expect_equal(out$date[out$person_id == 1], as.Date("2012-05-02"))
})

test_that("anchor='latest' is available (A-001 — 'earliest' is likely wrong for a prediction study)", {
  df <- rbind(mm(1, 200, "2015-01-01"), mm(1, 150, "2012-05-02"))
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS,
                           anchor = "latest", tiebreak = "mean")
  expect_equal(out$value, 200)
})

test_that("drops non-physiologic values (A-004)", {
  df <- rbind(
    mm(1, 0,    "2015-01-01"),   # <= min
    mm(2, 5000, "2015-01-01"),   # >= max
    mm(3, 130,  "2015-01-01")    # keeper
  )
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(out$person_id, 3)
})

test_that("the LDL<400 cap is NOT applied unless asked for (A-004 — it would delete FH carriers)", {
  # An untreated familial hypercholesterolemia carrier. This is the single most important person in
  # a rare-variant study, and the notebook's <400 cap silently deletes them.
  df <- mm(1, 480, "2015-01-01")
  kept <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(kept$value, 480)

  dropped <- clean_measurement(df, units = "mg/dL", bounds = list(min = 1, max = 400),
                               tiebreak = "mean")
  expect_equal(nrow(dropped), 0)
})

test_that("unit filter is exact by default, and silently loses people (A-003, fixture defect A1)", {
  # Fixture participant 1000021: their ONLY LDL is recorded as lowercase 'mg/dl'. The notebook
  # drops them entirely, with no warning. This test pins that data loss so it stays visible.
  df <- mm(1, 135, "2015-01-01", unit = "mg/dl")
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(nrow(out), 0)   # <- the bug, asserted on purpose

  # ...and the fix, when opted into, recovers them.
  fixed <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS,
                             tiebreak = "mean", normalise_units = TRUE)
  expect_equal(fixed$value, 135)
})

test_that("accepts multiple unit spellings (the notebook accepts 'mg/dL{calc}' for LDL)", {
  df <- rbind(mm(1, 130, "2015-01-01", unit = "mg/dL{calc}"),
              mm(2, 140, "2015-01-01", unit = "mg/dL"))
  out <- clean_measurement(df, units = c("mg/dL", "mg/dL{calc}"),
                           bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(nrow(out), 2)
})

test_that("ALWAYS returns exactly one row per person, whatever the tiebreak", {
  # This is the invariant the whole R->Python contract rests on (D-005). Step 4 (min-date) alone
  # does NOT guarantee it -- same-day duplicates survive it -- which is why step 5 exists.
  df <- rbind(mm(1, 130, "2012-05-02"), mm(1, 131, "2012-05-02"), mm(1, 132, "2012-05-02"))
  for (tb in c("first", "mean", "min", "max", "median")) {
    out <- suppressWarnings(
      clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = tb))
    expect_equal(nrow(out), 1, info = tb)
  }
})

test_that("same-day duplicates: deterministic tiebreaks are deterministic (A-002)", {
  # Fixture participant 1000006 -- same-day LDL of 130, 131, 132. The answer key can only assert
  # `one_of:130|131|132` today, because the notebook's tiebreak is arbitrary. These are the
  # candidate replacements; the CHOICE between them is still open (configs: same_day_tiebreak).
  df <- rbind(mm(6, 130, "2012-05-02"), mm(6, 131, "2012-05-02"), mm(6, 132, "2012-05-02"))
  expect_equal(clean_measurement(df, units="mg/dL", bounds=LIPID_BOUNDS, tiebreak="mean")$value,   131)
  expect_equal(clean_measurement(df, units="mg/dL", bounds=LIPID_BOUNDS, tiebreak="median")$value, 131)
  expect_equal(clean_measurement(df, units="mg/dL", bounds=LIPID_BOUNDS, tiebreak="min")$value,    130)
  expect_equal(clean_measurement(df, units="mg/dL", bounds=LIPID_BOUNDS, tiebreak="max")$value,    132)

  # ...and the legacy path warns that it is NOT deterministic, rather than pretending otherwise.
  expect_warning(
    clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "first"),
    "not reproducible"
  )
})

test_that("rows with no usable value, date, or person_id are dropped (fixture defects A2, A5)", {
  df <- rbind(
    mm(1, NA, "2015-01-01"),           # censored lab: value_as_number NULL, e.g. '<10'  (A2)
    mm(NA, 130, "2015-01-01"),         # NULL person_id                                   (A5)
    mm(2, 130, NA),                    # undateable
    mm(3, 130, "2015-01-01")           # keeper
  )
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS, tiebreak = "mean")
  expect_equal(out$person_id, 3)
})

test_that("an empty input yields an empty, correctly-shaped frame rather than an error", {
  df <- mm(numeric(0), numeric(0), as.Date(character(0)))
  out <- clean_measurement(df, units = "mg/dL", bounds = LIPID_BOUNDS,
                           tiebreak = "mean", out_names = c("person_id", "LDL", "LDL_date"))
  expect_equal(nrow(out), 0)
  expect_named(out, c("person_id", "LDL", "LDL_date"))
})
