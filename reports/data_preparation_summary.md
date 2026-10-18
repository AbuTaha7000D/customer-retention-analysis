# Data Preparation Summary

**Source (read-only):** `data/raw/online_retail.zip` (workbook `Online Retail.xlsx`) read directly in memory; the raw ZIP is never modified or extracted.

## Dataset Dimensions & Dates
- Total rows: 541909
- Total columns: 15
- InvoiceDate minimum: 2010-12-01 08:26:00
- InvoiceDate maximum: 2011-12-09 12:50:00

## Eligible Purchase Lines
- is_eligible_purchase_line = (InvoiceNo does not start with 'C') AND (CustomerID not null) AND (Quantity > 0) AND (UnitPrice > 0) AND (InvoiceDate within verified observed range)
- Eligible purchase rows: 397884

## Exclusions / Flag Counts
- cancellation invoices (InvoiceNo starts with C): 9288
- missing CustomerID: 135080
- Quantity <= 0: 10624
- UnitPrice <= 0: 2517

**Note:** these flag/exclusion counts can overlap (e.g. a single row may be both a cancellation and a negative quantity) and must not be summed.

## Duplicates
- Exact duplicates (keep='first'): 5268
- Rows in duplicate groups (keep=False): 10147
- Duplicates are flagged only; no rows were removed.

## Distinct Counts
- Distinct invoices: 25900
- Distinct non-null customers: 4372
- Distinct eligible customers: 4338

## Gross Purchase Value
- gross_purchase_value = Quantity * UnitPrice for eligible rows only; null (not zero) for ineligible rows.
- Rows with non-null gross_purchase_value: 397884

## Validation
- All 541,909 raw rows and original field values are preserved; only documented CSV serialization differences apply (datetime formatting, null representation).
- Assertions verified: total rows, required columns, flag counts, duplicate counts, distinct invoice/customer counts, and InvoiceDate bounds against the verified audit invariants.
- The raw ZIP is opened read-only and is not modified by this script.
