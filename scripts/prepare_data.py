#!/usr/bin/env python3
"""First data-preparation stage for the UCI Online Retail project.

Reads data/raw/online_retail.zip in memory (never modifies or extracts it),
validates the workbook against verified audit invariants, adds quality flags
and the eligible-purchase-line indicator, computes Gross Purchase Value for
eligible rows only, and writes:

- data/processed/online_retail_prepared.csv
- reports/data_preparation_summary.md
"""
from pathlib import Path
import sys
import zipfile

import numpy as np
import pandas as pd

REPO = Path(__file__).resolve().parents[1]
RAW_ZIP = REPO / "data" / "raw" / "online_retail.zip"
WORKBOOK_NAME = "Online Retail.xlsx"
PROCESSED_DIR = REPO / "data" / "processed"
REPORTS_DIR = REPO / "reports"
OUT_CSV = PROCESSED_DIR / "online_retail_prepared.csv"
OUT_MD = REPORTS_DIR / "data_preparation_summary.md"

REQUIRED_COLS = [
    "InvoiceNo",
    "StockCode",
    "Description",
    "Quantity",
    "InvoiceDate",
    "UnitPrice",
    "CustomerID",
    "Country",
]

# Verified audit invariants (see reports/data_quality_and_methodology.md)
EXP_ROWS = 541909
EXP_NA_CUST = 135080
EXP_QTY_NEG = 10624
EXP_PRICE_NP = 2517
EXP_CANC_ROWS = 9288
EXP_DUP_KEEPFIRST = 5268
EXP_DUP_KEEPFALSE = 10147
EXP_UNIQUE_INVOICES = 25900
EXP_UNIQUE_CUSTOMERS_NONNULL = 4372
DATE_MIN = pd.Timestamp("2010-12-01 08:26:00")
DATE_MAX = pd.Timestamp("2011-12-09 12:50:00")


def load_workbook() -> pd.DataFrame:
    """Read the workbook from the raw ZIP in memory with clear error handling."""
    if not RAW_ZIP.exists():
        raise SystemExit(f"ERROR: raw ZIP not found: {RAW_ZIP}")
    if not RAW_ZIP.is_file():
        raise SystemExit(f"ERROR: raw ZIP path is not a file: {RAW_ZIP}")
    try:
        with zipfile.ZipFile(RAW_ZIP) as z:
            if WORKBOOK_NAME not in z.namelist():
                raise SystemExit(
                    f"ERROR: workbook '{WORKBOOK_NAME}' not found in {RAW_ZIP}; "
                    f"archive contains: {z.namelist()}"
                )
            with z.open(WORKBOOK_NAME) as fh:
                df = pd.read_excel(fh)
    except zipfile.BadZipFile as e:
        raise SystemExit(f"ERROR: raw ZIP is not a valid zip archive ({RAW_ZIP}): {e}")
    except Exception as e:
        # Includes openpyxl/xlrd read failures; preserve the underlying details.
        raise SystemExit(
            f"ERROR: failed to read workbook '{WORKBOOK_NAME}' from {RAW_ZIP}: "
            f"{type(e).__name__}: {e}"
        )
    return df


def build_summary_lines(
    df: pd.DataFrame,
    total_rows: int,
    eligible_rows: int,
    dup_keepfirst: int,
    dup_keepfalse: int,
) -> list:
    exclusions = {
        "cancellation invoices (InvoiceNo starts with C)": int(df["is_cancellation"].sum()),
        "missing CustomerID": int((~df["has_customer_id"]).sum()),
        "Quantity <= 0": int((df["Quantity"] <= 0).sum()),
        "UnitPrice <= 0": int((df["UnitPrice"] <= 0).sum()),
    }
    distinct_invoices = int(df["InvoiceNo"].nunique())
    distinct_customers = int(df.loc[df["CustomerID"].notna(), "CustomerID"].nunique())
    eligible_customers = (
        int(df.loc[df["is_eligible_purchase_line"], "CustomerID"].nunique())
        if eligible_rows
        else 0
    )
    lines = [
        "# Data Preparation Summary",
        "",
        "**Source (read-only):** `data/raw/online_retail.zip` (workbook "
        f"`{WORKBOOK_NAME}`) read directly in memory; the raw ZIP is never "
        "modified or extracted.",
        "",
        "## Dataset Dimensions & Dates",
        f"- Total rows: {total_rows}",
        f"- Total columns: {len(df.columns)}",
        f"- InvoiceDate minimum: {df['InvoiceDate'].min()}",
        f"- InvoiceDate maximum: {df['InvoiceDate'].max()}",
        "",
        "## Eligible Purchase Lines",
        "- is_eligible_purchase_line = (InvoiceNo does not start with 'C') AND "
        "(CustomerID not null) AND (Quantity > 0) AND (UnitPrice > 0) AND "
        "(InvoiceDate within verified observed range)",
        f"- Eligible purchase rows: {eligible_rows}",
        "",
        "## Exclusions / Flag Counts",
    ]
    lines += [f"- {name}: {count}" for name, count in exclusions.items()]
    lines += [
        "",
        "**Note:** these flag/exclusion counts can overlap (e.g. a single row may "
        "be both a cancellation and a negative quantity) and must not be summed.",
        "",
        "## Duplicates",
        f"- Exact duplicates (keep='first'): {dup_keepfirst}",
        f"- Rows in duplicate groups (keep=False): {dup_keepfalse}",
        "- Duplicates are flagged only; no rows were removed.",
        "",
        "## Distinct Counts",
        f"- Distinct invoices: {distinct_invoices}",
        f"- Distinct non-null customers: {distinct_customers}",
        f"- Distinct eligible customers: {eligible_customers}",
        "",
        "## Gross Purchase Value",
        "- gross_purchase_value = Quantity * UnitPrice for eligible rows only; "
        "null (not zero) for ineligible rows.",
        f"- Rows with non-null gross_purchase_value: {eligible_rows}",
        "",
        "## Validation",
        "- All 541,909 raw rows and original field values are preserved; only "
        "documented CSV serialization differences apply (datetime formatting, "
        "null representation).",
        "- Assertions verified: total rows, required columns, flag counts, "
        "duplicate counts, distinct invoice/customer counts, and InvoiceDate "
        "bounds against the verified audit invariants.",
        "- The raw ZIP is opened read-only and is not modified by this script.",
    ]
    return lines


