-- 06_business_findings.sql
-- Read-only business-findings diagnostics against
-- data/processed/customer_retention.sqlite3 (table prepared_transactions).
-- All statements are SELECT-only, CTE-based; no tables/views are created and
-- no data is modified. No CustomerID is ever selected or printed.
--
-- Population (see reports/data_quality_and_methodology.md):
--   Eligible purchase line = is_eligible_purchase_line = 1, i.e. InvoiceNo
--   does NOT start with 'C', CustomerID is NOT NULL, Quantity > 0,
--   UnitPrice > 0, InvoiceDate within 2010-12-01 08:26:00 .. 2011-12-09 12:50:00.
--   Expected: 397,884 eligible lines, 18,532 eligible invoices,
--   4,338 eligible customers.
--
-- Measure semantics:
--   * Gross Purchase Value (GPV) is a GROSS measure in GBP. Cancellations and
--     returns are NOT netted because reliable cancellation-to-original matching
--     was not established. GPV is therefore NOT net revenue.
--   * Exact duplicates are FLAGGED, never deleted. They are NOT proven errors.
--   * Percentages always state their denominator explicitly.
--   * This file reports observed associations only. It makes no causal claims
--     (no intervention is implied), no permanent-churn claims (the observation
--     window is ~12 months and months at both ends are partial), and no net
--     revenue claims.
--   * Months 2010-12 (partial start: window opens 2010-12-01, first rows on
--     2010-12-01, coverage to 2010-12-23 in-month) and 2011-12 (truncated end:
--     data stop 2011-12-09) are flagged explicitly and are not comparable to
--     full months.

-- ===========================================================================
-- F1. Eligible population and GPV reconciliation (customer-level vs line-level)
-- ===========================================================================
WITH lines AS (
  SELECT COUNT(*) AS n_lines, ROUND(SUM(gross_purchase_value), 2) AS gpv
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
cust AS (
  SELECT COUNT(*) AS n_customers, ROUND(SUM(m), 2) AS gpv
  FROM (
    SELECT CustomerID, SUM(gross_purchase_value) AS m
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1
    GROUP BY CustomerID
  )
)
SELECT
  lines.n_lines                                   AS eligible_lines,
  cust.n_customers                                AS eligible_customers,
  lines.gpv                                       AS eligible_line_gpv,
  cust.gpv                                        AS customer_level_gpv,
  ROUND(ABS(lines.gpv - cust.gpv), 2)             AS gpv_difference
FROM lines, cust;

-- ===========================================================================
-- F2. Repeat purchasing: share of one-time vs multiple-invoice customers
--     Denominator: 4,338 eligible customers.
-- ===========================================================================
WITH cust AS (
  SELECT CustomerID, COUNT(DISTINCT InvoiceNo) AS f
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
)
SELECT
  COUNT(*)                                                              AS eligible_customers,
  SUM(CASE WHEN f = 1  THEN 1 ELSE 0 END)                               AS one_time_customers,
  ROUND(100.0 * SUM(CASE WHEN f = 1  THEN 1 ELSE 0 END) / COUNT(*), 2)  AS pct_one_time,
  SUM(CASE WHEN f >= 2 THEN 1 ELSE 0 END)                               AS repeat_customers,
  ROUND(100.0 * SUM(CASE WHEN f >= 2 THEN 1 ELSE 0 END) / COUNT(*), 2)  AS pct_repeat
FROM cust;

-- ===========================================================================
-- F3. One-time vs repeat buyers: frequency and GPV
--     Per-customer averages are computed WITHIN each segment (denominator is
--     that segment's customer count). Totals are segment-wide SUMS. The two
--     must not be conflated. avg_gpv_per_invoice = segment GPV / segment
--     eligible invoices (each eligible invoice belongs to exactly one customer,
--     no invoice spans customers). pct_of_total_gpv denominator = total
--     eligible GPV across all 4,338 eligible customers.
-- ===========================================================================
WITH cust AS (
  SELECT CustomerID, COUNT(DISTINCT InvoiceNo) AS f, SUM(gross_purchase_value) AS m
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
seg AS (
  SELECT CASE WHEN f = 1 THEN 'one_time' ELSE 'repeat' END AS segment, f, m FROM cust
)
SELECT
  segment,
  COUNT(*)                              AS customers,
  SUM(f)                                AS total_invoices,
  ROUND(SUM(m), 2)                      AS total_gpv,
  ROUND(100.0 * SUM(m) / (SELECT SUM(m) FROM seg), 2) AS pct_of_total_gpv,
  ROUND(AVG(f), 2)                      AS avg_invoices_per_customer,
  ROUND(AVG(m), 2)                      AS avg_gpv_per_customer,
  ROUND(SUM(m) / SUM(f), 2)             AS avg_gpv_per_invoice
FROM seg
GROUP BY segment
ORDER BY segment;

-- ===========================================================================
-- F4. Revenue (GPV) concentration among top customers
--     Method: rank eligible customers by GPV descending (ties broken by
--     CustomerID ascending for determinism, not output). Top X% = the first
--     k customers where k = ROUND(0.01*N), ROUND(0.05*N), ROUND(0.10*N)
--     (nearest integer). Shares = 100 * (top-k GPV) / (total GPV), rounded to
--     2 dp. A top-10-CUSTOMER block is included to compare directly with the
--     existing top-10 result from sql/02_customer_purchase_summary.sql (Q6).
-- ===========================================================================
WITH cust AS (
  SELECT CustomerID, ROUND(SUM(gross_purchase_value), 2) AS m
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
ranked AS (
  SELECT m, ROW_NUMBER() OVER (ORDER BY m DESC, CustomerID) AS rn FROM cust
),
p AS (SELECT COUNT(*) AS n, SUM(m) AS gpv_total FROM cust)
SELECT
  n                                                                     AS eligible_customers,
  ROUND(gpv_total, 2)                                                   AS gpv_total,
  CAST(ROUND(0.01 * n) AS INT)                                          AS k_top1pct_customers,
  ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.01 * n) AS INT)), 2) AS top1pct_gpv,
  ROUND(100.0 * (SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.01 * n) AS INT)) / gpv_total, 2) AS top1pct_pct_gpv,
  CAST(ROUND(0.05 * n) AS INT)                                          AS k_top5pct_customers,
  ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.05 * n) AS INT)), 2) AS top5pct_gpv,
  ROUND(100.0 * (SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.05 * n) AS INT)) / gpv_total, 2) AS top5pct_pct_gpv,
  CAST(ROUND(0.10 * n) AS INT)                                          AS k_top10pct_customers,
  ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.10 * n) AS INT)), 2) AS top10pct_gpv,
  ROUND(100.0 * (SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.10 * n) AS INT)) / gpv_total, 2) AS top10pct_pct_gpv,
  ROUND((SELECT SUM(m) FROM ranked WHERE rn <= 10), 2)                  AS top10customers_gpv,
  ROUND(100.0 * (SELECT SUM(m) FROM ranked WHERE rn <= 10) / gpv_total, 2) AS top10customers_pct_gpv
