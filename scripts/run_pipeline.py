"""Run the SQL pipeline: sql/01 to sql/06, in order, on data/partd.duckdb.

Stops at the first error and prints the row count of every table and view.
Every SQL object is CREATE OR REPLACE, so the pipeline can be rerun from scratch.

Run from the project root:  python scripts/run_pipeline.py
"""

import sys
from pathlib import Path

import duckdb

DB_PATH = Path("data") / "partd.duckdb"
SQL_FILES = [
    "01_load_raw.sql",
    "02_dim_product.sql",
    "03_fact.sql",
    "04_analysis.sql",
    "05_validation.sql",
    "06_export.sql",
]


def main():
    if not Path("sql").is_dir():
        sys.exit("Run this from the project root: python scripts/run_pipeline.py")
    # COPY in 06_export.sql needs these folders to exist
    for folder in ("outputs", "powerbi"):
        Path(folder).mkdir(exist_ok=True)

    con = duckdb.connect(str(DB_PATH))
    for name in SQL_FILES:
        print(f"Running sql/{name} ...")
        try:
            con.execute((Path("sql") / name).read_text(encoding="utf-8"))
        except duckdb.Error as err:
            con.close()
            sys.exit(f"FAILED in sql/{name}:\n{err}")

    print("\nRow counts:")
    objects = con.execute(
        """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_catalog = current_database() AND table_schema = 'main'
        ORDER BY table_type, table_name
        """
    ).fetchall()
    for table_name, table_type in objects:
        count = con.execute(f'SELECT count(*) FROM "{table_name}"').fetchone()[0]
        kind = "view " if table_type == "VIEW" else "table"
        print(f"  {kind}  {table_name:<30} {count:>9,}")
    con.close()


if __name__ == "__main__":
    main()
