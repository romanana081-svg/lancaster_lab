"""Replay the notebook's R cleaning pipeline over the fixture's CSV exports and
diff the result against the hand-authored answer key.

This is a *simulation* of the R code in `LDLR Get phenotypes.ipynb` -- it mirrors
the same steps (unit filter -> physiologic bounds -> earliest record -> distinct ->
rename -> left_join -> collapse), including the bug in FORMAT.md sec.7.3, which is
reproduced deliberately rather than fixed. It is a test oracle for the fixture, not
a replacement for running the notebook.

Run:  py fixture/build/verify.py
"""
import csv
import pathlib

import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / "fixture"
BUCKET = "fc-secure-7e84f6f0-9e03-4626-b34e-6dcf5d5f1701"
OWNER = "megan.lancaster@researchallofus.org"
EXPORTS = FIX / "bucket" / BUCKET / "bq_exports" / OWNER

TRIG, CHOL_EXCLUDED = 3022192, 3008631
SURVEY_YES = ("Are you currently prescribed medications and/or receiving treatment "
              "for high cholesterol? - Yes")


def glob(date, name):
    return (EXPORTS / date / name / f"{name}_*.csv").as_posix()


con = duckdb.connect()

# --- the per-domain cleaning idiom, as SQL -------------------------------------
# R's `group_by(person_id) %>% filter(d == min(d))` then `distinct(person_id, .keep_all=TRUE)`
# == "earliest record per person, first row wins ties". row_number() over the file
# order reproduces R's distinct(), which keeps the first occurrence.
def earliest(view, date_col):
    return f"""
    SELECT * EXCLUDE (_rn, _rk) FROM (
      SELECT *, row_number() OVER () AS _rn,
             row_number() OVER (PARTITION BY person_id ORDER BY {date_col}, _ord) AS _rk
      FROM (SELECT *, row_number() OVER () AS _ord FROM {view})
    ) WHERE _rk = 1"""


