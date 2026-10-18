-- 02_customer_purchase_summary.sql
-- Read-only per-customer aggregation and aggregate diagnostics against
-- prepared_transactions in data/processed/customer_retention.sqlite3.
--
-- Population (see reports/data_quality_and_methodology.md):
--   Eligible purchase line = is_eligible_purchase_line = 1, i.e.
--   InvoiceNo does NOT start with 'C', CustomerID IS NOT NULL,
--   Quantity > 0, UnitPrice > 0, and InvoiceDate within
--   2010-12-01 08:26:00 .. 2011-12-09 12:50:00. Expected eligible
--   customers: 4,338. Nothing is deleted or modified; all statements are
--   SELECT-only (CTE-based; no tables are created).
--
-- Reference date: 2011-12-10 (day after the verified max timestamp
--   2011-12-09 12:50:00). Recency is measured against it.
--
-- LIMITATION (gross, not net): Gross Purchase Value is a GROSS measure.
--   Cancellations/returns are NOT netted against purchases because
--   reliable cancellation-to-original matching is not possible from the
--   available fields. Query 8 reports a descriptive credit-note total
--   only; it is not subtracted from GPV and is not verified returns.
--
-- Duplicates: is_exact_duplicate flags exact repeated rows (5,268 with
--   keep='first'; 10,147 rows in duplicate groups with keep=False).
--   Duplicates are FLAGGED only, never deleted. Query 9 is a
--   sensitivity comparison (eligible rows with vs without the flag) and
--   must not be read as "the deduplicated values are the truth".
--
-- SQLite notes: this build (3.51.2) has math functions (LN/LOG), so
--   log-scale cutpoints are computed here. There is no built-in
--   percentile aggregate function; percentiles below are row-position
--   approximations (nearest-rank via ROW_NUMBER) computed in-window.
--   No CustomerIDs or per-customer rows are printed anywhere.

