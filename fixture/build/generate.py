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

# --------------------------------------------------------------------------
# PREVENT panel domains (T-004). Codes come from configs/prevent_concepts.yaml.
# Three PREVENT measurement inputs already exist above and resolve today:
# total cholesterol (2093-3 = CHOL_EXCLUDED), HDL-C (2085-9 = STRAY), BMI (39156-5 =
# BMI_C). These are the ones T-004 adds.
#
# CRUCIAL: the four measurement concepts below are seeded as STANDALONE cb_criteria
# nodes (parent_path=None), exactly like BMI -- NOT under the lipid group. The
# notebook's labs export walks only the lipid-group hierarchy (37026687 / 3022192), so
# these never enter its negatively-defined LDL frame and cannot pollute the LDLR
# pipeline. (HDL and TC still do, via the pre-existing A9 path -- that is why the
# PREVENT participants' LDL column below is their HDL value.)
SBP    = 3004249   # LOINC 8480-6  systolic blood pressure                 (unit mmHg)
CREAT  = 3016723   # LOINC 2160-0  creatinine [Mass/volume] in serum       (unit mg/dL)
HBA1C1 = 3004410   # LOINC 4548-4  hemoglobin A1c                          (unit %)
HBA1C2 = 3007263   # LOINC 17856-6 hemoglobin A1c by IFCC protocol         (unit %)

UNIT_MMHG, UNIT_PERCENT = 8876, 8554

# Diabetes by DIAGNOSIS code. ICD10CM lives on condition_source_concept_id (the linkage
# trap, sec.C of 01_prevent_concept_discovery.sql); SNOMED sits on condition_concept_id.
DM_ICD_T2, DM_ICD_T1 = 45591001, 45591002   # source concepts, is_standard = 0
DM_STD = 201826                              # SNOMED "Type 2 diabetes mellitus"

# Antihypertensive ingredients. ILLUSTRATIVE fixture data only: the authoritative
# ingredient list is DELIBERATELY not hardcoded (prevent_concepts.yaml: NEEDS_A_CODE_LIST,
# "do NOT improvise this list from memory"). This is just enough for a future extractor
# to find rows -- it is not a clinical definition and must not be treated as one.
ANTIHTN = [1308216, 974166]   # lisinopril, hydrochlorothiazide (RxNorm ingredients)

# Current smoking is SURVEY-derived in All of Us (prevent_concepts.yaml: NEEDS_MAPPING).
# Seeded in ds_survey under its own question_concept_id so it does NOT leak into the
# cholesterol-med survey export (that query filters question_concept_id = 43528793).
SMOKING_Q = 1585857

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

    # --- PREVENT panel domains (T-004) ------------------------------------
    # Standalone measurement concepts (parent_path=None), like BMI: seeded so the
    # discovery query resolves them and the completeness query counts them, but kept
    # OUT of the lipid-group hierarchy so the notebook's LDL export never sees them.
    for cid, code, nm in [
        (SBP,    "8480-6",  "Systolic blood pressure"),
        (CREAT,  "2160-0",  "Creatinine [Mass/volume] in Serum or Plasma"),
        (HBA1C1, "4548-4",  "Hemoglobin A1c/Hemoglobin.total in Blood"),
        (HBA1C2, "17856-6", "Hemoglobin A1c/Hemoglobin.total in Blood by IFCC protocol"),
    ]:
        add_concept(cid, nm, "Measurement", "LOINC", "Lab Test", "S", code)
        add_criteria(cid, nm, "MEASUREMENT", "LOINC", 1)

    # Diabetes: ICD10CM on the SOURCE concept, one SNOMED standard concept.
    add_concept(DM_STD, "Type 2 diabetes mellitus", "Condition", "SNOMED", "Clinical Finding", "S", "44054006")
    for cid, code, nm in [
        (DM_ICD_T2, "E11.9", "Type 2 diabetes mellitus without complications"),
        (DM_ICD_T1, "E10.9", "Type 1 diabetes mellitus without complications"),
    ]:
        add_concept(cid, nm, "Condition", "ICD10CM", "4-char billing code", None, code)
        add_criteria(cid, nm, "CONDITION", "ICD10CM", 0)

    # Antihypertensives (ILLUSTRATIVE -- see constants). Mirrors the statin pattern:
    # ingredient -> cb_criteria(is_standard=1) -> cb_criteria_ancestor -> clinical drug.
    for c in ANTIHTN:
        add_concept(c, f"Antihypertensive ingredient {c}", "Drug", "RxNorm", "Ingredient", "S", str(c))
        add_criteria(c, f"Antihypertensive ingredient {c}", "DRUG", "RXNORM", 1)
        clinical = 40000000 + c % 1000000
        add_concept(clinical, f"Clinical drug for ingredient {c}", "Drug", "RxNorm", "Clinical Drug", "S", str(clinical))
        cb_anc.append((c, c))
        cb_anc.append((c, clinical))

    # Smoking survey question.
    add_concept(SMOKING_Q, "Smoking status", "Observation", "PPI", "Question", "S", "smoking_status")

    # Supporting units for the new measurements.
    add_concept(UNIT_MMHG, "millimeter mercury column", "Unit", "UCUM", "Unit", "S", "mmHg")
    add_concept(UNIT_PERCENT, "percent", "Unit", "UCUM", "Unit", "S", "%")