con.execute(f"""
CREATE VIEW labs_raw AS SELECT * FROM read_csv_auto('{glob("20240321", "measurement_65837970")}', union_by_name=true);
CREATE VIEW bmi_raw  AS SELECT * FROM read_csv_auto('{glob("20240324", "measurement_80780919")}', union_by_name=true);
CREATE VIEW icd_raw  AS SELECT * FROM read_csv_auto('{glob("20240321", "condition_99802609")}', union_by_name=true);
CREATE VIEW cpt_raw  AS SELECT * FROM read_csv_auto('{glob("20240321", "procedure_35162265")}', union_by_name=true);
CREATE VIEW statin_raw    AS SELECT * FROM read_csv_auto('{glob("20240321", "drug_32584860")}', union_by_name=true);
CREATE VIEW nonstatin_raw AS SELECT * FROM read_csv_auto('{glob("20240321", "drug_41010260")}', union_by_name=true);
CREATE VIEW survey_raw AS SELECT * FROM read_csv_auto('{glob("20240321", "survey_43208585")}', union_by_name=true);
CREATE VIEW demo       AS SELECT * FROM read_csv_auto('{glob("20240321", "person_09842086")}', union_by_name=true);
CREATE VIEW pad_raw    AS SELECT * FROM read_csv_auto('{glob("20241101", "condition_32633938")}', union_by_name=true);
CREATE VIEW cadfh_raw  AS SELECT * FROM read_csv_auto('{glob("20241101", "observation_59227507")}', union_by_name=true);
CREATE VIEW hc_raw     AS SELECT * FROM read_csv_auto('{glob("20241104", "condition_86884566")}', union_by_name=true);

-- LDL is defined NEGATIVELY in the notebook: anything that is not trig and not 3008631.
CREATE VIEW ldl_f AS SELECT * FROM labs_raw
  WHERE measurement_concept_id NOT IN ({TRIG}, {CHOL_EXCLUDED})
    AND unit_source_value = 'mg/dL'
    AND value_as_number > 1 AND value_as_number < 1000;
CREATE VIEW trig_f AS SELECT * FROM labs_raw
  WHERE measurement_concept_id = {TRIG}
    AND unit_source_value = 'mg/dL'
    AND value_as_number > 1 AND value_as_number < 1000;
CREATE VIEW bmi_f AS SELECT * FROM bmi_raw
  WHERE unit_source_value = 'kg/m2' AND value_as_number > 14 AND value_as_number < 60;

CREATE VIEW ldl_df  AS {earliest('ldl_f',  'measurement_datetime')};
CREATE VIEW trig_df AS {earliest('trig_f', 'measurement_datetime')};
CREATE VIEW bmi_df  AS {earliest('bmi_f',  'measurement_datetime')};
CREATE VIEW icd_df  AS {earliest('icd_raw', 'condition_start_datetime')};
CREATE VIEW cpt_df  AS {earliest('cpt_raw', 'procedure_datetime')};
CREATE VIEW pad_df  AS {earliest('pad_raw', 'condition_start_datetime')};
CREATE VIEW hc_df   AS {earliest('hc_raw',  'condition_start_datetime')};
CREATE VIEW cadfh_df AS {earliest('cadfh_raw', 'observation_datetime')};
CREATE VIEW statin_df    AS {earliest('statin_raw',    'drug_exposure_start_datetime')};
CREATE VIEW nonstatin_df AS {earliest('nonstatin_raw', 'drug_exposure_start_datetime')};
CREATE VIEW survey_df    AS {earliest('survey_raw',    'survey_datetime')};

-- codes_df: rbind(icd, cpt) then re-reduce to the earliest per person
CREATE VIEW codes_all AS
  SELECT person_id, CAST(condition_start_datetime AS DATE) AS dt FROM icd_df
  UNION ALL
  SELECT person_id, CAST(procedure_datetime AS DATE) AS dt FROM cpt_df;
CREATE VIEW codes_df AS SELECT person_id, min(dt) AS CAD_code_date FROM codes_all GROUP BY 1;

-- meds_df: full_join(statin, nonstatin, survey). NOTE the survey frame contains
-- EVERY responder, including those who answered "No" -- this is what drives the
-- FORMAT.md sec.7.3 bug downstream.
CREATE VIEW meds_df AS
SELECT person_id,
       min(statin_start)    AS statin_start,
       min(nonstatin_start) AS nonstatin_start,
       min(survey_dt)       AS survey_dt,
       max(ans_yes)         AS ans_yes
FROM (
  SELECT person_id, CAST(drug_exposure_start_datetime AS DATE) AS statin_start,
         NULL::DATE AS nonstatin_start, NULL::DATE AS survey_dt, 0 AS ans_yes FROM statin_df
  UNION ALL
  SELECT person_id, NULL, CAST(drug_exposure_start_datetime AS DATE), NULL, 0 FROM nonstatin_df
  UNION ALL
  SELECT person_id, NULL, NULL, CAST(survey_datetime AS DATE),
         CASE WHEN answer = '{SURVEY_YES}' THEN 1 ELSE 0 END FROM survey_df
) GROUP BY person_id;
""")

# --- the join + collapse (pheno_df -> pheno_df2) -------------------------------
pheno = con.execute("""
SELECT d.person_id,
       CAST(d.date_of_birth AS DATE)                    AS date_of_birth,
       d.race, d.sex_at_birth,
       l.value_as_number                                AS LDL,
       CAST(l.measurement_datetime AS DATE)             AS Date_LDL_assessment,
       t.value_as_number                                AS Trig,
       b.value_as_number                                AS BMI,
       CASE WHEN c.person_id IS NULL THEN 0 ELSE 1 END  AS CAD_code,
       c.CAD_code_date,
       CASE WHEN p.person_id IS NULL THEN 0 ELSE 1 END  AS PAD_code,
       CASE WHEN h.person_id IS NULL THEN 0 ELSE 1 END  AS HC_code,
       CASE WHEN f.person_id IS NULL THEN 'FALSE' ELSE 'TRUE' END AS CADFH_code,
       -- pheno_df2$any_chol_med[!is.na(...)] <- 1 : ANY row present in meds_df
       -- becomes 1, including people whose survey answer was "No" (sec.7.3).
       CASE WHEN m.person_id IS NULL THEN 0 ELSE 1 END  AS any_chol_med,
       least(coalesce(m.statin_start,    DATE '9999-12-31'),
             coalesce(m.nonstatin_start, DATE '9999-12-31'),
             coalesce(m.survey_dt,       DATE '9999-12-31'))
         AS any_chol_med_start_date_raw,
       m.ans_yes
FROM demo d
LEFT JOIN ldl_df  l ON l.person_id = d.person_id
LEFT JOIN trig_df t ON t.person_id = d.person_id
LEFT JOIN bmi_df  b ON b.person_id = d.person_id
LEFT JOIN codes_df c ON c.person_id = d.person_id
LEFT JOIN pad_df  p ON p.person_id = d.person_id
LEFT JOIN hc_df   h ON h.person_id = d.person_id
LEFT JOIN cadfh_df f ON f.person_id = d.person_id
LEFT JOIN meds_df m ON m.person_id = d.person_id
ORDER BY d.person_id
""").fetchall()
cols = [c[0] for c in con.description]
rows = {}
for r in pheno:
    rec = dict(zip(cols, r))
    start = rec.pop("any_chol_med_start_date_raw")
    rec["any_chol_med_start_date"] = None if str(start) == "9999-12-31" else start
    ldl_d, med_d = rec["Date_LDL_assessment"], rec["any_chol_med_start_date"]
    # case_when() with no .default -> NA when either side is missing (defect A7)
    rec["LDL_measured_on_meds"] = "NA" if (ldl_d is None or med_d is None) else int(ldl_d > med_d)
    rows.setdefault(rec["person_id"], []).append(rec)