-- =========================================================================
-- Canonical per-customer base (re-used by every diagnostic query below as
-- the CTE `customer_base`). One row per eligible customer:
--   CustomerID, first/last eligible purchase timestamps, Frequency (F =
--   distinct eligible invoices), Monetary (M = sum of Gross Purchase
--   Value), Recency days vs 2011-12-10, Country, is_repeat_buyer.
-- Country consistency is verified in query 1 before it is relied upon.
-- =========================================================================
-- WITH customer_base AS (
--     SELECT
--         CustomerID,
--         MIN(InvoiceDate)                       AS first_eligible_purchase,
--         MAX(InvoiceDate)                       AS last_eligible_purchase,
--         COUNT(DISTINCT InvoiceNo)              AS frequency,
--         ROUND(SUM(gross_purchase_value), 2)    AS monetary,
--         CAST(JULIANDAY(date('2011-12-10'))
--              - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days,
--         (Recency = calendar-date difference: days between the DATE of the
--          last eligible purchase and the reference date. Range for the
--          eligible population: 1..374 days.)
--         MIN(Country)                           AS country,
--         CASE WHEN COUNT(DISTINCT InvoiceNo) >= 2 THEN 1 ELSE 0 END
--                                                AS is_repeat_buyer
--     FROM prepared_transactions
--     WHERE is_eligible_purchase_line = 1
--     GROUP BY CustomerID
-- )

-- Q1a. Country consistency check (assumption test before relying on
--      Country in the per-customer base): customers whose eligible rows
--      show more than one distinct country. Observed: 8 of 4,338 (none of
--      these is forced into a single country; country-level transaction
--      aggregates are reported separately in sql/06_business_findings.sql, F8).
SELECT COUNT(*) AS customers_with_multiple_countries
FROM (
    SELECT CustomerID
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
    HAVING COUNT(DISTINCT Country) > 1
);

-- Q1b. Eligible customer count and repeat-buyer split.
--      Expected eligible customers: 4,338.
WITH customer_base AS (
    SELECT
        CustomerID,
        COUNT(DISTINCT InvoiceNo) AS frequency,
        SUM(gross_purchase_value) AS monetary
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
)
SELECT
    COUNT(*)                                                    AS eligible_customers,
    SUM(CASE WHEN frequency = 1 THEN 1 ELSE 0 END)              AS one_purchase_customers,
    SUM(CASE WHEN frequency >= 2 THEN 1 ELSE 0 END)             AS repeat_buyers,
    ROUND(100.0 * SUM(CASE WHEN frequency = 1 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                        AS pct_one_purchase
FROM customer_base;

-- Q2. Frequency distribution (count and % of eligible customers).
WITH customer_base AS (
    SELECT COUNT(DISTINCT InvoiceNo) AS frequency
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
)
SELECT
    CASE WHEN frequency <= 5 THEN CAST(frequency AS TEXT)
         ELSE '6+' END                          AS freq_band,
    COUNT(*)                                    AS customers,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customer_base), 2)
                                                AS pct_of_customers
FROM customer_base
GROUP BY freq_band
ORDER BY MIN(frequency);

-- Q3. Frequency percentiles (nearest-rank approximation via ROW_NUMBER;
--     SQLite has no percentile aggregate). n = 4,338 customers.
--     The MEDIAN follows the conventional statistical definition: for
--     even n the average of the two middle ordered values; for odd n the
--     middle value. Other percentiles remain nearest-rank.
WITH customer_base AS (
    SELECT COUNT(DISTINCT InvoiceNo) AS frequency
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
),
ordered AS (
    SELECT frequency,
           ROW_NUMBER() OVER (ORDER BY frequency) AS rn,
           COUNT(*) OVER ()                       AS n
    FROM customer_base
)
SELECT
    MIN(CASE WHEN rn = CAST(0.25 * n AS INT) + 1 THEN frequency END) AS freq_p25,
    (SELECT AVG(frequency) FROM ordered
      WHERE rn IN ((n + 1) / 2, n / 2 + 1))                           AS freq_median,
    MIN(CASE WHEN rn = CAST(0.75 * n AS INT) + 1 THEN frequency END) AS freq_p75,
    MIN(CASE WHEN rn = CAST(0.90 * n AS INT) + 1 THEN frequency END) AS freq_p90,
    MAX(frequency)                                                    AS freq_max
FROM ordered;

-- Q4. Monetary summary (Gross Purchase Value, gross NOT netted):
--     min, percentiles (nearest-rank), mean, max, total.
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
),
ordered AS (
    SELECT monetary,
           ROW_NUMBER() OVER (ORDER BY monetary) AS rn,
           COUNT(*) OVER ()                      AS n
    FROM customer_base
)
SELECT
    ROUND(MIN(monetary), 2)                                             AS gpv_min,
    ROUND(MIN(CASE WHEN rn = CAST(0.25 * n AS INT) + 1 THEN monetary END), 2) AS gpv_p25,
    ROUND((SELECT AVG(monetary) FROM ordered
            WHERE rn IN ((n + 1) / 2, n / 2 + 1)), 2)                   AS gpv_median,
    ROUND(MIN(CASE WHEN rn = CAST(0.75 * n AS INT) + 1 THEN monetary END), 2) AS gpv_p75,
    ROUND(MIN(CASE WHEN rn = CAST(0.90 * n AS INT) + 1 THEN monetary END), 2) AS gpv_p90,
    ROUND(AVG(monetary), 2)                                            AS gpv_mean,
    ROUND(MAX(monetary), 2)                                            AS gpv_max,
    ROUND(SUM(monetary), 2)                                            AS gpv_total
FROM ordered;

-- Q5. Candidate Monetary quintile cutpoints, raw and log scale.
--     Log scale uses LN(); valid because every eligible customer has
--     monetary > 0 (Quantity > 0 and UnitPrice > 0 on every eligible
--     line). Cutpoints are the p20/p40/p60/p80 boundary values.
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
),
ordered AS (
    SELECT monetary, LN(monetary) AS log_monetary,
           ROW_NUMBER() OVER (ORDER BY monetary) AS rn,
           COUNT(*) OVER ()                      AS n
    FROM customer_base
)
SELECT
    ROUND(MIN(CASE WHEN rn = CAST(0.20 * n AS INT) + 1 THEN monetary END), 2) AS raw_p20,
    ROUND(MIN(CASE WHEN rn = CAST(0.40 * n AS INT) + 1 THEN monetary END), 2) AS raw_p40,
    ROUND(MIN(CASE WHEN rn = CAST(0.60 * n AS INT) + 1 THEN monetary END), 2) AS raw_p60,
    ROUND(MIN(CASE WHEN rn = CAST(0.80 * n AS INT) + 1 THEN monetary END), 2) AS raw_p80,
    ROUND(MIN(CASE WHEN rn = CAST(0.20 * n AS INT) + 1 THEN log_monetary END), 4) AS log_p20,
    ROUND(MIN(CASE WHEN rn = CAST(0.40 * n AS INT) + 1 THEN log_monetary END), 4) AS log_p40,
    ROUND(MIN(CASE WHEN rn = CAST(0.60 * n AS INT) + 1 THEN log_monetary END), 4) AS log_p60,
    ROUND(MIN(CASE WHEN rn = CAST(0.80 * n AS INT) + 1 THEN log_monetary END), 4) AS log_p80