# --------------------------------------------------------------------------
# Row builders
# --------------------------------------------------------------------------
CDR_REF_YEAR = 2022  # the fixture's stand-in CDR cutoff year; age_at_cdr is measured against it


def add_person(pid, dob="1960-06-15", race=8527, sex=8507, wgs=1, ehr=1):
    # age_at_cdr mirrors the real CDR column: the participant's age at the CDR cutoff, derived per
    # person from dob (NOT a constant), so sql/02's age_at_cdr 30-79 gate is exercised offline.
    age_at_cdr = CDR_REF_YEAR - int(dob[:4])
    person.append((pid, sex, int(dob[:4]), 6, 15, f"{dob} 00:00:00", race, 0, None, None, None,
                   f"P{pid}", None, 0, RACES.get(race), race, None, 0, sex, sex, None))
    cb_person.append((pid, RACES.get(race), SEXES.get(sex), RACES.get(race), "Not Hispanic or Latino",
                      dob, max(age_at_cdr - 3, 0), age_at_cdr, ehr, 1, 1, 0, wgs, 1, 0, 0, "OH"))


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


def add_smoking(pid, d, status):
    """A smoking-status survey answer. Its question_concept_id (SMOKING_Q) differs from
    the cholesterol-med question, so it is invisible to the notebook's survey export and
    only a PREVENT extractor (T-003) will read it."""
    survey.append((pid, f"{d} 00:00:00", "Lifestyle", SMOKING_Q, "Smoking status",
                   0, status, 2100000000, "version 1"))


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
# The PREVENT panel scenario participants (T-004).
#
# These exercise the domains the LDLR notebook never touched -- systolic BP, serum
# creatinine, HbA1c/diabetes, smoking and antihypertensive use -- and they are what
# lets 02_prevent_panel_completeness.sql finally count a complete panel offline.
#
# Read-me before editing the LDL/BMI columns: the LDLR pipeline is untouched and still
# defines LDL negatively, so each person's HDL row (LOINC 2085-9, mg/dL) is misread as
# their LDL (defect A9). That is why LDL below equals the HDL value. Total cholesterol
# (2093-3) is excluded; SBP / creatinine / HbA1c are standalone concepts the LDL export
# never sees. The has_* / complete_prevent_panel columns are the NEW answer-key columns
# and are validated by tests/testthat/test-prevent-panel-sql.R, not by verify.py.
# --------------------------------------------------------------------------
PREVENT_DATE = "2019-03-03"