# --- diff against the answer key ----------------------------------------------
key = list(csv.DictReader((FIX / "expected" / "answer_key.csv").open(encoding="utf-8")))
CHECK = ["CAD_code", "CAD_code_date", "LDL", "Date_LDL_assessment", "BMI", "any_chol_med",
         "any_chol_med_start_date", "LDL_measured_on_meds", "PAD_code", "HC_code",
         "CADFH_code", "race"]


def norm(v):
    if v is None or v == "":
        return "NA"
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v)


print(f"{'person':<9} {'result':<8} scenario / mismatches")
print("-" * 100)
n_ok = n_expected_fail = n_bad = 0
for k in key:
    pid = int(k["person_id"])
    got = rows.get(pid)

    if k["CAD_code"] == "absent":                       # P20: outside the srWGS cohort
        if got is None:
            print(f"{pid:<9} {'PASS':<8} {k['scenario']}")
            n_ok += 1
        else:
            print(f"{pid:<9} {'FAIL':<8} {k['scenario']} -- PRESENT but must be absent")
            n_bad += 1
        continue

    if got is None:
        print(f"{pid:<9} {'FAIL':<8} {k['scenario']} -- missing from pheno_df")
        n_bad += 1
        continue

    if k.get("note") == "expect 2 rows, not 1":         # P26: duplicate person row (A4)
        tag = "PASS" if len(got) == 2 else "FAIL"
        print(f"{pid:<9} {tag:<8} {k['scenario']} (got {len(got)} rows)")
        n_ok += 1 if tag == "PASS" else 0
        n_bad += 0 if tag == "PASS" else 1
        continue

    rec = got[0]
    diffs = []
    for c in CHECK:
        want = k.get(c, "")
        if want == "":
            continue
        have = norm(rec.get(c))
        # "one_of:a|b|c" -- the pipeline's tie-break among same-day duplicates is
        # order-dependent, so only membership is assertable (see D3 / P06).
        if want.startswith("one_of:"):
            if have not in want[len("one_of:"):].split("|"):
                diffs.append(f"{c}: expected one of {want[7:]}, got {have}")
            continue
        if norm(want) != have:
            diffs.append(f"{c}: expected {norm(want)}, got {have}")

    if not diffs:
        print(f"{pid:<9} {'PASS':<8} {k['scenario']}")
        n_ok += 1
    elif "sec.7.3" in k["scenario"]:
        # The known bug: this SHOULD mismatch. A pass here would mean it was fixed.
        print(f"{pid:<9} {'BUG':<8} {k['scenario']}")
        for d in diffs:
            print(f"{'':<18} {d}")
        n_expected_fail += 1
    else:
        print(f"{pid:<9} {'FAIL':<8} {k['scenario']}")
        for d in diffs:
            print(f"{'':<18} {d}")
        n_bad += 1

print("-" * 100)
print(f"{n_ok} pass, {n_expected_fail} reproduced-bug (expected), {n_bad} unexpected failure(s)")
raise SystemExit(1 if n_bad else 0)