FROM ordered;

-- Q6. Top-10 customer GPV concentration, aggregate statistics only
--     (no CustomerIDs are ever selected or printed).
WITH customer_base AS (
    SELECT SUM(gross_purchase_value) AS monetary
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
),
total AS (SELECT SUM(monetary) AS gpv_total, COUNT(*) AS customers FROM customer_base),
top10 AS (SELECT SUM(monetary) AS top10_gpv FROM (
              SELECT monetary FROM customer_base ORDER BY monetary DESC LIMIT 10
          ))
SELECT
    (SELECT gpv_total FROM total)                            AS gpv_total,
    ROUND(top10_gpv, 2)                                      AS top10_gpv,
    ROUND(100.0 * top10_gpv / (SELECT gpv_total FROM total), 2)
                                                             AS top10_pct_of_gpv,
    ROUND((SELECT gpv_total FROM total)
          / (SELECT customers FROM total), 2)                AS mean_gpv_per_customer
FROM top10;

-- Q7. Recency distribution vs reference date 2011-12-10 (days; whole
--     customers, eligible population only).
WITH customer_base AS (
    SELECT CAST(JULIANDAY(date('2011-12-10'))
                - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days
    FROM prepared_transactions
    WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
),
ordered AS (
    SELECT recency_days,
           ROW_NUMBER() OVER (ORDER BY recency_days) AS rn,
           COUNT(*) OVER ()                          AS n
    FROM customer_base
)
SELECT
    MIN(recency_days)                                                       AS recency_min,
    MIN(CASE WHEN rn = CAST(0.25 * n AS INT) + 1 THEN recency_days END)     AS recency_p25,
    MIN(CASE WHEN rn = CAST(0.50 * n AS INT) + 1 THEN recency_days END)     AS recency_median,
    MIN(CASE WHEN rn = CAST(0.75 * n AS INT) + 1 THEN recency_days END)     AS recency_p75,
    MAX(recency_days)                                                       AS recency_max
FROM ordered;

-- Q8. Descriptive credit-note amount (LIMITATION query): sum of
--     Quantity * UnitPrice over cancellation ('C') invoice lines.
--     This is a DESCRIPTIVE gross magnitude only. It is NOT netted
--     against GPV, NOT subtracted anywhere, and NOT verified as
--     returns matched to original purchases (matching is not possible
--     from the available fields).
SELECT
    COUNT(*)                                                          AS credit_note_lines,
    ROUND(SUM(Quantity * UnitPrice), 2)                               AS credit_note_value_signed,
    ROUND(-SUM(Quantity * UnitPrice), 2)                              AS credit_note_value_magnitude
FROM prepared_transactions
WHERE is_cancellation = 1 AND Quantity < 0;

-- Q9. Duplicate sensitivity: eligible metrics computed twice —
--     (a) all eligible rows (primary policy: duplicates flagged only)
--     (b) eligible rows excluding is_exact_duplicate = 1 (sensitivity
--         view only; data is NOT deleted and (b) is NOT "the truth").
--     Note: there are 5,268 duplicate-flagged rows in the FULL dataset;
--           of those, 5,192 belong to the ELIGIBLE population used here.
--     Reports deltas in total GPV, eligible customers, and invoices.
WITH e AS (
    SELECT * FROM prepared_transactions WHERE is_eligible_purchase_line = 1
)
SELECT
    ROUND(SUM(gross_purchase_value), 2)                                   AS gpv_all,
    ROUND(SUM(CASE WHEN is_exact_duplicate = 0
                   THEN gross_purchase_value END), 2)                     AS gpv_dedup_sensitivity,
    ROUND(SUM(CASE WHEN is_exact_duplicate = 1
                   THEN gross_purchase_value END), 2)                     AS gpv_from_duplicate_rows,
    COUNT(DISTINCT CustomerID)                                            AS eligible_customers_all,
    COUNT(DISTINCT CASE WHEN is_exact_duplicate = 0
                        THEN CustomerID END)                              AS eligible_customers_dedup,
    COUNT(DISTINCT InvoiceNo)                                             AS eligible_invoices_all,
    COUNT(DISTINCT CASE WHEN is_exact_duplicate = 0
                        THEN InvoiceNo END)                               AS eligible_invoices_dedup
FROM e;
