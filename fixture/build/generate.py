"""Build the synthetic All of Us CDR fixture described in FORMAT.md.

Creates fixture/db/aou_fixture.duckdb with the 12 tables the LDLR notebook queries
(plus empty stubs for schema completeness), seeded with the concept vocabulary the
notebook's hardcoded IDs require and with the defects catalogued in FORMAT.md sec.7.

Run:  py fixture/build/generate.py
"""
import csv
import pathlib
import random
import re

import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / "fixture"
QUERIES = FIX / "build" / "queries"
DB_PATH = FIX / "db" / "aou_fixture.duckdb"

random.seed(20240321)  # deterministic fixture

# --------------------------------------------------------------------------
# Concept IDs, lifted straight out of the notebook's generated SQL so the
# fixture can never drift from the queries it has to satisfy.
# --------------------------------------------------------------------------


def ids_from(query_name, which=0):
    """Pull the Nth `concept_id IN (...)` list out of an extracted query."""
    sql = (QUERIES / f"{query_name}.sql").read_text(encoding="utf-8")
    lists = re.findall(r"concept_id\s+IN\s*\(\s*([\d,\s]+?)\s*\)", sql)
    return [int(x) for x in lists[which].replace("\n", "").split(",") if x.strip()]


CAD_ICD = ids_from("dataset_99802609_condition_sql")          # source concepts, is_standard=0
CAD_CPT = ids_from("dataset_35162265_procedure_sql")          # source concepts, is_standard=0
PAD = ids_from("dataset_32633938_condition_sql")              # standard, is_standard=1
FH_OBS = ids_from("dataset_64642663_observation_sql")         # direct filter, no cb_criteria
FH_COND = ids_from("dataset_64642663_condition_sql")          # source, is_standard=0
CADFH_OBS = ids_from("dataset_59227507_observation_sql")      # direct filter
HC = ids_from("dataset_86884566_condition_sql")               # source, is_standard=0
STATIN = ids_from("dataset_32584860_drug_sql")                # standard -> cb_criteria_ancestor
NONSTATIN = ids_from("dataset_41010260_drug_sql")             # standard -> cb_criteria_ancestor
LABS = ids_from("dataset_65837970_measurement_sql")           # standard, is_standard=1
BMI = ids_from("dataset_80780919_measurement_sql")            # standard, is_standard=1
SURVEY_Q = ids_from("dataset_43208585_survey_sql")[0]         # 43528793

# Measurement leaves. The notebook defines LDL *negatively* (anything that is not
# 3022192 or 3008631), so what lives under the lipid group node matters a lot.
TRIG = 3022192          # triglycerides
LIPID_GROUP = 37026687  # group node the query names
LDL = 3028288           # LDL cholesterol -- the intended LDL concept
CHOL_EXCLUDED = 3008631 # explicitly excluded by ldl_df
STRAY = 3007352         # defect A9: not 3022192, not 3008631 -> silently becomes "LDL"
BMI_C = BMI[0]          # 3038553

# Standard concepts the source-coded rows map to (needed only so the LEFT JOINs
# to `concept` resolve to a name rather than NULL).
CAD_STD, PAD_STD, HC_STD, FH_STD = 312327, 321052, 437827, 4059317
CPT_STD = 4336464

UNIT_MGDL, UNIT_KGM2 = 8840, 9531
VISIT_IP, VISIT_OP, VISIT_ER, VISIT_OFFICE = 9201, 9202, 9203, 581477
TYPE_EHR, TYPE_SURVEY = 32817, 45905771
OP_LT = 4171756

RACES = {
    8527: "White",
    8516: "Black or African American",
    8515: "Asian",
    38003615: "Middle Eastern or North African",
    903096: "PMI: Skip",
    1177221: "I prefer not to answer",
    0: "None Indicated",
}
SEXES = {8507: "Male", 8532: "Female", 903096: "PMI: Skip", 0: "None Indicated"}

SURVEY_TEXT = "Are you currently prescribed medications and/or receiving treatment for high cholesterol?"
SURVEY_YES = f"{SURVEY_TEXT} - Yes"
SURVEY_NO = f"{SURVEY_TEXT} - No"

# Unit strings. AoU does not harmonise unit_source_value; only the exact string
# 'mg/dL' survives the notebook's filter (defect D1 / A1).
DIRTY_MGDL = ["mg/dL", "mg/dL", "mg/dL", "mg/dl", "MG/DL", "mg/dL calc", "mmol/L", "", "unk"]
DIRTY_KGM2 = ["kg/m2", "kg/m2", "kg/m2", "kg/m^2", "Kg/M2", ""]

# --------------------------------------------------------------------------
# Row accumulators
# --------------------------------------------------------------------------
concept, cb_criteria, cb_anc, cb_person = [], [], [], []
person, visit, cond, proc, meas, obs, drug, survey = [], [], [], [], [], [], [], []
answers = []

_ids = {}


def nid(kind):
    _ids[kind] = _ids.get(kind, 0) + 1
    return _ids[kind]


def add_concept(cid, name, domain, vocab, cls, standard, code):
    concept.append((cid, name, domain, vocab, cls, standard, code, "1970-01-01", "2099-12-31", None))


# cb_criteria.id lives in a different number space from concept_id (FORMAT.md sec.3).
_crit_id = [0]


def add_criteria(cid, name, domain, ctype, is_standard, parent_path=None, selectable=1):
    """Seed one cb_criteria node. `full_text` MUST carry a [<domain>_rank1] token and
    `path` MUST be a dot-joined chain of cb_criteria.id ending in this node's own id,
    or the notebook's hierarchy-walk subquery returns zero rows *with no error*."""
    _crit_id[0] += 1
    i = _crit_id[0]
    path = f"{parent_path}.{i}" if parent_path else str(i)
    full_text = f"{name}|[{domain.lower()}_rank1]"
    cb_criteria.append((i, 0, domain.upper(), is_standard, ctype, None, cid, str(cid), name,
                        None, 100, 0, selectable, 0, 1, 0, path, None, 0, 0, full_text, None))
    return path