def main() -> None:
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)

    df = load_workbook()

    missing_cols = [c for c in REQUIRED_COLS if c not in df.columns]
    if missing_cols:
        raise SystemExit(f"ERROR: missing required columns: {missing_cols}")

    df["InvoiceDate"] = pd.to_datetime(df["InvoiceDate"], errors="raise")

    total_rows = len(df)
    assert total_rows == EXP_ROWS, f"row count changed: {total_rows} != {EXP_ROWS}"
    assert len(df.columns) == len(REQUIRED_COLS), (
        f"column count mismatch: {len(df.columns)} != {len(REQUIRED_COLS)}"
    )

    # Verify parsed date bounds BEFORE computing eligibility.
    date_min, date_max = df["InvoiceDate"].min(), df["InvoiceDate"].max()
    assert date_min == DATE_MIN, f"InvoiceDate min changed: {date_min} != {DATE_MIN}"
    assert date_max == DATE_MAX, f"InvoiceDate max changed: {date_max} != {DATE_MAX}"

    # Duplicate counts on the original columns, before adding any flags.
    dup_keepfirst = int(df.duplicated(keep="first").sum())
    dup_keepfalse = int(df.duplicated(keep=False).sum())
    assert dup_keepfirst == EXP_DUP_KEEPFIRST, (
        f"duplicates (keep='first') changed: {dup_keepfirst} != {EXP_DUP_KEEPFIRST}"
    )
    assert dup_keepfalse == EXP_DUP_KEEPFALSE, (
        f"duplicates (keep=False) changed: {dup_keepfalse} != {EXP_DUP_KEEPFALSE}"
    )

    # Flags
    df["is_cancellation"] = df["InvoiceNo"].astype(str).str.startswith("C", na=False)
    df["has_customer_id"] = df["CustomerID"].notna()
    df["qty_negative"] = df["Quantity"] < 0
    df["price_nonpositive"] = df["UnitPrice"] <= 0
    df["is_exact_duplicate"] = df.duplicated(keep="first")

    assert int(df["has_customer_id"].sum()) == total_rows - EXP_NA_CUST, (
        "missing CustomerID count changed"
    )
    assert int(df["qty_negative"].sum()) == EXP_QTY_NEG, "negative quantity count changed"
    assert int(df["price_nonpositive"].sum()) == EXP_PRICE_NP, "non-positive price count changed"
    assert int(df["is_cancellation"].sum()) == EXP_CANC_ROWS, "cancellation count changed"
    assert int(df["is_exact_duplicate"].sum()) == EXP_DUP_KEEPFIRST

    # Distinct-count invariants (verified audit facts)
    distinct_invoices = int(df["InvoiceNo"].nunique())
    assert distinct_invoices == EXP_UNIQUE_INVOICES, (
        f"distinct invoices changed: {distinct_invoices} != {EXP_UNIQUE_INVOICES}"
    )
    distinct_customers = int(df.loc[df["CustomerID"].notna(), "CustomerID"].nunique())
    assert distinct_customers == EXP_UNIQUE_CUSTOMERS_NONNULL, (
        f"distinct non-null customers changed: "
        f"{distinct_customers} != {EXP_UNIQUE_CUSTOMERS_NONNULL}"
    )

    # Eligible purchase line: literal methodology rule, including observed date range.
    within_period = df["InvoiceDate"].between(DATE_MIN, DATE_MAX, inclusive="both")
    df["is_eligible_purchase_line"] = (
        (~df["is_cancellation"])
        & df["has_customer_id"]
        & (df["Quantity"] > 0)
        & (df["UnitPrice"] > 0)
        & within_period
    )

    # Gross Purchase Value: eligible rows only; null elsewhere (never zero-filled).
    df["gross_purchase_value"] = np.nan
    eligible_mask = df["is_eligible_purchase_line"]
    df.loc[eligible_mask, "gross_purchase_value"] = (
        df.loc[eligible_mask, "Quantity"] * df.loc[eligible_mask, "UnitPrice"]
    )

    # Row-preservation invariant: nothing dropped, nothing added.
    assert len(df) == EXP_ROWS, f"row count not preserved: {len(df)} != {EXP_ROWS}"

    df.to_csv(OUT_CSV, index=False)

    eligible_rows = int(eligible_mask.sum())
    lines = build_summary_lines(df, total_rows, eligible_rows, dup_keepfirst, dup_keepfalse)
    OUT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # Print the same concise summary to stdout.
    print("\n".join(lines))
    print("\nDONE")


if __name__ == "__main__":
    sys.exit(main())
