# Data Quality & Methodology Plan

## 1. Provenance & Verified Facts

- **Dataset**: UCI Online Retail (dataset 352) — https://archive.ics.uci.edu/dataset/352/online+retail  
- **License**: CC BY 4.0 — attribution required when using or referencing this work. (Cite: Chen, D. (2015). Online Retail [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5BW33)
- **Data period (documented)**: 01/12/2010 to 09/12/2011
- **Source file (official)**: `data/raw/online_retail.zip` (contains `Online Retail.xlsx`; 22.6 MB). Downloaded from official UCI source and preserved unchanged.
- **Dimensions (observed)**:
  - Rows: 541,909
  - Columns: 8 (InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country)
  - Date range (observed): 2010-12-01 08:26:00 to 2011-12-09 12:50:00
- **Quality counts (observed)**:
  - Missing Description: 1,454
  - Missing CustomerID: 135,080 (~25% of rows)
  - Duplicates (exact rows): 5,268 (rows marked as duplicates with `keep='first'`); 10,147 rows belong to duplicate groups (with `keep=False`)
  - Quantity < 0: 10,624 (9,288 are 'C' invoices; 1,336 are not 'C' invoices)
  - UnitPrice <= 0: 2,517
  - Cancellations (InvoiceNo starts with 'C'): 9,288 (all have Quantity < 0)
  - Negative-quantity rows outside `C` invoices: 1,336; all have `UnitPrice == 0.0` and missing `CustomerID` (business meaning unknown)
  - Unique invoices: 25,900; invoices with all CustomerIDs missing: 3,710; invoices with all IDs present: 22,190; invoices with mixed known/missing IDs: 0; no invoice has multiple distinct non-null CustomerIDs
  - Unique customers (CustomerID non-null): 4,372

All values above are verified from inspection; no derived business metrics have been calculated for this plan.

## 2. Data-Quality Policies: Flags vs. Exclusion Rules

We distinguish **flags** (non-destructive annotations) from **exclusion rules** (criteria for inclusion in specific analyses). Records are not to be deleted or transformed without explicit documentation and verification.

### Missing CustomerID (135,080 rows)
- **Flag**: `has_customer_id` = (CustomerID is not null/NaN).
- **Policy (verified):** Customer-level analyses (RFM, retention) are restricted to invoices/rows with non-null `CustomerID`. No customer ID imputation.
- **Exclusion rule (customer-level):** Exclude rows with missing `CustomerID` from primary customer-level purchase metrics.
- **Caveat (verified):** No invoice contains both known and missing CustomerIDs; 3,710 invoices have all CustomerIDs missing, 22,190 have all present. Customer identity is consistent within invoices when present. Large missing fraction means customer-level results will be biased; coverage must be reported explicitly.

### Cancellations (`InvoiceNo` starts with 'C') (9,288 rows; all Quantity < 0)
- **Flag**: `is_cancellation` = InvoiceNo string starts with 'C' (case-insensitive). Also flag `is_credit_note` consistently.
- **Policy:** Treat cancellations as adjustment/credit events. Do not sum absolute quantities/values blindly.
- **Exclusion rule:** Exclude cancellation lines from eligible purchase metrics (see Section 4). Do not net cancellations against purchases because reliable original-transaction matching was **not** established by available fields.
- **Caveat (verified):** Field-based matching (StockCode, opposite quantity, price, customer, date) is ambiguous and in many cases yields multiple candidates or no plausible match; some cancellations reference codes with no corresponding original line found. Matching remains unresolved; no claim of successful matching is made.

### Negative quantities (10,624 rows total; 1,336 outside 'C')
- **Flag**: `qty_negative` = (Quantity < 0); `qty_negative_non_cancellation` = (Quantity < 0 and not starting with 'C').
- **Policy (verified):** Eligible purchase lines require `Quantity > 0` (strictly positive). Negative quantities are not considered purchases.
- **Exclusion rule:** Exclude all negative-quantity rows from primary customer-level purchase metrics. Do not include them in Frequency or as positive revenue.
- **Caveat (verified):** 1,336 negative-quantity rows occur outside `C` invoices; all have `UnitPrice == 0.0` and missing `CustomerID`. Their business meaning remains unknown. Linkage to original transactions is unverified.

### Non-positive prices (UnitPrice <= 0; 2,517 rows)
- **Flag**: `price_invalid` = (UnitPrice <= 0).
- **Policy (verified):** Eligible purchase lines require `UnitPrice > 0`.
- **Exclusion rule:** Exclude from primary customer-level purchase metrics (including Monetary). Preserve raw records.
- **Caveat:** Business meaning varies (discounts, samples, goodwill, adjustments, errors); exclusion is by rule for purchase metrics, not dataset deletion.

### Missing descriptions (1,454 rows)
- **Flag**: `has_description` = Description not null/NaN.
- **Policy:** Track for completeness; not determinative for identity/eligibility.
- **Exclusion rule:** No automatic exclusion based solely on missing description.

### Exact duplicates (5,268 rows; 10,147 in duplicate groups)
- **Flag**: `is_exact_duplicate` = exact duplicate of another row (all fields equal). Record group membership.
- **Policy (verified):** Keep exact duplicate rows flagged, not automatically deleted. Distinguish: 5,268 rows marked as duplicates with `keep='first'`, and 10,147 rows belonging to duplicate groups with `keep=False`.
- **Exclusion rule:** Duplicates must not be removed silently. Any decision to exclude them from final metrics requires a later sensitivity comparison, explicit justification, and documented impact. 
- **Caveat:** Exact equality indicates likely data artifacts; legitimate repeated line items would differ in at least one identifying field.

**General principle**: Flags are descriptive; exclusions are analysis-specific and must be explicit. No records were deleted or transactions successfully matched in this plan.

## 3. Eligible Purchase Invoice & Customer Population

For repeat-purchase and RFM analysis:

- **Eligible purchase line (primary definition)**: A line/item representing a valid purchase, defined by (verified):
  - `InvoiceNo` does **not** start with `C` (`is_cancellation == False`)
  - `Quantity > 0` (strictly positive)
  - `UnitPrice > 0` (`price_invalid == False`)
  - Occurs within the observed InvoiceDate range (2010-12-01 08:26:00 to 2011-12-09 12:50:00)
  - Associated with non-null `CustomerID` for customer-level metrics (`has_customer_id == True`)
- **Eligible purchase invoice**: An invoice (InvoiceNo) that contains at least one eligible purchase line under the above criteria (for non-cancellation events).
- **Customer population (RFM/retention)**: Only customers with `has_customer_id == True` (CustomerID non-null). Customer-level aggregations are restricted to this subset. Report coverage: count of customers, invoices, and rows included vs excluded (including counts of excluded rows by reason: missing CustomerID, cancellations, non-positive quantity, non-positive price, duplicates when treated).
- **Invoice identity / coverage (verified)**: No invoice has mixed known/missing CustomerIDs; 3,710 invoices are entirely unattributable (all CustomerID null); 22,190 have all known. Unattributed invoices are excluded from customer-level metrics.
- **Caveat (verified)**: Reliable cancellation-to-original invoice matching is not established; therefore cancellations and returns are not netted against purchases. The 1,336 negative-quantity rows outside `C` (all zero-price, missing CustomerID) remain unclassified. The raw dataset is preserved unchanged; no customer IDs are imputed.

## 4. RFM Definition (implemented; see `sql/04_rfm_scoring.sql`)

- **Reference date**: `2011-12-10` (data-driven; day after the verified maximum InvoiceDate `2011-12-09 12:50:00`).
- **Recency (R)**: Calendar days between the customer's last eligible purchase date and the reference date, as `date('2011-12-10') - date(last_eligible_purchase)`.
- **Frequency (F)**: Count of distinct eligible purchase invoices per customer (not line items).
- **Monetary (M)**: **Gross Purchase Value** = sum of `Quantity * UnitPrice` across eligible purchase lines per customer.
- **Monetary semantics (explicit)**: Gross, not net revenue; cancellations/returns not netted; credit notes (`C`) and the 1,336 non-`C` negative-quantity rows (all zero-price, missing CustomerID) are not netted.
- **Inclusion/exclusion (customer-level)**: Missing `CustomerID`, non-positive quantities, or non-positive prices are excluded. Exact duplicates remain flagged (5,268 with `keep='first'`, 10,147 in duplicate groups with `keep=False`); sensitivity checks required before any deduplication.
- **Scoring bands (implemented in `sql/04_rfm_scoring.sql`):**
  - **R (5 bands, value-thresholds; nearest-rank cutpoints 13, 33, 72, 180 days)**: `R <= 13d` (highest R), `13d < R <= 33d`, `33d < R <= 72d`, `72d < R <= 180d`, `R > 180d` (lowest R). Equal values receive the same score; bands may be uneven. Lower Recency → higher score.
  - **F (4 ordinal bands)**: `F == 1`, `F == 2 or 3`, `F == 4 or 5`, `F >= 6`. One-time buyers retained. Ordinal preferred over quantiles given distribution.
  - **M (5 bands, value-thresholds; raw GPV preferred)**: `M <= 250.15` (lowest), `250.15 < M <= 490.22`, `490.22 < M <= 942.26`, `942.26 < M <= 2059.45`, `M > 2059.45` (highest). Equal values receive the same score; bands may be uneven. Raw GPV preferred for interpretability; log scoring is a sensitivity alternative only.
- **Boundary rules**: mutually exclusive and exhaustive; inclusive of upper boundary in each split; all equal boundary values go to the same band; every customer assigned exactly once.
- **Status**: Implemented in `sql/04_rfm_scoring.sql` (SELECT-only; no tables/views). Validation performed there covers: exactly 4,338 customers scored with no missing scores and positive Monetary; R in 1–5, F in 1–4, M in 1–5; per-band customer counts; boundary/tie handling at every cutpoint (equal values share a score); customer-level GPV reconciliation to eligible-line GPV (difference 0.00); and identical output on a deterministic re-run. No business segment labels or retention cohorts are assigned here, and no validation beyond these checks is implied.
- **Limitations**: return/cancellation matching unverified (gross GPV); 1,336 non-`C` negative-quantity rows unclassified; coverage excludes 3,710 invoices with all CustomerID missing; partial months at ends affect comparability; 8 of 4,338 customers span multiple countries (country-level views need handling); duplicates flagged only.

## 5. Retention Definition (implemented; see `sql/05_cohort_retention.sql`)

A customer-level retention view that respects data limitations:

- **Cohort definition**: Customers are cohorted by the month of their first **observed** eligible purchase (the first purchase visible in the dataset, not necessarily the customer's true first-ever purchase), restricted to customers with `has_customer_id == True` and at least one eligible purchase invoice (as defined in Section 3).
- **Retention metric**: For each cohort, the count/share of cohort customers who made at least one eligible purchase invoice at a given **calendar-month age**, where age = (activity year×12 + activity month) − (cohort year×12 + cohort month) and the denominator is that cohort's size. Reported ages are age 1 and age 3 months (`sql/06_business_findings.sql`, F6); the full observable age grid is produced by `sql/05_cohort_retention.sql`.
- **Adjustments for observation period (required)**:
  - **Short observation period** (~12 months total). 
  - **Incomplete start/end**: First month (2010-12-01, partial day) and last period (ends 2011-12-09, partial) mean some cohorts have truncated follow-up windows and must be handled as right-censored.
  - **Unobservable cells**: a cohort-age cell is reported only when cohort + age ≤ the last observed month (2011-12); unobservable/future cells are returned as NULL/NA, never zero, and are not interpreted as churn.
  - **Customer identification**: Restrict to non-null CustomerID; report cohort coverage (3,710 invoices entirely unattributable excluded).
- **Status**: Implemented in `sql/05_cohort_retention.sql` with validation covering: cohort sizes sum to the 4,338 eligible customers; one cohort per eligible customer; age-0 activity is 100% for every cohort; active customers never exceed cohort size; retention within [0,1] where observable; unobservable cells omitted as NULL/NA (never zero-filled); and identical output on a deterministic re-run. Ages 1 and 3 months are summarised in `sql/06_business_findings.sql` (F6). These are **observed repeat-activity rates** for specific ages, not censoring-adjusted retention; cohorts have unequal observation windows and their rates are not directly comparable without accounting for that limitation. Retention definitions remain consistent with the purchase eligibility and duplicate handling above.

## 6. Decisions and Implementation Status

The items below were the pre-implementation verification checklist for this project. They are now resolved by the implemented scripts and SQL; the adopted decision (and any remaining limitation) is stated for each. No caveat below has been relaxed.

1. **Cancellation matching**: Reliable matching of `C` invoices to original invoices was not established. Cancellations and returns are therefore **not netted**; all Monetary values are Gross Purchase Value only.
2. **Negative quantity semantics**: The 1,336 negative-quantity rows outside `C` invoices (all zero-price, missing CustomerID) remain unclassified and are excluded from primary purchase metrics.
3. **Price <= 0 cases**: Excluded from primary purchase-metric eligibility by rule (`UnitPrice > 0`); rows are retained, not deleted.
4. **Duplicates**: Exact duplicates are flagged only (5,268 with `keep='first'`, 10,147 in duplicate groups with `keep=False`). A duplicate-exclusion sensitivity is reported (`sql/02` Q9, `sql/06` F9) and is limited to aggregate GPV and distinct customer/invoice counts; per-customer Monetary, RFM, concentration, and cohort metrics are not re-tested under duplicate exclusion.
5. **CustomerID missing subset**: Rows with missing CustomerID are excluded from customer-level metrics; no imputation is performed, and coverage (including 3,710 entirely unattributable invoices) is reported.
6. **Eligible population parameters**: Eligible purchase line = non-cancellation, `CustomerID` non-null (for customer-level metrics), `Quantity > 0`, `UnitPrice > 0`, within the observed date range (2010-12-01 08:26:00 .. 2011-12-09 12:50:00). Applied consistently across preparation, RFM, retention, and business findings.
7. **Retention windows & censoring**: Calendar-month cohorts and ages are used; age 1 and age 3 months are reported. Cohort observation windows are unequal, the first/last months are partial, and unobservable/future cohort-age cells are NULL/NA (never zero). Reference date `2011-12-10` is used as the Recency reference.
8. **RFM implementation details**: Frequency = distinct eligible purchase invoices; Monetary = Gross Purchase Value (not net revenue). Implemented in `sql/04_rfm_scoring.sql` with the documented exclusions and duplicate handling.

**Notes**: This document reflects verified audit facts and the implemented policies and definitions. The raw file `data/raw/online_retail.zip` remains unchanged. The metrics do not represent net revenue, and cancellation-to-original matching is not assumed to be possible.