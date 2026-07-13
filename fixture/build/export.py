"""Run the notebook's own generated SQL against the fixture and write the sharded
CSV exports the "Format ..." cells read.

The queries are extracted verbatim from `LDLR Get phenotypes.ipynb` (see
extract_sql.py) -- nothing is paraphrased. If a query returns 0 rows here, the
fixture's cb_criteria seeding is wrong, which is exactly the silent failure mode
FORMAT.md sec.3 warns about.

Output mirrors the real bucket layout so the notebook's hardcoded gs:// paths work
after only WORKSPACE_BUCKET is repointed:

  fixture/bucket/<bucket>/bq_exports/<owner>/<YYYYMMDD>/<name>/<name>_0000000000NN.csv

Run:  py fixture/build/export.py
"""
import pathlib
import shutil

import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / "fixture"
QUERIES = FIX / "build" / "queries"
DB_PATH = FIX / "db" / "aou_fixture.duckdb"

BUCKET = "fc-secure-7e84f6f0-9e03-4626-b34e-6dcf5d5f1701"
OWNER = "megan.lancaster@researchallofus.org"

# name -> (query file, export date, n_shards)
# n_shards=1 where the notebook's "Format" cell hardcodes a single exact shard
# filename (…_000000000000.csv) rather than a *.csv glob -- writing 2 shards there
# would silently strand half the rows.
EXPORTS = {
    "condition_99802609":  ("dataset_99802609_condition_sql",   "20240321", 2),
    "procedure_35162265":  ("dataset_35162265_procedure_sql",   "20240321", 2),
    "drug_32584860":       ("dataset_32584860_drug_sql",        "20240321", 2),
    "drug_41010260":       ("dataset_41010260_drug_sql",        "20240321", 2),
    "measurement_65837970": ("dataset_65837970_measurement_sql", "20240321", 2),
    "person_09842086":     ("dataset_09842086_person_sql",      "20240321", 2),
    "survey_43208585":     ("dataset_43208585_survey_sql",      "20240321", 2),
    "measurement_80780919": ("dataset_80780919_measurement_sql", "20240324", 2),
    "condition_32633938":  ("dataset_32633938_condition_sql",   "20241101", 1),
    "condition_64642663":  ("dataset_64642663_condition_sql",   "20241101", 1),
    "observation_64642663": ("dataset_64642663_observation_sql", "20241101", 1),
    "observation_59227507": ("dataset_59227507_observation_sql", "20241101", 2),
    "condition_86884566":  ("dataset_86884566_condition_sql",   "20241104", 2),
}


def main():
    con = duckdb.connect(str(DB_PATH), read_only=True)
    root = FIX / "bucket" / BUCKET / "bq_exports" / OWNER
    if root.exists():
        # OneDrive intermittently holds directory handles on Windows; the COPY below
        # overwrites each shard anyway, so a failed rmtree is not fatal.
        for stale in root.rglob("*.csv"):
            stale.unlink(missing_ok=True)
        shutil.rmtree(root, ignore_errors=True)

    print(f"{'export':<22} {'rows':>6}  {'persons':>7}  shards")
    print("-" * 50)
    empty = []
    for name, (qfile, date, n_shards) in EXPORTS.items():
        sql = (QUERIES / f"{qfile}.sql").read_text(encoding="utf-8")
        # BigQuery -> DuckDB dialect gap (FORMAT.md sec.9): DuckDB quotes identifiers
        # with " rather than `. Nothing else in the generated SQL needs translating.
        sql = sql.replace("`", '"')
        con.execute(f"CREATE OR REPLACE TEMP VIEW _x AS {sql}")
        total = con.execute("SELECT count(*) FROM _x").fetchone()[0]
        persons = con.execute("SELECT count(DISTINCT person_id) FROM _x").fetchone()[0]

        outdir = root / date / name
        outdir.mkdir(parents=True, exist_ok=True)

        # Split into shards by row number, preserving query order. The notebook's
        # reader bind_rows() whatever `gsutil ls` returns, so shard boundaries must
        # not change the union -- but they DO change per-shard type inference (A8).
        per = -(-total // n_shards) if total else 0
        for s in range(n_shards):
            path = outdir / f"{name}_{s:012d}.csv"
            if total == 0:
                con.execute(f"COPY (SELECT * FROM _x) TO '{path.as_posix()}' (HEADER, DELIMITER ',')")
                break
            con.execute(
                f"COPY (SELECT * EXCLUDE (_rn) FROM "
                f"(SELECT *, row_number() OVER () AS _rn FROM _x) "
                f"WHERE _rn > {s * per} AND _rn <= {(s + 1) * per}) "
                f"TO '{path.as_posix()}' (HEADER, DELIMITER ',')")

        flag = "" if total else "   <-- EMPTY (check cb_criteria seeding)"
        if not total:
            empty.append(name)
        print(f"{name:<22} {total:>6}  {persons:>7}  {n_shards}{flag}")

    con.close()
    print(f"\nwrote to fixture/bucket/{BUCKET}/bq_exports/{OWNER}/")
    if empty:
        raise SystemExit(f"\nFAIL: {len(empty)} export(s) returned no rows: {', '.join(empty)}")
    print("all exports non-empty")


if __name__ == "__main__":
    main()