def seed_vocabulary():
    # --- condition / procedure source concepts (is_standard = 0) -----------
    for c in CAD_ICD:
        add_concept(c, f"Ischemic heart disease {c}", "Condition", "ICD10CM", "4-char billing code", None, f"I2{c % 10}.{c % 9}")
        add_criteria(c, f"Ischemic heart disease {c}", "CONDITION", "ICD10CM", 0)
    for c in CAD_CPT:
        add_concept(c, f"Coronary procedure {c}", "Procedure", "CPT4", "CPT4", None, str(92900 + c % 90))
        add_criteria(c, f"Coronary procedure {c}", "PROCEDURE", "CPT4", 0)
    for c in FH_COND:
        add_concept(c, "Familial hypercholesterolemia", "Condition", "ICD10CM", "4-char billing code", None, "E78.01")
        add_criteria(c, "Familial hypercholesterolemia", "CONDITION", "ICD10CM", 0)
    for c in HC:
        if not any(x[0] == c for x in concept):
            add_concept(c, "Pure hypercholesterolemia", "Condition", "ICD10CM", "4-char billing code", None, "E78.00")
            add_criteria(c, "Pure hypercholesterolemia", "CONDITION", "ICD10CM", 0)

    # --- PAD: filtered on condition_concept_id, so is_standard = 1 ---------
    for c in PAD:
        add_concept(c, "Peripheral arterial disease", "Condition", "SNOMED", "Clinical Finding", "S", str(c))
        add_criteria(c, "Peripheral arterial disease", "CONDITION", "SNOMED", 1)

    # --- observation concepts (filtered directly, no cb_criteria needed) ---
    for c in FH_OBS:
        add_concept(c, "Family history of familial hypercholesterolemia", "Observation", "SNOMED", "Clinical Finding", "S", str(c))
    for c in CADFH_OBS:
        add_concept(c, "Family history of clinical finding", "Observation", "SNOMED", "Clinical Finding", "S", str(c))

    # --- standard concepts referenced by the LEFT JOINs -------------------
    add_concept(CAD_STD, "Myocardial infarction", "Condition", "SNOMED", "Clinical Finding", "S", "22298006")
    add_concept(PAD_STD, "Peripheral vascular disease", "Condition", "SNOMED", "Clinical Finding", "S", "400047006")
    add_concept(HC_STD, "Hypercholesterolemia", "Condition", "SNOMED", "Clinical Finding", "S", "13644009")
    add_concept(FH_STD, "Familial hypercholesterolemia", "Condition", "SNOMED", "Clinical Finding", "S", "398036000")
    add_concept(CPT_STD, "Percutaneous coronary intervention", "Procedure", "SNOMED", "Procedure", "S", "415070008")

    # --- measurements: lipid group with its leaves -------------------------
    add_concept(LIPID_GROUP, "Lipid panel", "Measurement", "LOINC", "LOINC Group", "S", "24331-1")
    grp = add_criteria(LIPID_GROUP, "Lipid panel", "MEASUREMENT", "LOINC", 1)
    for cid, nm, code in [
        (TRIG, "Triglyceride [Mass/volume] in Serum or Plasma", "2571-8"),
        (LDL, "Cholesterol in LDL [Mass/volume] in Serum or Plasma", "13457-7"),
        (CHOL_EXCLUDED, "Cholesterol [Mass/volume] in Serum or Plasma", "2093-3"),
        (STRAY, "Cholesterol in HDL [Mass/volume] in Serum or Plasma", "2085-9"),
    ]:
        add_concept(cid, nm, "Measurement", "LOINC", "Lab Test", "S", code)
        add_criteria(cid, nm, "MEASUREMENT", "LOINC", 1, parent_path=grp)

    add_concept(BMI_C, "Body mass index (BMI) [Ratio]", "Measurement", "LOINC", "Lab Test", "S", "39156-5")
    add_criteria(BMI_C, "Body mass index (BMI) [Ratio]", "MEASUREMENT", "LOINC", 1)

    # --- drugs: cb_criteria (is_standard=1) -> cb_criteria_ancestor --------
    for c in STATIN + NONSTATIN:
        kind = "statin" if c in STATIN else "non-statin"
        add_concept(c, f"Lipid-lowering ingredient {c} ({kind})", "Drug", "RxNorm", "Ingredient", "S", str(c))
        add_criteria(c, f"Lipid-lowering ingredient {c} ({kind})", "DRUG", "RXNORM", 1)
        # Each ingredient is its own descendant, plus one clinical drug beneath it.
        clinical = 40000000 + c % 1000000
        add_concept(clinical, f"Clinical drug for ingredient {c}", "Drug", "RxNorm", "Clinical Drug", "S", str(clinical))
        cb_anc.append((c, c))
        cb_anc.append((c, clinical))

    # --- supporting concepts ----------------------------------------------
    add_concept(UNIT_MGDL, "milligram per deciliter", "Unit", "UCUM", "Unit", "S", "mg/dL")
    add_concept(UNIT_KGM2, "kilogram per square meter", "Unit", "UCUM", "Unit", "S", "kg/m2")
    for vc, nm in [(VISIT_IP, "Inpatient Visit"), (VISIT_OP, "Outpatient Visit"),
                   (VISIT_ER, "Emergency Room Visit"), (VISIT_OFFICE, "Office Visit")]:
        add_concept(vc, nm, "Visit", "Visit", "Visit", "S", str(vc))
    add_concept(TYPE_EHR, "EHR", "Type Concept", "Type Concept", "Type Concept", "S", "EHR")
    add_concept(TYPE_SURVEY, "Observation recorded from a Survey", "Type Concept", "Type Concept", "Type Concept", "S", "SURVEY")
    add_concept(OP_LT, "<", "Meas Value Operator", "Concept Class", "Qualifier Value", "S", "<")
    for cid, nm in RACES.items():
        if not any(x[0] == cid for x in concept):
            add_concept(cid, nm, "Race", "Race", "Race", "S", str(cid))
    for cid, nm in SEXES.items():
        if not any(x[0] == cid for x in concept):
            add_concept(cid, nm, "Gender", "Gender", "Gender", "S", str(cid))
    add_concept(43528793, SURVEY_TEXT, "Observation", "PPI", "Question", "S", "cholesterol_med")


