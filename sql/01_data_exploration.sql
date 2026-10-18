-- 01_data_exploration.sql
-- Read-only exploration of prepared_transactions in data/processed/customer_retention.sqlite3
--
-- Population notes (see reports/data_quality_and_methodology.md):
--   * "Eligible purchase line" = is_eligible_purchase_line = 1, i.e.:
--     InvoiceNo does NOT start with 'C', CustomerID is NOT NULL,
--     Quantity > 0, UnitPrice > 0, and InvoiceDate is within
--     2010-12-01 08:26:00 .. 2011-12-09 12:50:00.
--   * ALL customer-level purchase metrics below use that eligible population.
--     Queries that intentionally use the full table say so in their comments.
--   * LIMITATION: Gross Purchase Value is a GROSS measure. Cancellations and
--     returns are NOT netted against purchases because reliable
--     cancellation-to-original matching was not established from the data.
--   * LIMITATION: 3,710 invoices have no CustomerID at all (135,080 rows are
--     unattributable to a customer); they are excluded from customer-level
--     metrics but included in the whole-table counts where explicitly noted.
--   * Exclusion/flag counts can overlap (e.g. a row can be both a
--     cancellation and a negative quantity) and must not be summed.

-- 1. Overall counts (whole table, all rows regardless of eligibility)
SELECT 'rows_total'            AS metric, COUNT(*)                    AS value FROM prepared_transactions
UNION ALL
SELECT 'invoices_distinct',           COUNT(DISTINCT InvoiceNo)             FROM prepared_transactions
UNION ALL
SELECT 'customers_distinct_nonnull',  COUNT(DISTINCT CustomerID)            FROM prepared_transactions
 WHERE CustomerID IS NOT NULL;

-- 2. Monthly transaction-line and distinct-invoice counts (whole table;
--    NOT customer-level, so eligibility filter is not applied; included for
--    completeness/coverage of all activity including cancellations)
SELECT strftime('%Y-%m', InvoiceDate)            AS month,
       COUNT(*)                                  AS transaction_lines,
       COUNT(DISTINCT InvoiceNo)                 AS distinct_invoices
FROM prepared_transactions
GROUP BY month
ORDER BY month;

-- 3. Monthly ELIGIBLE purchase invoice counts and eligible Gross Purchase Value
--    (customer-level purchase population: eligible rows only; GPV is gross,
--     cancellations/returns NOT netted)
SELECT strftime('%Y-%m', InvoiceDate)            AS month,
       COUNT(*)                                  AS eligible_lines,
       COUNT(DISTINCT InvoiceNo)                 AS eligible_invoices,
       ROUND(SUM(gross_purchase_value), 2)       AS gross_purchase_value
FROM prepared_transactions
WHERE is_eligible_purchase_line = 1
GROUP BY month
ORDER BY month;

-- 4. Country-level ELIGIBLE metrics sorted by Gross Purchase Value descending
--    (customer-level purchase population: eligible rows only)
SELECT Country,
       COUNT(DISTINCT InvoiceNo)                 AS eligible_invoices,
       COUNT(DISTINCT CustomerID)                AS customers,
       ROUND(SUM(gross_purchase_value), 2)       AS gross_purchase_value
FROM prepared_transactions
WHERE is_eligible_purchase_line = 1
GROUP BY Country
ORDER BY gross_purchase_value DESC;

-- 5. Eligible vs ineligible row counts (whole table)
SELECT CASE WHEN is_eligible_purchase_line = 1 THEN 'eligible'
            ELSE 'ineligible' END                AS eligibility,
       COUNT(*)                                  AS rows
FROM prepared_transactions
GROUP BY eligibility;

-- 6. Data-quality flag counts (whole table; counts OVERLAP, do not sum)
SELECT 'cancellation_rows'       AS flag, SUM(is_cancellation)        AS rows_flagged FROM prepared_transactions
UNION ALL
SELECT 'negative_quantity_rows',        SUM(qty_negative)                      FROM prepared_transactions
UNION ALL
SELECT 'nonpositive_price_rows',       SUM(price_nonpositive)                 FROM prepared_transactions
UNION ALL
SELECT 'missing_customerid_rows',      SUM(CASE WHEN has_customer_id = 0 THEN 1 ELSE 0 END) FROM prepared_transactions
UNION ALL
SELECT 'exact_duplicate_rows',         SUM(is_exact_duplicate)                FROM prepared_transactions;

-- 7. Monthly coverage boundaries: first/last transaction day per month
--    (identifies incomplete first month 2010-12 and incomplete last month
--     2011-12, which end on 2011-12-09)
SELECT strftime('%Y-%m', InvoiceDate)            AS month,
       MIN(date(InvoiceDate))                    AS first_day,
       MAX(date(InvoiceDate))                    AS last_day,
       COUNT(DISTINCT date(InvoiceDate))         AS active_days
FROM prepared_transactions
GROUP BY month
ORDER BY month;