def build_prevent_scenarios():
    PD = PREVENT_DATE

    # P28 complete panel, all clean -> INCLUDED by D-013. Also carries a diabetes
    # diagnosis code, a smoking answer and an antihypertensive, so every PREVENT domain
    # has at least one clean, fully-wired example on a single person.
    add_person(1000028, dob="1965-06-15"); add_visits(1000028, STD_VISITS)
    add_meas(1000028, PD, CHOL_EXCLUDED, 190.0)                          # total cholesterol
    add_meas(1000028, PD, STRAY, 52.0)                                  # HDL  -> LDL=52 (A9)
    add_meas(1000028, PD, SBP, 128.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000028, PD, CREAT, 0.9)                                   # mg/dL (<=1, so not even LDL-eligible)
    add_meas(1000028, PD, BMI_C, 27.5, unit="kg/m2", unit_cid=UNIT_KGM2)
    add_cond(1000028, "2018-01-01", DM_ICD_T2, DM_STD, "E11.9")
    add_drug(1000028, "2017-01-01", ANTIHTN[0])
    add_smoking(1000028, "2020-01-01", "Current Every Day")
    expect(1000028, "complete PREVENT panel, clean -- INCLUDED (D-013)",
           CAD_code=0, CAD_code_date=None, LDL=52, Date_LDL_assessment=PD, BMI=27.5,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=1,
           has_bmi=1, has_diabetes_dx=1, has_hba1c=0, has_smoking=1, has_antihypertensive=1,
           complete_prevent_panel=1)

    # P29 missing serum creatinine -> INCOMPLETE, EXCLUDED by D-013. The eligibility
    # rule needs a test as much as the cleaning does: this person has four of five inputs.
    add_person(1000029, dob="1970-06-15"); add_visits(1000029, STD_VISITS)
    add_meas(1000029, PD, CHOL_EXCLUDED, 205.0)
    add_meas(1000029, PD, STRAY, 48.0)                                  # -> LDL=48
    add_meas(1000029, PD, SBP, 134.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000029, PD, BMI_C, 31.2, unit="kg/m2", unit_cid=UNIT_KGM2)
    expect(1000029, "incomplete panel: no serum creatinine -- EXCLUDED (D-013)",
           CAD_code=0, CAD_code_date=None, LDL=48, Date_LDL_assessment=PD, BMI=31.2,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=0,
           has_bmi=1, has_diabetes_dx=0, complete_prevent_panel=0)

    # P30 complete panel, but SBP is DIRTY: an out-of-range 900, a wrong-unit-string row,
    # and a same-day duplicate, alongside a valid reading. has_systolic_bp=1 and the panel
    # is complete (the count query does not bound values) -- but a T-003 extractor that
    # fails to bound systolic BP will pick the 900. Coverage: SBP dirty-record class.
    add_person(1000030, dob="1958-06-15"); add_visits(1000030, STD_VISITS)
    add_meas(1000030, PD, CHOL_EXCLUDED, 175.0)
    add_meas(1000030, PD, STRAY, 60.0)                                  # -> LDL=60
    add_meas(1000030, "2019-01-01", SBP, 900.0, unit="mmHg", unit_cid=UNIT_MMHG)    # out of range
    add_meas(1000030, "2019-02-02", SBP, 120.0, unit="mm[Hg]", unit_cid=UNIT_MMHG)  # wrong unit string
    add_meas(1000030, PD, SBP, 132.0, unit="mmHg", unit_cid=UNIT_MMHG)              # valid
    add_meas(1000030, PD, SBP, 134.0, unit="mmHg", unit_cid=UNIT_MMHG)              # same-day duplicate
    add_meas(1000030, PD, CREAT, 1.1)
    add_meas(1000030, PD, BMI_C, 26.4, unit="kg/m2", unit_cid=UNIT_KGM2)
    expect(1000030, "complete panel, SBP dirty (out-of-range / wrong-unit / same-day dup)",
           CAD_code=0, CAD_code_date=None, LDL=60, Date_LDL_assessment=PD, BMI=26.4,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=1,
           has_bmi=1, has_diabetes_dx=0, complete_prevent_panel=1,
           note="SBP has out-of-range 900 + wrong-unit + same-day dup; extractor must bound it")

    # P31 creatinine present but ONLY as a censored row (value_as_number NULL,
    # value_source_value '<0.2'). The completeness query's `value_as_number IS NOT NULL`
    # guard MUST drop it -> has_serum_creatinine=0 -> INCOMPLETE. A row that looks like
    # data and is useless as data (cf. defect A2). Coverage: creatinine missing class.
    add_person(1000031, dob="1972-06-15"); add_visits(1000031, STD_VISITS)
    add_meas(1000031, PD, CHOL_EXCLUDED, 195.0)
    add_meas(1000031, PD, STRAY, 55.0)                                  # -> LDL=55
    add_meas(1000031, PD, SBP, 126.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000031, PD, CREAT, None, vsv="<0.2", op=OP_LT)            # censored -> must not count
    add_meas(1000031, PD, BMI_C, 24.1, unit="kg/m2", unit_cid=UNIT_KGM2)
    expect(1000031, "creatinine only as a censored NULL-value row -- EXCLUDED (must not count)",
           CAD_code=0, CAD_code_date=None, LDL=55, Date_LDL_assessment=PD, BMI=24.1,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=0,
           has_bmi=1, has_diabetes_dx=0, complete_prevent_panel=0,
           note="creatinine row exists but value_as_number is NULL")

    # P32 complete panel + HbA1c 7.2% (diabetic range) but NO diabetes diagnosis code.
    # Diabetes-by-code and diabetes-by-HbA1c do NOT identify the same people
    # (prevent_concepts.yaml): has_diabetes_dx=0 while has_hba1c=1. Still INCLUDED on the
    # five-input panel. Carries a smoking answer + antihypertensive for domain coverage.
    add_person(1000032, dob="1961-06-15"); add_visits(1000032, STD_VISITS)
    add_meas(1000032, PD, CHOL_EXCLUDED, 210.0)
    add_meas(1000032, PD, STRAY, 45.0)                                  # -> LDL=45
    add_meas(1000032, PD, SBP, 140.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000032, PD, CREAT, 1.0)
    add_meas(1000032, PD, BMI_C, 33.3, unit="kg/m2", unit_cid=UNIT_KGM2)
    add_meas(1000032, PD, HBA1C1, 7.2, unit="%", unit_cid=UNIT_PERCENT)
    add_smoking(1000032, "2020-01-01", "Never")
    add_drug(1000032, "2016-01-01", ANTIHTN[1])
    expect(1000032, "complete panel; HbA1c 7.2% but no diabetes code (definitions diverge)",
           CAD_code=0, CAD_code_date=None, LDL=45, Date_LDL_assessment=PD, BMI=33.3,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=1,
           has_bmi=1, has_diabetes_dx=0, has_hba1c=1, has_smoking=1, has_antihypertensive=1,
           complete_prevent_panel=1)

    # P33 complete panel but AGE 84 (dob 1938) -> outside PREVENT's validated 30-79 range
    # (Q-S7). The age gate must EXCLUDE it from both the eligible count and the complete
    # count, even though all five inputs are present. It still appears in the LDLR pheno_df
    # (that pipeline has no age gate), so it keeps a normal set of LDLR answers.
    add_person(1000033, dob="1938-06-15"); add_visits(1000033, STD_VISITS)
    add_meas(1000033, PD, CHOL_EXCLUDED, 200.0)
    add_meas(1000033, PD, STRAY, 50.0)                                  # -> LDL=50
    add_meas(1000033, PD, SBP, 130.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000033, PD, CREAT, 0.95)
    add_meas(1000033, PD, BMI_C, 28.6, unit="kg/m2", unit_cid=UNIT_KGM2)
    expect(1000033, "complete panel but age 84 -- EXCLUDED by the 30-79 gate (Q-S7)",
           CAD_code=0, CAD_code_date=None, LDL=50, Date_LDL_assessment=PD, BMI=28.6,
           any_chol_med=0, LDL_measured_on_meds="NA", censor_type=1, CAD_censored_date=LAST_VISIT,
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=1,
           has_bmi=1, has_diabetes_dx=0, complete_prevent_panel="age-excluded")

    # P34 complete panel, has_whole_genome_variant=0. This is the participant that DISTINGUISHES the
    # two cohorts: it is ABSENT from the srWGS-gated LDLR export/pheno_df (like P20, so verify.py must
    # still not see it), but PRESENT and complete in the genomic-free PREVENT cohort (sql/02 gates on
    # has_ehr_data, not srWGS). age_at_cdr = 2022-1968 = 54, in range.
    add_person(1000034, dob="1968-06-15", wgs=0); add_visits(1000034, STD_VISITS)
    add_meas(1000034, PD, CHOL_EXCLUDED, 185.0)
    add_meas(1000034, PD, STRAY, 58.0)
    add_meas(1000034, PD, SBP, 122.0, unit="mmHg", unit_cid=UNIT_MMHG)
    add_meas(1000034, PD, CREAT, 0.8)
    add_meas(1000034, PD, BMI_C, 25.4, unit="kg/m2", unit_cid=UNIT_KGM2)
    expect(1000034, "complete panel, wgs=0 -- ABSENT from LDLR, but PRESENT+complete in PREVENT cohort",
           CAD_code="absent", LDL="absent", any_chol_med="absent", censor_type="absent",
           CAD_censored_date="absent",
           has_total_cholesterol=1, has_hdl_c=1, has_systolic_bp=1, has_serum_creatinine=1,
           has_bmi=1, has_diabetes_dx=0, complete_prevent_panel=1)


# --------------------------------------------------------------------------
# Randomised filler, so group_by / distinct behaviour is exercised at volume
# --------------------------------------------------------------------------
def build_filler(n_from=1000035, n_to=1000307):
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
    build_prevent_scenarios()
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
            "race", "censor_type", "CAD_censored_date",
            # PREVENT panel expectations (T-004). Populated only for participants 1000028+.
            # Validated by tests/testthat/test-prevent-panel-sql.R, not by verify.py.
            "has_total_cholesterol", "has_hdl_c", "has_systolic_bp", "has_serum_creatinine",
            "has_bmi", "has_diabetes_dx", "has_hba1c", "has_smoking", "has_antihypertensive",
            "complete_prevent_panel", "note"]
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
