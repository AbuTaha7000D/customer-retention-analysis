#!/usr/bin/env python3
"""Load the prepared CSV into a SQLite database and validate the import.

Rebuilds (never appends to) the single table `prepared_transactions` in
data/processed/customer_retention.sqlite3 from
data/processed/online_retail_prepared.csv, then runs SQL-level validation
queries against the verified audit invariants and prints a concise report.
"""
import csv
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CSV_PATH = REPO / "data" / "processed" / "online_retail_prepared.csv"
DB_PATH = REPO / "data" / "processed" / "customer_retention.sqlite3"
TABLE = "prepared_transactions"

# Verified invariants (see reports/data_quality_and_methodology.md)
EXP_TOTAL_ROWS = 541909
EXP_DISTINCT_INVOICES = 25900
EXP_DISTINCT_CUSTOMERS = 4372
EXP_ELIGIBLE_ROWS = 397884
EXP_ELIGIBLE_CUSTOMERS = 4338
EXP_DUP_FLAG = 5268
DATE_MIN = "2010-12-01 08:26:00"
DATE_MAX = "2011-12-09 12:50:00"

BOOL_COLS = {
    "is_cancellation",
    "has_customer_id",
    "qty_negative",
    "price_nonpositive",
    "is_exact_duplicate",
    "is_eligible_purchase_line",
}
INT_COLS = {"Quantity"}
REAL_COLS = {"UnitPrice", "CustomerID", "gross_purchase_value"}
TEXT_COLS = {"InvoiceNo", "StockCode", "Description", "InvoiceDate", "Country"}


def convert(row: dict) -> tuple:
    """Convert one CSV row (string values) to typed SQLite values."""
    values = []
    for col, raw in row.items():
        if col in BOOL_COLS:
            values.append(1 if raw == "True" else 0)
        elif col in INT_COLS:
            values.append(int(raw))
        elif col in REAL_COLS:
            values.append(None if raw == "" else float(raw))
        elif col in TEXT_COLS:
            values.append(None if raw == "" else raw)
        else:  # unknown column: keep as-is (TEXT) rather than dropping data
            values.append(None if raw == "" else raw)
    return tuple(values)


def main() -> None:
    if not CSV_PATH.is_file():
        raise SystemExit(f"ERROR: prepared CSV not found: {CSV_PATH}")

    # Read the CSV (header defines column order).
    with CSV_PATH.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        columns = reader.fieldnames
        if not columns:
            raise SystemExit(f"ERROR: CSV has no header: {CSV_PATH}")
        rows = [convert(r) for r in reader]

    ncols = len(columns)
    placeholders = ", ".join("?" * ncols)
    create_sql = (
        f"CREATE TABLE {TABLE} (\n"
        + ",\n".join(f"    {c} " + sql_type(c) for c in columns)
        + "\n)"
    )

    # Rebuild deterministically: never append to or preserve stale data.
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute(create_sql)
        conn.executemany(
            f"INSERT INTO {TABLE} ({', '.join(columns)}) VALUES ({placeholders})",
            rows,
        )
        conn.commit()

        # ---- SQL-level validation ----
        checks = []

        def check(name: str, sql: str, expected) -> None:
            got = conn.execute(sql).fetchone()[0]
            checks.append((name, got, expected, got == expected))

        check(
            "total rows",
            f"SELECT COUNT(*) FROM {TABLE}",
            EXP_TOTAL_ROWS,
        )
        check(
            "distinct invoices",
            f"SELECT COUNT(DISTINCT InvoiceNo) FROM {TABLE}",
            EXP_DISTINCT_INVOICES,
        )
        check(
            "distinct non-null customers",
            f"SELECT COUNT(DISTINCT CustomerID) FROM {TABLE} "
            "WHERE CustomerID IS NOT NULL",
            EXP_DISTINCT_CUSTOMERS,
        )
        check(
            "eligible purchase rows",
            f"SELECT COUNT(*) FROM {TABLE} WHERE is_eligible_purchase_line = 1",
            EXP_ELIGIBLE_ROWS,
        )
        check(
            "eligible distinct customers",
            f"SELECT COUNT(DISTINCT CustomerID) FROM {TABLE} "
            "WHERE is_eligible_purchase_line = 1 AND CustomerID IS NOT NULL",
            EXP_ELIGIBLE_CUSTOMERS,
        )
        check(
            "duplicate flag count (keep='first')",
            f"SELECT COUNT(*) FROM {TABLE} WHERE is_exact_duplicate = 1",
            EXP_DUP_FLAG,
        )
        check(
            "date minimum",
            f"SELECT MIN(InvoiceDate) FROM {TABLE}",
            DATE_MIN,
        )
        check(
            "date maximum",
            f"SELECT MAX(InvoiceDate) FROM {TABLE}",
            DATE_MAX,
        )
        check(
            "gpv non-null exactly when eligible",
            f"SELECT COUNT(*) FROM {TABLE} WHERE "
            "(gross_purchase_value IS NOT NULL) != (is_eligible_purchase_line = 1)",
            0,
        )
        check(
            "gpv values correct on eligible rows",
            f"SELECT COUNT(*) FROM {TABLE} WHERE is_eligible_purchase_line = 1 "
            "AND ABS(gross_purchase_value - Quantity * UnitPrice) > 1e-9",
            0,
        )
        check(
            "loaded rows match CSV rows",
            f"SELECT COUNT(*) FROM {TABLE}",
            len(rows),
        )

        # ---- Report ----
        print(f"Database: {DB_PATH}")
        print(f"Table:    {TABLE} ({len(rows)} rows, {ncols} columns)")
        print()
        failures = 0
        for name, got, expected, ok in checks:
            status = "PASS" if ok else "FAIL"
            if not ok:
                failures += 1
            print(f"[{status}] {name}: got={got} expected={expected}")
        print()
        if failures:
            raise SystemExit(f"ERROR: {failures} validation check(s) failed")
        print(f"All {len(checks)} validation checks passed.")
    finally:
        conn.close()


def sql_type(col: str) -> str:
    if col in BOOL_COLS:
        return "INTEGER NOT NULL"  # 0/1
    if col in INT_COLS:
        return "INTEGER"
    if col in REAL_COLS:
        return "REAL"  # nullable
    return "TEXT"


if __name__ == "__main__":
    sys.exit(main())