FROM p;

-- Vertical view of the same concentration figures (easier to read).
WITH cust AS (
  SELECT CustomerID, ROUND(SUM(gross_purchase_value), 2) AS m
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
ranked AS (
  SELECT m, ROW_NUMBER() OVER (ORDER BY m DESC, CustomerID) AS rn FROM cust
),
p AS (SELECT COUNT(*) AS n, SUM(m) AS gpv_total FROM cust)
SELECT 'top_1pct' AS segment, CAST(ROUND(0.01*n) AS INT) AS k_customers,
       ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.01*n) AS INT)),2) AS topk_gpv,
       ROUND(100.0*(SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.01*n) AS INT))/gpv_total,2) AS pct_of_gpv FROM p
UNION ALL
SELECT 'top_5pct', CAST(ROUND(0.05*n) AS INT),
       ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.05*n) AS INT)),2),
       ROUND(100.0*(SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.05*n) AS INT))/gpv_total,2) FROM p
UNION ALL
SELECT 'top_10pct', CAST(ROUND(0.10*n) AS INT),
       ROUND((SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.10*n) AS INT)),2),
       ROUND(100.0*(SELECT SUM(m) FROM ranked WHERE rn <= CAST(ROUND(0.10*n) AS INT))/gpv_total,2) FROM p
UNION ALL
SELECT 'top_10_customers', 10,
       ROUND((SELECT SUM(m) FROM ranked WHERE rn <= 10),2),
       ROUND(100.0*(SELECT SUM(m) FROM ranked WHERE rn <= 10)/gpv_total,2) FROM p;