# --------------------------------------------------------------------------
# Row builders
# --------------------------------------------------------------------------
def add_person(pid, dob="1960-06-15", race=8527, sex=8507, wgs=1, ehr=1):
    person.append((pid, sex, int(dob[:4]), 6, 15, f"{dob} 00:00:00", race, 0, None, None, None,
                   f"P{pid}", None, 0, RACES.get(race), race, None, 0, sex, sex, None))
    cb_person.append((pid, RACES.get(race), SEXES.get(sex), RACES.get(race), "Not Hispanic or Latino",
                      dob, 45, 62, ehr, 1, 1, 0, wgs, 1, 0, 0, "OH"))


def add_visit(pid, d, vc=VISIT_OP):
    visit.append((nid("v"), pid, vc, d, f"{d} 00:00:00", d, f"{d} 00:00:00", TYPE_EHR,
                  None, None, str(vc), 0, 0, None, 0, None, None))


def add_visits(pid, dates):
    for d in dates:
        add_visit(pid, d)


def add_cond(pid, d, src, std, src_val, stop=None):
    cond.append((nid("c"), pid, std, d, f"{d} 00:00:00", d, f"{d} 00:00:00", TYPE_EHR, 0,
                 stop, None, None, None, src_val, src, None))


def add_proc(pid, d, src, std, src_val):
    proc.append((nid("p"), pid, std, d, f"{d} 00:00:00", TYPE_EHR, 0, 1, None, None, None,
                 src_val, src, None))


def add_meas(pid, d, cid, val, unit="mg/dL", unit_cid=UNIT_MGDL, vsv=None, op=None):
    meas.append((nid("m"), pid, cid, d, f"{d} 00:00:00", None, TYPE_EHR, op, val, None,
                 unit_cid, None, None, None, None, None, str(cid), cid, unit, vsv))


def add_obs(pid, d, cid, src_cid, src_val):
    obs.append((nid("o"), pid, cid, d, f"{d} 00:00:00", TYPE_SURVEY, None, None, None, None,
                None, None, None, None, src_val, src_cid, None, None, None, None, nid("qr")))


def add_drug(pid, d, cid):
    drug.append((nid("d"), pid, cid, d, f"{d} 00:00:00", d, f"{d} 00:00:00", None, TYPE_EHR,
                 None, 0, 30.0, 30, None, None, None, None, None, None, str(cid), cid, None, None))


def add_survey(pid, d, yes):
    survey.append((pid, f"{d} 00:00:00", "Personal Medical History", SURVEY_Q, SURVEY_TEXT,
                   1 if yes else 0, SURVEY_YES if yes else SURVEY_NO, 2100000000, "version 1"))


def expect(pid, scenario, **kw):
    row = {"person_id": pid, "scenario": scenario}
    row.update(kw)
    answers.append(row)


# --------------------------------------------------------------------------
# The 27 hand-authored scenario participants (FORMAT.md sec.8)
# --------------------------------------------------------------------------
FIRST_VISIT, LAST_VISIT = "2010-03-01", "2021-11-20"
STD_VISITS = [FIRST_VISIT, "2015-07-07", LAST_VISIT]
CAD_ICD_1, CAD_CPT_1 = CAD_ICD[0], CAD_CPT[0]


def build_scenarios():
    # P01 clean baseline: ICD CAD, clean LDL, statin
    add_person(1000001); add_visits(1000001, STD_VISITS)
    add_cond(1000001, "2015-04-10", CAD_ICD_1, CAD_STD, "I21.4")
    add_meas(1000001, "2012-05-02", LDL, 130.0); add_meas(1000001, "2012-05-02", TRIG, 150.0)
    add_drug(1000001, "2014-01-01", STATIN[0])
    expect(1000001, "clean baseline", CAD_code=1, CAD_code_date="2015-04-10", LDL=130,
           Date_LDL_assessment="2012-05-02", any_chol_med=1, LDL_measured_on_meds=0,
           censor_type=3, CAD_censored_date=LAST_VISIT)

    # P02 clean, no CAD, no meds -> A7 (LDL_measured_on_meds is NA, not 0)
    add_person(1000002); add_visits(1000002, STD_VISITS)
    add_meas(1000002, "2013-01-09", LDL, 110.0)
    expect(1000002, "no CAD, no meds (A7)", CAD_code=0, CAD_code_date=None, LDL=110,
           Date_LDL_assessment="2013-01-09", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P03 CAD via CPT only
    add_person(1000003); add_visits(1000003, STD_VISITS)
    add_proc(1000003, "2016-08-22", CAD_CPT_1, CPT_STD, "92941")
    add_meas(1000003, "2011-02-11", LDL, 145.0)
    expect(1000003, "CAD via CPT only", CAD_code=1, CAD_code_date="2016-08-22", LDL=145,
           Date_LDL_assessment="2011-02-11", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=3, CAD_censored_date=LAST_VISIT)

    # P04 both ICD and CPT; ICD earlier -> earliest wins
    add_person(1000004); add_visits(1000004, STD_VISITS)
    add_cond(1000004, "2014-03-05", CAD_ICD_1, CAD_STD, "I21.4")
    add_proc(1000004, "2017-01-01", CAD_CPT_1, CPT_STD, "92941")
    add_meas(1000004, "2010-06-01", LDL, 160.0)
    add_drug(1000004, "2013-01-01", STATIN[0])
    expect(1000004, "ICD + CPT, earliest wins", CAD_code=1, CAD_code_date="2014-03-05", LDL=160,
           Date_LDL_assessment="2010-06-01", any_chol_med=1, LDL_measured_on_meds=0,
           censor_type=3, CAD_censored_date=LAST_VISIT)

    # P05 CAD code precedes first visit -> censor type 2
    add_person(1000005); add_visits(1000005, STD_VISITS)
    add_cond(1000005, "2009-05-01", CAD_ICD_1, CAD_STD, "I21.4")
    add_meas(1000005, "2011-04-04", LDL, 120.0)
    expect(1000005, "CAD before first visit (D7)", CAD_code=1, CAD_code_date="2009-05-01", LDL=120,
           Date_LDL_assessment="2011-04-04", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=2, CAD_censored_date="2009-05-01")

    # P06 duplicate same-day LDL. filter(d == min(d)) leaves all three rows; only
    # distinct(person_id, .keep_all=TRUE) cuts it to one -- and it keeps whichever
    # row happens to come FIRST. Row order out of BigQuery is not guaranteed, so
    # *which* duplicate survives is arbitrary. The reproducible property is
    # "exactly one row, and its value is one of the duplicates" -- not a fixed value.
    add_person(1000006); add_visits(1000006, STD_VISITS)
    for v in (130.0, 131.0, 132.0):
        add_meas(1000006, "2012-05-02", LDL, v)
    expect(1000006, "same-day duplicate LDL (D3) -- surviving row is arbitrary",
           CAD_code=0, CAD_code_date=None, LDL="one_of:130|131|132",
           Date_LDL_assessment="2012-05-02", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT, note="exactly 1 row; value not deterministic")

    # P07 LDL only in mmol/L and % -> unit filter removes everything
    add_person(1000007); add_visits(1000007, STD_VISITS)
    add_meas(1000007, "2012-05-02", LDL, 3.4, unit="mmol/L", unit_cid=None)
    add_meas(1000007, "2013-05-02", LDL, 42.0, unit="%", unit_cid=None)
    expect(1000007, "LDL only in mmol/L and % (D1)", CAD_code=0, CAD_code_date=None, LDL="NA",
           Date_LDL_assessment="NA", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P08 outlier dropped BEFORE the earliest-record filter -> later valid row wins
    add_person(1000008); add_visits(1000008, STD_VISITS)
    add_meas(1000008, "2011-01-01", LDL, 9999.0)
    add_meas(1000008, "2013-06-06", LDL, 140.0)
    expect(1000008, "non-physiologic LDL dropped (D2)", CAD_code=0, CAD_code_date=None, LDL=140,
           Date_LDL_assessment="2013-06-06", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P09 LDL == Trig: the diff!=0 filter is applied only to the scratch frame,
    # so the defect SURVIVES into the join.
    add_person(1000009); add_visits(1000009, STD_VISITS)
    add_meas(1000009, "2014-02-02", LDL, 180.0); add_meas(1000009, "2014-02-02", TRIG, 180.0)
    expect(1000009, "LDL == Trig, defect survives (D4)", CAD_code=0, CAD_code_date=None, LDL=180,
           Date_LDL_assessment="2014-02-02", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P10 genomic only: no EHR rows at all, and no survey (so any_chol_med is a
    # true 0 rather than tripping the sec.7.3 bug).
    add_person(1000010, ehr=0)
    expect(1000010, "genomic only, zero EHR (D5)", CAD_code=0, CAD_code_date=None, LDL="NA",
           Date_LDL_assessment="NA", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date="NA")

    # P11 / P12 non-response demographics
    add_person(1000011, race=903096, sex=1177221); add_visits(1000011, STD_VISITS)
    add_meas(1000011, "2014-07-07", LDL, 115.0)
    expect(1000011, "race PMI: Skip (D6)", CAD_code=0, CAD_code_date=None, LDL=115,
           Date_LDL_assessment="2014-07-07", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT, race="PMI: Skip")

    add_person(1000012, race=0, sex=0); add_visits(1000012, STD_VISITS)
    add_meas(1000012, "2013-03-03", LDL, 125.0)
    expect(1000012, "race None Indicated (D6)", CAD_code=0, CAD_code_date=None, LDL=125,
           Date_LDL_assessment="2013-03-03", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=1, CAD_censored_date=LAST_VISIT, race="None Indicated")

    # P13 non-statin only; LDL drawn on the med start date -> boundary is <=, so 0
    add_person(1000013); add_visits(1000013, STD_VISITS)
    add_drug(1000013, "2016-01-01", NONSTATIN[0])
    add_meas(1000013, "2016-01-01", LDL, 150.0)
    expect(1000013, "non-statin only", CAD_code=0, CAD_code_date=None, LDL=150,
           Date_LDL_assessment="2016-01-01", any_chol_med=1,
           any_chol_med_start_date="2016-01-01", LDL_measured_on_meds=0,
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P14 THE BUG (FORMAT.md sec.7.3): answered the survey "No", takes nothing.
    # Correct answer is 0; the pipeline collapses non-NA -> 1.
    add_person(1000014); add_visits(1000014, STD_VISITS)
    add_survey(1000014, "2018-01-01", yes=False)
    add_meas(1000014, "2018-02-02", LDL, 105.0)
    expect(1000014, "survey 'No', no drugs -- EXPECT 0, PIPELINE YIELDS 1 (sec.7.3)",
           CAD_code=0, CAD_code_date=None, LDL=105, Date_LDL_assessment="2018-02-02",
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1,
           CAD_censored_date=LAST_VISIT)

    # P15 survey "Yes", no prescriptions
    add_person(1000015); add_visits(1000015, STD_VISITS)
    add_survey(1000015, "2019-01-01", yes=True)
    add_meas(1000015, "2019-05-05", LDL, 190.0)
    expect(1000015, "survey 'Yes', no drugs", CAD_code=0, CAD_code_date=None, LDL=190,
           Date_LDL_assessment="2019-05-05", any_chol_med=1,
           any_chol_med_start_date="2019-01-01", LDL_measured_on_meds=1,
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P16 statin BEFORE the LDL draw -> measured on meds
    add_person(1000016); add_visits(1000016, STD_VISITS)
    add_drug(1000016, "2015-01-01", STATIN[1])
    add_meas(1000016, "2017-06-06", LDL, 95.0)
    expect(1000016, "statin before LDL draw", CAD_code=0, CAD_code_date=None, LDL=95,
           Date_LDL_assessment="2017-06-06", any_chol_med=1,
           any_chol_med_start_date="2015-01-01", LDL_measured_on_meds=1,
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P17 LDL drawn BEFORE any medication -> not on meds
    add_person(1000017); add_visits(1000017, STD_VISITS)
    add_drug(1000017, "2016-01-01", STATIN[1])
    add_meas(1000017, "2012-01-01", LDL, 175.0)
    expect(1000017, "LDL before meds", CAD_code=0, CAD_code_date=None, LDL=175,
           Date_LDL_assessment="2012-01-01", any_chol_med=1,
           any_chol_med_start_date="2016-01-01", LDL_measured_on_meds=0,
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P18 every comorbidity flag at once
    add_person(1000018); add_visits(1000018, STD_VISITS)
    add_cond(1000018, "2013-01-01", PAD[0], PAD[0], "I73.9")
    add_cond(1000018, "2013-02-01", FH_COND[0], FH_STD, "E78.01")
    add_cond(1000018, "2013-03-01", HC[0], HC_STD, "E78.00")
    add_obs(1000018, "2013-04-01", FH_OBS[0], FH_OBS[0], "FamilyHistory_FH")
    add_obs(1000018, "2013-05-01", CADFH_OBS[0], CADFH_OBS[0], "FamilyHistory_FamilyHeartAttack")
    add_meas(1000018, "2015-09-09", LDL, 200.0)
    expect(1000018, "PAD + FH + CADFH + HC", CAD_code=0, CAD_code_date=None, LDL=200,
           Date_LDL_assessment="2015-09-09", any_chol_med=0, LDL_measured_on_meds="NA",
           PAD_code=1, FH_code=1, CADFH_code="TRUE", HC_code=1,
           censor_type=1, CAD_censored_date=LAST_VISIT)

    # P19 BMI: one wrong-unit row and one outlier -> nothing survives
    add_person(1000019); add_visits(1000019, STD_VISITS)
    add_meas(1000019, "2014-01-01", BMI_C, 28.0, unit="kg/m^2", unit_cid=UNIT_KGM2)
    add_meas(1000019, "2015-01-01", BMI_C, 900.0, unit="kg/m2", unit_cid=UNIT_KGM2)
    add_meas(1000019, "2014-01-01", LDL, 120.0)
    expect(1000019, "BMI wrong unit + outlier (D1,D2)", CAD_code=0, CAD_code_date=None, LDL=120,
           Date_LDL_assessment="2014-01-01", BMI="NA", any_chol_med=0,
           LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT)

    # P20 NOT in the cohort: has_whole_genome_variant = 0. Must never appear.
    add_person(1000020, wgs=0); add_visits(1000020, STD_VISITS)
    add_cond(1000020, "2015-04-10", CAD_ICD_1, CAD_STD, "I21.4")
    add_meas(1000020, "2012-05-02", LDL, 130.0)
    add_drug(1000020, "2014-01-01", STATIN[0])
    expect(1000020, "has_whole_genome_variant=0 -- MUST BE ABSENT", CAD_code="absent",
           LDL="absent", any_chol_med="absent", censor_type="absent", CAD_censored_date="absent")

    # P21 A1: lowercase 'mg/dl' silently drops the person's only LDL
    add_person(1000021); add_visits(1000021, STD_VISITS)
    add_meas(1000021, "2013-08-08", LDL, 135.0, unit="mg/dl")
    expect(1000021, "lowercase mg/dl unit (A1) -- LDL silently lost, ideally 135",
           CAD_code=0, CAD_code_date=None, LDL="NA", Date_LDL_assessment="NA",
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT)

    # P22 A2: censored lab value -- value_as_number NULL, value_source_value populated
    add_person(1000022); add_visits(1000022, STD_VISITS)
    add_meas(1000022, "2013-09-09", LDL, None, vsv="<10", op=OP_LT)
    expect(1000022, "NULL value_as_number, value_source_value '<10' (A2) -- silently dropped",
           CAD_code=0, CAD_code_date=None, LDL="NA", Date_LDL_assessment="NA",
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT)

    # P23 A3: DOB after the CAD event -> negative age
    add_person(1000023, dob="2019-01-01"); add_visits(1000023, STD_VISITS)
    add_cond(1000023, "2015-04-10", CAD_ICD_1, CAD_STD, "I21.4")
    add_meas(1000023, "2012-05-02", LDL, 130.0)
    expect(1000023, "DOB after events (A3) -- negative ages", CAD_code=1,
           CAD_code_date="2015-04-10", LDL=130, Date_LDL_assessment="2012-05-02",
           any_chol_med=0, CAD_age=-4, Age_at_LDL_assessment=-7, LDL_measured_on_meds="NA",
           censor_type=3, CAD_censored_date=LAST_VISIT)

    # P24 A6: in cohort, has a CAD code, but zero visits -> max(visit_start) over empty set
    add_person(1000024)
    add_cond(1000024, "2015-04-10", CAD_ICD_1, CAD_STD, "I21.4")
    add_meas(1000024, "2012-05-02", LDL, 130.0)
    expect(1000024, "CAD code but zero visits (A6) -- censoring breaks", CAD_code=1,
           CAD_code_date="2015-04-10", LDL=130, Date_LDL_assessment="2012-05-02",
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type="breaks",
           CAD_censored_date="NA/-Inf")

    # P25 A9: a stray lipid analyte that is neither 3022192 nor 3008631 becomes "LDL"
    add_person(1000025); add_visits(1000025, STD_VISITS)
    add_meas(1000025, "2016-03-03", STRAY, 55.0)          # HDL -- misread as LDL
    add_meas(1000025, "2016-03-03", CHOL_EXCLUDED, 210.0)  # correctly excluded
    expect(1000025, "stray analyte becomes LDL (A9)", CAD_code=0, CAD_code_date=None,
           LDL=55, Date_LDL_assessment="2016-03-03", any_chol_med=0,
           LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT)

    # P26 A4: duplicate person row -> row multiplication across the whole join
    add_person(1000026, race=8527)
    add_person(1000026, race=8515)  # same person_id, different race
    add_visits(1000026, STD_VISITS)
    add_meas(1000026, "2015-05-05", LDL, 140.0)
    expect(1000026, "duplicate person row (A4) -- pheno_df gains a duplicate row",
           CAD_code=0, CAD_code_date=None, LDL=140, Date_LDL_assessment="2015-05-05",
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1,
           CAD_censored_date=LAST_VISIT, note="expect 2 rows, not 1")

    # P27 A8: stop_reason is empty for every other condition row, populated only here.
    # Placed last so it lands in the final shard -> per-shard type inference differs.
    add_person(1000027); add_visits(1000027, STD_VISITS)
    add_cond(1000027, "2016-06-06", CAD_ICD_1, CAD_STD, "I21.4", stop="resolved")
    add_meas(1000027, "2016-06-06", LDL, 128.0)
    expect(1000027, "stop_reason only in last shard (A8) -- cross-shard type inference",
           CAD_code=1, CAD_code_date="2016-06-06", LDL=128,
           Date_LDL_assessment="2016-06-06", any_chol_med=0, LDL_measured_on_meds="NA",
           censor_type=3, CAD_censored_date=LAST_VISIT)

    # A5: an orphan measurement row with a NULL person_id (belongs to nobody).
    meas.append((nid("m"), None, LDL, "2015-01-01", "2015-01-01 00:00:00", None, TYPE_EHR,
                 None, 133.0, None, UNIT_MGDL, None, None, None, None, None, str(LDL), LDL,
                 "mg/dL", None))


# --------------------------------------------------------------------------
# Randomised filler, so group_by / distinct behaviour is exercised at volume
# --------------------------------------------------------------------------
def build_filler(n_from=1000028, n_to=1000300):
    race_pool = [8527] * 55 + [8516] * 20 + [8515] * 12 + [38003615] * 5 + \
                [903096] * 4 + [1177221] * 2 + [0] * 2
    for pid in range(n_from, n_to + 1):
        wgs = 1 if random.random() < 0.60 else 0
        has_ehr = random.random() < 0.70
        dob = f"{random.randint(1940, 1985)}-06-15"
        add_person(pid, dob=dob, race=random.choice(race_pool),
                   sex=random.choice([8507, 8532]), wgs=wgs, ehr=int(has_ehr))
        if not has_ehr:
            continue

        vstart = random.randint(2008, 2014)
        vdates = sorted(f"{random.randint(vstart, 2021)}-{random.randint(1,12):02d}-{random.randint(1,28):02d}"
                        for _ in range(random.randint(2, 6)))
        add_visits(pid, vdates)

        if random.random() < 0.18:  # CAD
            d = f"{random.randint(2011, 2021)}-{random.randint(1,12):02d}-{random.randint(1,28):02d}"
            if random.random() < 0.5:
                add_cond(pid, d, random.choice(CAD_ICD), CAD_STD, "I21.4")
            else:
                add_proc(pid, d, random.choice(CAD_CPT), CPT_STD, "92941")
        if random.random() < 0.08:
            add_cond(pid, f"{random.randint(2011,2021)}-05-05", PAD[0], PAD[0], "I73.9")
        if random.random() < 0.12:
            add_cond(pid, f"{random.randint(2011,2021)}-06-06", HC[0], HC_STD, "E78.00")
        if random.random() < 0.05:
            add_obs(pid, f"{random.randint(2011,2021)}-07-07", CADFH_OBS[0], CADFH_OBS[0],
                    "FamilyHistory_FamilyHeartAttack")

        # LDL / Trig, with the D1/D2/D3/D4 defects sprinkled in
        ldl_date = f"{random.randint(2010, 2020)}-{random.randint(1,12):02d}-{random.randint(1,28):02d}"
        ldl_val = round(random.gauss(120, 32), 1)
        trig_val = round(random.gauss(150, 60), 1)
        if random.random() < 0.02:      # D4: LDL == Trig
            trig_val = ldl_val
        if random.random() < 0.02:      # D2: non-physiologic
            ldl_val = random.choice([0.0, -1.0, 9999.0])
        unit = random.choice(DIRTY_MGDL)  # D1
        add_meas(pid, ldl_date, LDL, ldl_val, unit=unit)
        add_meas(pid, ldl_date, TRIG, max(trig_val, 5.0), unit=random.choice(DIRTY_MGDL))
        if random.random() < 0.15:      # D3: same-day duplicate
            add_meas(pid, ldl_date, LDL, ldl_val + random.choice([0, 1, 2]), unit=unit)
        if random.random() < 0.06:      # A2: censored value
            add_meas(pid, ldl_date, LDL, None, vsv=random.choice(["<10", ">500", "TNP"]), op=OP_LT)

        if random.random() < 0.8:       # BMI
            add_meas(pid, ldl_date, BMI_C, round(random.gauss(29, 6), 1),
                     unit=random.choice(DIRTY_KGM2), unit_cid=UNIT_KGM2)

        if random.random() < 0.30:
            add_drug(pid, f"{random.randint(2010,2020)}-03-03", random.choice(STATIN))
        if random.random() < 0.10:
            add_drug(pid, f"{random.randint(2010,2020)}-04-04", random.choice(NONSTATIN))
        if random.random() < 0.55:
            add_survey(pid, f"{random.randint(2018,2021)}-01-01", yes=random.random() < 0.3)


# --------------------------------------------------------------------------
# Schema + load
# --------------------------------------------------------------------------
DDL = """
DROP TABLE IF EXISTS concept; CREATE TABLE concept(
  concept_id BIGINT, concept_name VARCHAR, domain_id VARCHAR, vocabulary_id VARCHAR,
  concept_class_id VARCHAR, standard_concept VARCHAR, concept_code VARCHAR,
  valid_start_date DATE, valid_end_date DATE, invalid_reason VARCHAR);

DROP TABLE IF EXISTS cb_criteria; CREATE TABLE cb_criteria(
  id BIGINT, parent_id BIGINT, domain_id VARCHAR, is_standard BIGINT, type VARCHAR,
  subtype VARCHAR, concept_id BIGINT, code VARCHAR, name VARCHAR, value VARCHAR,
  est_count BIGINT, is_group BIGINT, is_selectable BIGINT, has_attribute BIGINT,
  has_hierarchy BIGINT, has_ancestor_data BIGINT, path VARCHAR, synonyms VARCHAR,
  rollup_count BIGINT, item_count BIGINT, full_text VARCHAR, display_synonyms VARCHAR);

DROP TABLE IF EXISTS cb_criteria_ancestor; CREATE TABLE cb_criteria_ancestor(
  ancestor_id BIGINT, descendant_id BIGINT);

DROP TABLE IF EXISTS cb_search_person; CREATE TABLE cb_search_person(
  person_id BIGINT, gender VARCHAR, sex_at_birth VARCHAR, race VARCHAR, ethnicity VARCHAR,
  dob DATE, age_at_consent BIGINT, age_at_cdr BIGINT, has_ehr_data BIGINT,
  has_ppi_survey_data BIGINT, has_physical_measurement_data BIGINT, is_deceased BIGINT,
  has_whole_genome_variant BIGINT, has_array_data BIGINT, has_lr_whole_genome_variant BIGINT,
  has_structural_variant_data BIGINT, state_of_residence VARCHAR);

DROP TABLE IF EXISTS person; CREATE TABLE person(
  person_id BIGINT, gender_concept_id BIGINT, year_of_birth BIGINT, month_of_birth BIGINT,
  day_of_birth BIGINT, birth_datetime TIMESTAMP, race_concept_id BIGINT,
  ethnicity_concept_id BIGINT, location_id BIGINT, provider_id BIGINT, care_site_id BIGINT,
  person_source_value VARCHAR, gender_source_value VARCHAR, gender_source_concept_id BIGINT,
  race_source_value VARCHAR, race_source_concept_id BIGINT, ethnicity_source_value VARCHAR,
  ethnicity_source_concept_id BIGINT, sex_at_birth_concept_id BIGINT,
  sex_at_birth_source_concept_id BIGINT, sex_at_birth_source_value VARCHAR);

DROP TABLE IF EXISTS visit_occurrence; CREATE TABLE visit_occurrence(
  visit_occurrence_id BIGINT, person_id BIGINT, visit_concept_id BIGINT, visit_start_date DATE,
  visit_start_datetime TIMESTAMP, visit_end_date DATE, visit_end_datetime TIMESTAMP,
  visit_type_concept_id BIGINT, provider_id BIGINT, care_site_id BIGINT,
  visit_source_value VARCHAR, visit_source_concept_id BIGINT, admitting_source_concept_id BIGINT,
  admitting_source_value VARCHAR, discharge_to_concept_id BIGINT,
  discharge_to_source_value VARCHAR, preceding_visit_occurrence_id BIGINT);

DROP TABLE IF EXISTS condition_occurrence; CREATE TABLE condition_occurrence(
  condition_occurrence_id BIGINT, person_id BIGINT, condition_concept_id BIGINT,
  condition_start_date DATE, condition_start_datetime TIMESTAMP, condition_end_date DATE,
  condition_end_datetime TIMESTAMP, condition_type_concept_id BIGINT,
  condition_status_concept_id BIGINT, stop_reason VARCHAR, provider_id BIGINT,
  visit_occurrence_id BIGINT, visit_detail_id BIGINT, condition_source_value VARCHAR,
  condition_source_concept_id BIGINT, condition_status_source_value VARCHAR);

DROP TABLE IF EXISTS procedure_occurrence; CREATE TABLE procedure_occurrence(
  procedure_occurrence_id BIGINT, person_id BIGINT, procedure_concept_id BIGINT,
  procedure_date DATE, procedure_datetime TIMESTAMP, procedure_type_concept_id BIGINT,
  modifier_concept_id BIGINT, quantity BIGINT, provider_id BIGINT, visit_occurrence_id BIGINT,
  visit_detail_id BIGINT, procedure_source_value VARCHAR, procedure_source_concept_id BIGINT,
  modifier_source_value VARCHAR);

DROP TABLE IF EXISTS measurement; CREATE TABLE measurement(
  measurement_id BIGINT, person_id BIGINT, measurement_concept_id BIGINT,
  measurement_date DATE, measurement_datetime TIMESTAMP, measurement_time VARCHAR,
  measurement_type_concept_id BIGINT, operator_concept_id BIGINT, value_as_number DOUBLE,
  value_as_concept_id BIGINT, unit_concept_id BIGINT, range_low DOUBLE, range_high DOUBLE,
  provider_id BIGINT, visit_occurrence_id BIGINT, visit_detail_id BIGINT,
  measurement_source_value VARCHAR, measurement_source_concept_id BIGINT,
  unit_source_value VARCHAR, value_source_value VARCHAR);

DROP TABLE IF EXISTS observation; CREATE TABLE observation(
  observation_id BIGINT, person_id BIGINT, observation_concept_id BIGINT, observation_date DATE,
  observation_datetime TIMESTAMP, observation_type_concept_id BIGINT, value_as_number DOUBLE,
  value_as_string VARCHAR, value_as_concept_id BIGINT, qualifier_concept_id BIGINT,
  unit_concept_id BIGINT, provider_id BIGINT, visit_occurrence_id BIGINT,
  visit_detail_id BIGINT, observation_source_value VARCHAR,
  observation_source_concept_id BIGINT, unit_source_value VARCHAR,
  qualifier_source_value VARCHAR, value_source_concept_id BIGINT, value_source_value VARCHAR,
  questionnaire_response_id BIGINT);

DROP TABLE IF EXISTS drug_exposure; CREATE TABLE drug_exposure(
  drug_exposure_id BIGINT, person_id BIGINT, drug_concept_id BIGINT,
  drug_exposure_start_date DATE, drug_exposure_start_datetime TIMESTAMP,
  drug_exposure_end_date DATE, drug_exposure_end_datetime TIMESTAMP, verbatim_end_date DATE,
  drug_type_concept_id BIGINT, stop_reason VARCHAR, refills BIGINT, quantity DOUBLE,
  days_supply BIGINT, sig VARCHAR, route_concept_id BIGINT, lot_number VARCHAR,
  provider_id BIGINT, visit_occurrence_id BIGINT, visit_detail_id BIGINT,
  drug_source_value VARCHAR, drug_source_concept_id BIGINT, route_source_value VARCHAR,
  dose_unit_source_value VARCHAR);

DROP TABLE IF EXISTS ds_survey; CREATE TABLE ds_survey(
  person_id BIGINT, survey_datetime TIMESTAMP, survey VARCHAR, question_concept_id BIGINT,
  question VARCHAR, answer_concept_id BIGINT, answer VARCHAR,
  survey_version_concept_id BIGINT, survey_version_name VARCHAR);

-- Empty stubs, for schema completeness (FORMAT.md sec.3).
DROP TABLE IF EXISTS observation_period; CREATE TABLE observation_period(
  observation_period_id BIGINT, person_id BIGINT, observation_period_start_date DATE,
  observation_period_end_date DATE, period_type_concept_id BIGINT);
DROP TABLE IF EXISTS death; CREATE TABLE death(
  person_id BIGINT, death_date DATE, death_datetime TIMESTAMP, death_type_concept_id BIGINT,
  cause_concept_id BIGINT, cause_source_value VARCHAR, cause_source_concept_id BIGINT);
DROP TABLE IF EXISTS concept_ancestor; CREATE TABLE concept_ancestor(
  ancestor_concept_id BIGINT, descendant_concept_id BIGINT,
  min_levels_of_separation BIGINT, max_levels_of_separation BIGINT);
DROP TABLE IF EXISTS concept_relationship; CREATE TABLE concept_relationship(
  concept_id_1 BIGINT, concept_id_2 BIGINT, relationship_id VARCHAR,
  valid_start_date DATE, valid_end_date DATE, invalid_reason VARCHAR);
DROP TABLE IF EXISTS cb_search_all_events; CREATE TABLE cb_search_all_events(
  person_id BIGINT, entry_date DATE, entry_datetime TIMESTAMP, is_standard BIGINT,
  concept_id BIGINT, domain VARCHAR, age_at_event BIGINT, visit_concept_id BIGINT,
  visit_occurrence_id BIGINT, value_as_number DOUBLE, value_as_concept_id BIGINT,
  value_source_concept_id BIGINT, systolic DOUBLE, diastolic DOUBLE,
  survey_version_concept_id BIGINT, survey_concept_id BIGINT, cati_concept_id BIGINT);
DROP TABLE IF EXISTS person_ext; CREATE TABLE person_ext(
  person_id BIGINT, src_id VARCHAR, state_of_residence_concept_id BIGINT,
  state_of_residence_source_value VARCHAR, sex_at_birth_concept_id BIGINT,
  sex_at_birth_source_concept_id BIGINT, sex_at_birth_source_value VARCHAR);
"""

TABLES = {
    "concept": concept, "cb_criteria": cb_criteria, "cb_criteria_ancestor": cb_anc,
    "cb_search_person": cb_person, "person": person, "visit_occurrence": visit,
    "condition_occurrence": cond, "procedure_occurrence": proc, "measurement": meas,
    "observation": obs, "drug_exposure": drug, "ds_survey": survey,
}


def main():
    seed_vocabulary()
    build_scenarios()
    build_filler()

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = duckdb.connect(str(DB_PATH))
    con.execute(DDL)
    for name, rows in TABLES.items():
        if not rows:
            continue
        placeholders = ",".join("?" * len(rows[0]))
        con.executemany(f"INSERT INTO {name} VALUES ({placeholders})", rows)

    print(f"{'table':<24} rows")
    print("-" * 32)
    for name in TABLES:
        n = con.execute(f"SELECT count(*) FROM {name}").fetchone()[0]
        print(f"{name:<24} {n:>6}")
    cohort = con.execute(
        "SELECT count(*) FROM cb_search_person WHERE has_whole_genome_variant = 1").fetchone()[0]
    print(f"\nsrWGS cohort (has_whole_genome_variant=1): {cohort}")
    con.close()

    # Answer key
    cols = ["person_id", "scenario", "CAD_code", "CAD_code_date", "LDL", "Date_LDL_assessment",
            "BMI", "any_chol_med", "any_chol_med_start_date", "LDL_measured_on_meds",
            "PAD_code", "FH_code", "CADFH_code", "HC_code", "CAD_age", "Age_at_LDL_assessment",
            "race", "censor_type", "CAD_censored_date", "note"]
    out = FIX / "expected" / "answer_key.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for row in answers:
            w.writerow(row)
    print(f"answer key: {out.relative_to(ROOT)} ({len(answers)} scenarios)")


if __name__ == "__main__":
    main()