-- ===========================================================================
-- F5. Recency bands and repeat status
--     Recency = calendar days from last eligible purchase to 2011-12-10.
--     Bands follow the documented RFM R cutpoints (13/33/72/180).
--     Denominator for pct_of_customers = 4,338 eligible customers.
--     repeat_share_pct denominator = customers in that band.
--     Customers in long-recency bands are NOT called "churned": the window is
--     ~12 months and the last month is truncated, so they may simply be
--     unobserved after 2011-12-09.
-- ===========================================================================
WITH cust AS (
  SELECT CustomerID,
         COUNT(DISTINCT InvoiceNo) AS f,
         SUM(gross_purchase_value) AS m,
         CAST(JULIANDAY(date('2011-12-10')) - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS r
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
)
SELECT
  CASE WHEN r <= 13 THEN '1_1-13d'
       WHEN r <= 33 THEN '2_14-33d'
       WHEN r <= 72 THEN '3_34-72d'
       WHEN r <= 180 THEN '4_73-180d'
       ELSE '5_181+d' END                                              AS recency_band,
  COUNT(*)                                                             AS customers,
  ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM cust), 2)             AS pct_of_customers,
  SUM(CASE WHEN f = 1  THEN 1 ELSE 0 END)                              AS one_time_customers,
  SUM(CASE WHEN f >= 2 THEN 1 ELSE 0 END)                              AS repeat_customers,
  ROUND(100.0 * SUM(CASE WHEN f >= 2 THEN 1 ELSE 0 END) / COUNT(*), 2) AS repeat_share_pct_within_band,
  ROUND(AVG(m), 2)                                                     AS avg_gpv_per_customer
FROM cust
GROUP BY recency_band
ORDER BY MIN(r);

-- ===========================================================================
-- F6. Cohort observed repeat-activity at age 1 and age 3 months
--     Cohort = month of FIRST OBSERVED eligible purchase (left-truncated,
--     not necessarily true first-ever purchase). Age = calendar-month
--     difference (year*12 + month index). A cell is observable only when
--     cohort + age <= last observed month (2011-12). Unobservable cells are
--     NULL (NA), never 0. An observable cell with no activity is a genuine 0.
--     These are OBSERVED repeat-activity rates for the given ages, NOT
--     censoring-adjusted retention and NOT evidence of permanent churn.
--     Cohorts have unequal observation windows (earlier cohorts have longer
--     follow-up, later cohorts fewer observable ages); their rates are not
--     directly comparable without accounting for that limitation and for the
--     left-truncated 2010-12 start and right-truncated 2011-12 end.
-- ===========================================================================
WITH cust AS (
  SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cm
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
cs AS (
  SELECT cm, COUNT(*) AS cohort_size,
         (CAST(substr(cm,1,4) AS INT) * 12 + CAST(substr(cm,6,2) AS INT)) AS cmi
  FROM cust GROUP BY cm
),
act AS (
  SELECT DISTINCT CustomerID,
         (CAST(substr(strftime('%Y-%m',InvoiceDate),1,4) AS INT) * 12 +
          CAST(substr(strftime('%Y-%m',InvoiceDate),6,2) AS INT)) AS ami
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
ci AS (
  SELECT c.CustomerID, cs.cmi FROM cust c JOIN cs ON c.cm = cs.cm
),
maxi AS (SELECT MAX(ami) AS mxi FROM act),
ac AS (
  SELECT ci.cmi, (a.ami - ci.cmi) AS age_months, COUNT(DISTINCT ci.CustomerID) AS active_customers
  FROM ci JOIN act a ON ci.CustomerID = a.CustomerID
  GROUP BY ci.cmi, age_months
)
SELECT
  cs.cm                                                                 AS cohort_month,
  cs.cohort_size,
  CASE WHEN (SELECT mxi FROM maxi) - cs.cmi >= 1
       THEN COALESCE((SELECT SUM(active_customers) FROM ac WHERE ac.cmi = cs.cmi AND ac.age_months = 1), 0)
       END                                                              AS age1_active,
  CASE WHEN (SELECT mxi FROM maxi) - cs.cmi >= 1
       THEN ROUND(1.0 * COALESCE((SELECT SUM(active_customers) FROM ac WHERE ac.cmi = cs.cmi AND ac.age_months = 1), 0) / cs.cohort_size, 4)
       END                                                              AS age1_observed_rate,
  CASE WHEN (SELECT mxi FROM maxi) - cs.cmi >= 3
       THEN COALESCE((SELECT SUM(active_customers) FROM ac WHERE ac.cmi = cs.cmi AND ac.age_months = 3), 0)
       END                                                              AS age3_active,
  CASE WHEN (SELECT mxi FROM maxi) - cs.cmi >= 3
       THEN ROUND(1.0 * COALESCE((SELECT SUM(active_customers) FROM ac WHERE ac.cmi = cs.cmi AND ac.age_months = 3), 0) / cs.cohort_size, 4)
       END                                                              AS age3_observed_rate
FROM cs
ORDER BY cs.cm;

-- ===========================================================================
-- F7. Monthly GPV, invoices, new customers, repeat-active customers
--     New = first observed eligible purchase month equals current month.
--     Repeat-active = active in month with first observed purchase in an
--     earlier month. GPV/invoices are line-level aggregates over the eligible
--     population. Month status flags the partial start (2010-12) and the
--     truncated end (2011-12).
--     The Nov-2011 peak is a single-year observation; it is not asserted to be
--     a stable seasonal trend.
-- ===========================================================================
WITH elig AS (
  SELECT InvoiceNo, CustomerID, strftime('%Y-%m', InvoiceDate) AS m, gross_purchase_value AS g
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
mm AS (
  SELECT m, ROUND(SUM(g), 2) AS gpv, COUNT(DISTINCT InvoiceNo) AS eligible_invoices
  FROM elig GROUP BY m
),
act AS (
  SELECT DISTINCT CustomerID, m FROM elig
),
first AS (
  SELECT CustomerID, MIN(m) AS fm FROM act GROUP BY CustomerID
),
cm AS (
  SELECT a.m,
         SUM(CASE WHEN a.m =  f.fm THEN 1 ELSE 0 END) AS new_customers,
         SUM(CASE WHEN a.m <> f.fm THEN 1 ELSE 0 END) AS repeat_active_customers,
         COUNT(DISTINCT a.CustomerID)                 AS total_active_customers
  FROM act a JOIN first f ON a.CustomerID = f.CustomerID
  GROUP BY a.m
)
SELECT
  mm.m                                        AS month,
  mm.gpv                                      AS gross_purchase_value,
  mm.eligible_invoices,
  cm.new_customers,
  cm.repeat_active_customers,
  cm.total_active_customers,
  CASE WHEN mm.m = '2010-12' THEN 'partial_start'
       WHEN mm.m = '2011-12' THEN 'truncated_end'
       ELSE 'full' END                        AS month_status
FROM mm JOIN cm ON cm.m = mm.m
ORDER BY mm.m;

-- ===========================================================================
-- F8. Country sensitivity: UK vs non-UK aggregates
--     Aggregates are line/invoice/customer counts over the eligible
--     population. No invoice spans more than one country (verified below), so
--     invoice totals are additive across regions. Customer counts here are
--     per-region DISTINCT counts; 8 customers have eligible transactions in
--     two countries, so customer-level country attribution is not forced and
--     per-region customer counts must not be treated as a partition of
--     individuals without the overlap report below.
-- ===========================================================================
WITH elig AS (
  SELECT InvoiceNo, CustomerID, Country, gross_purchase_value
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
)
SELECT
  CASE WHEN Country = 'United Kingdom' THEN 'UK' ELSE 'non-UK' END AS region,
  COUNT(DISTINCT CustomerID)                                       AS identified_customers,
  COUNT(DISTINCT InvoiceNo)                                        AS eligible_invoices,
  COUNT(*)                                                         AS eligible_lines,
  ROUND(SUM(gross_purchase_value), 2)                              AS gross_purchase_value
FROM elig
GROUP BY region
ORDER BY region;

-- F8b. Multi-country structure (aggregate counts only; no customer IDs)
WITH elig AS (
  SELECT DISTINCT CustomerID, Country
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
per_cust AS (
  SELECT CustomerID,
         COUNT(DISTINCT Country) AS n_countries,
         MAX(CASE WHEN Country  = 'United Kingdom' THEN 1 ELSE 0 END) AS has_uk,
         MAX(CASE WHEN Country <> 'United Kingdom' THEN 1 ELSE 0 END) AS has_non_uk
  FROM elig GROUP BY CustomerID
)
SELECT 'eligible_customers'              AS metric, COUNT(*)                        AS value FROM per_cust
UNION ALL
SELECT 'distinct_customer_country_pairs', (SELECT COUNT(*) FROM elig)
UNION ALL
SELECT 'customers_in_exactly_1_country',  SUM(CASE WHEN n_countries = 1 THEN 1 ELSE 0 END) FROM per_cust
UNION ALL
SELECT 'customers_in_2_countries',        SUM(CASE WHEN n_countries = 2 THEN 1 ELSE 0 END) FROM per_cust
UNION ALL
SELECT 'customers_spanning_UK_and_nonUK', SUM(CASE WHEN has_uk = 1 AND has_non_uk = 1 THEN 1 ELSE 0 END) FROM per_cust
UNION ALL
SELECT 'customers_spanning_2_nonUK',      SUM(CASE WHEN has_uk = 0 AND n_countries = 2 THEN 1 ELSE 0 END) FROM per_cust
UNION ALL
SELECT 'invoices_spanning_2_countries',
       (SELECT COUNT(*) FROM (
          SELECT InvoiceNo FROM prepared_transactions WHERE is_eligible_purchase_line = 1
          GROUP BY InvoiceNo HAVING COUNT(DISTINCT Country) > 1));

-- ===========================================================================
-- F9. Duplicate sensitivity (flagged only; duplicates are NOT deleted and are
--     NOT proven errors). Compares eligible GPV computed over ALL eligible
--     rows vs over eligible rows excluding is_exact_duplicate = 1. The
--     deduplicated figure is a SENSITIVITY view, not "the truth".
--
--     Scope of this check (do not over-read): excluding flagged duplicates
--     changes aggregate eligible GPV from 8,911,407.90 to 8,887,208.89
--     (difference -24,199.01, about -0.27%) and does NOT change the distinct
--     eligible customer count (4,338) or eligible invoice count (18,532).
--     It DOES change per-customer GPV for 951 of 4,338 customers (21.9%), so
--     customer-level Monetary values are affected even though aggregate
--     movement is small. RFM Monetary scores, revenue-concentration metrics,
--     and cohort GPV metrics were NOT re-tested under duplicate exclusion and
--     must not be assumed robust to it.
-- ===========================================================================
WITH e AS (
  SELECT * FROM prepared_transactions WHERE is_eligible_purchase_line = 1
)
SELECT
  ROUND(SUM(gross_purchase_value), 2)                                     AS gpv_all_eligible,
  ROUND(SUM(CASE WHEN is_exact_duplicate = 0 THEN gross_purchase_value END), 2) AS gpv_excluding_flagged_duplicates,
  ROUND(SUM(CASE WHEN is_exact_duplicate = 1 THEN gross_purchase_value END), 2) AS gpv_from_flagged_duplicate_rows,
  ROUND(SUM(gross_purchase_value)
        - SUM(CASE WHEN is_exact_duplicate = 0 THEN gross_purchase_value END), 2) AS gpv_difference,
  ROUND(100.0 * SUM(CASE WHEN is_exact_duplicate = 1 THEN gross_purchase_value END)
        / SUM(gross_purchase_value), 4)                                   AS pct_gpv_from_flagged_duplicates,
  COUNT(*)                                                                AS eligible_lines_all,
  SUM(CASE WHEN is_exact_duplicate = 1 THEN 1 ELSE 0 END)                 AS eligible_lines_flagged_duplicate,
  COUNT(DISTINCT CustomerID)                                              AS eligible_customers_all,
  COUNT(DISTINCT CASE WHEN is_exact_duplicate = 0 THEN CustomerID END)    AS eligible_customers_excluding_flagged,
  COUNT(DISTINCT InvoiceNo)                                               AS eligible_invoices_all,
  COUNT(DISTINCT CASE WHEN is_exact_duplicate = 0 THEN InvoiceNo END)     AS eligible_invoices_excluding_flagged
FROM e;

-- ===========================================================================
-- F10. Validations
-- ===========================================================================

-- V1. GPV reconciliation customer-level vs eligible-line level (diff must be 0).
WITH lines AS (
  SELECT ROUND(SUM(gross_purchase_value), 2) AS gpv
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
cust AS (
  SELECT ROUND(SUM(m), 2) AS gpv
  FROM (SELECT CustomerID, SUM(gross_purchase_value) AS m
        FROM prepared_transactions WHERE is_eligible_purchase_line = 1
        GROUP BY CustomerID)
)
SELECT 'gpv_line_level' AS metric, (SELECT gpv FROM lines) AS value
UNION ALL
SELECT 'gpv_customer_level', (SELECT gpv FROM cust)
UNION ALL
SELECT 'gpv_abs_difference', ROUND(ABS((SELECT gpv FROM lines) - (SELECT gpv FROM cust)), 2);

-- V2. Monthly aggregates reconcile to the eligible population totals.
WITH elig AS (
  SELECT InvoiceNo, CustomerID, strftime('%Y-%m', InvoiceDate) AS m, gross_purchase_value AS g
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
mm AS (SELECT m, ROUND(SUM(g), 2) AS gpv, COUNT(DISTINCT InvoiceNo) AS inv FROM elig GROUP BY m),
act AS (SELECT DISTINCT CustomerID, m FROM elig),
first AS (SELECT CustomerID, MIN(m) AS fm FROM act GROUP BY CustomerID),
cm AS (
  SELECT a.m,
         SUM(CASE WHEN a.m =  f.fm THEN 1 ELSE 0 END) AS new_c,
         SUM(CASE WHEN a.m <> f.fm THEN 1 ELSE 0 END) AS rep_c,
         COUNT(DISTINCT a.CustomerID)                 AS tot_c
  FROM act a JOIN first f ON a.CustomerID = f.CustomerID GROUP BY a.m
),
j AS (SELECT mm.m, mm.gpv, mm.inv, cm.new_c, cm.rep_c, cm.tot_c FROM mm JOIN cm ON cm.m = mm.m)
SELECT 'monthly_gpv_sum' AS metric, ROUND(SUM(gpv), 2) AS value FROM j
UNION ALL
SELECT 'total_eligible_gpv', (SELECT ROUND(SUM(g), 2) FROM elig)
UNION ALL
SELECT 'monthly_invoice_sum', SUM(inv) FROM j
UNION ALL
SELECT 'total_eligible_invoices', (SELECT COUNT(DISTINCT InvoiceNo) FROM elig)
UNION ALL
SELECT 'monthly_new_customers_sum', SUM(new_c) FROM j
UNION ALL
SELECT 'total_eligible_customers', (SELECT COUNT(DISTINCT CustomerID) FROM elig)
UNION ALL
SELECT 'months_where_new_plus_repeat_ne_total', SUM(CASE WHEN new_c + rep_c <> tot_c THEN 1 ELSE 0 END) FROM j
UNION ALL
SELECT 'sum_of_monthly_total_active_not_unique', SUM(tot_c) FROM j;

-- V3. Country aggregates reconcile to the eligible population totals
--     (no invoice spans two countries, so invoice totals are additive).
WITH elig AS (
  SELECT InvoiceNo, CustomerID, Country, gross_purchase_value
  FROM prepared_transactions WHERE is_eligible_purchase_line = 1
),
r AS (
  SELECT CASE WHEN Country = 'United Kingdom' THEN 'UK' ELSE 'non-UK' END AS region,
         COUNT(DISTINCT InvoiceNo) AS inv, COUNT(DISTINCT CustomerID) AS cust,
         ROUND(SUM(gross_purchase_value), 2) AS gpv
  FROM elig GROUP BY region
)
SELECT 'region_gpv_sum' AS metric, ROUND(SUM(gpv), 2) AS value FROM r
UNION ALL
SELECT 'total_eligible_gpv', (SELECT ROUND(SUM(gross_purchase_value), 2) FROM elig)
UNION ALL
SELECT 'region_invoice_sum', SUM(inv) FROM r
UNION ALL
SELECT 'total_eligible_invoices', (SELECT COUNT(DISTINCT InvoiceNo) FROM elig)
UNION ALL
SELECT 'region_customer_sum', SUM(cust) FROM r
UNION ALL
SELECT 'total_eligible_customers', (SELECT COUNT(DISTINCT CustomerID) FROM elig);

-- V4. Percentage denominators used across this file (stated explicitly).
--     * repeat share (F2): denominator = eligible customers (4,338)
--     * concentration (F4): denominator = total eligible GPV
--     * recency pct_of_customers (F5): denominator = eligible customers
--     * recency repeat_share_pct_within_band (F5): denominator = band customers
--     * cohort observed rates (F6): denominator = that cohort's size
SELECT 'repeat_share_denominator_customers' AS metric,
       (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions WHERE is_eligible_purchase_line = 1) AS value
UNION ALL
SELECT 'concentration_denominator_gpv',
       (SELECT ROUND(SUM(gross_purchase_value), 2) FROM prepared_transactions WHERE is_eligible_purchase_line = 1)
UNION ALL
SELECT 'recency_pct_denominator_customers',
       (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions WHERE is_eligible_purchase_line = 1)
UNION ALL
SELECT 'cohort_count_denominators', (SELECT COUNT(DISTINCT cm) FROM (
         SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cm
         FROM prepared_transactions WHERE is_eligible_purchase_line = 1
         GROUP BY CustomerID));
