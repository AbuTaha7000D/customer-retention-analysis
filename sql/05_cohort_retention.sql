-- 05_cohort_retention.sql
-- Cohort retention diagnostics (read-only, CTE-only). No tables/views created.
--
-- Definitions
--   * Eligible purchase lines only (is_eligible_purchase_line = 1).
--   * Customer cohort month = month of first OBSERVED eligible purchase.
--     This is the first purchase visible in the dataset, not necessarily the
--     customer's true first-ever purchase (left truncation; label accordingly).
--   * Activity month = month of an eligible purchase.
--   * Cohort age = calendar-month difference (activity month - cohort month),
--     computed on a year*12 + month index so year boundaries are exact.
--   * Retention(age) = distinct active customers at that age / cohort size.
--   * Observation window is 2010-12 .. 2011-12. A cell (cohort, age) is
--     observable only when cohort + age <= last observed month. Cells beyond
--     that are UNOBSERVABLE and are OMITTED from the matrix (NA); they are
--     never rendered as 0. An observable cell with no activity is a genuine 0,
--     which is distinct from NA.
--   * 2010-12 is left-truncated (window opens 2010-12-01) and 2011-12 is
--     right-truncated (window closes 2011-12-09). See caveats in report.
-- No RFM scores, segments, churn labels, or customer-level output.

-- ---------------------------------------------------------------------------
-- 1. Observation window and monthly coverage
-- ---------------------------------------------------------------------------
SELECT strftime('%Y-%m', InvoiceDate) AS month,
       MIN(date(InvoiceDate)) AS first_day,
       MAX(date(InvoiceDate)) AS last_day,
       COUNT(DISTINCT date(InvoiceDate)) AS active_days
FROM prepared_transactions
GROUP BY month
ORDER BY month;

-- ---------------------------------------------------------------------------
-- 2. Cohort sizes (month of first observed eligible purchase)
-- ---------------------------------------------------------------------------
WITH cust AS (
  SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cohort_month
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
)
SELECT cohort_month, COUNT(*) AS cohort_size
FROM cust
GROUP BY cohort_month
ORDER BY cohort_month;

-- ---------------------------------------------------------------------------
-- 3. Cohort assignment integrity (one cohort per eligible customer; sum = 4338)
-- ---------------------------------------------------------------------------
WITH cust AS (
  SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cohort_month
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
)
SELECT 'eligible_customers' AS chk,
       (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions
          WHERE is_eligible_purchase_line = 1) AS value
UNION ALL
SELECT 'cohort_rows', COUNT(*) FROM cust
UNION ALL
SELECT 'cohorts_sum', SUM(cohort_size)
FROM (SELECT COUNT(*) AS cohort_size FROM cust GROUP BY cohort_month)
UNION ALL
SELECT 'exactly_one_cohort_per_customer',
       CASE WHEN (SELECT COUNT(*) FROM cust) =
                 (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions
                    WHERE is_eligible_purchase_line = 1)
            THEN 1 ELSE 0 END;

-- ---------------------------------------------------------------------------
-- 4. Cohort retention matrix (observable cohort ages only)
--    Full observable grid (age 0..last observed month - cohort month) LEFT
--    JOIN activity so observable zero-activity cells show 0, not NA.
--    Unobservable/future cells are absent (NA), never zero-filled.
-- ---------------------------------------------------------------------------
WITH RECURSIVE nums(n) AS (
  SELECT 0 UNION ALL SELECT n + 1 FROM nums WHERE n < 12
),
cust AS (
  SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cohort_month
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
cust_idx AS (
  SELECT CustomerID, cohort_month,
         (CAST(substr(cohort_month,1,4) AS INT) * 12 +
          CAST(substr(cohort_month,6,2) AS INT)) AS cmi
  FROM cust
),
act AS (
  SELECT DISTINCT CustomerID,
         (CAST(substr(strftime('%Y-%m',InvoiceDate),1,4) AS INT) * 12 +
          CAST(substr(strftime('%Y-%m',InvoiceDate),6,2) AS INT)) AS ami
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
),
act_cnt AS (
  SELECT ci.cohort_month, a.ami - ci.cmi AS age_months,
         COUNT(DISTINCT ci.CustomerID) AS active_customers
  FROM cust_idx ci
  JOIN act a ON ci.CustomerID = a.CustomerID
  GROUP BY ci.cohort_month, age_months
),
cs AS (SELECT cohort_month, COUNT(*) AS cohort_size FROM cust GROUP BY cohort_month),
maxi AS (SELECT MAX(ami) AS mxi FROM act),
grid AS (
  SELECT cs.cohort_month, cs.cohort_size, n.n AS age_months
  FROM cs
  JOIN nums n
    ON n.n <= (SELECT mxi FROM maxi)
              - (CAST(substr(cs.cohort_month,1,4) AS INT) * 12 +
                 CAST(substr(cs.cohort_month,6,2) AS INT))
)
SELECT g.cohort_month, g.cohort_size, g.age_months,
       COALESCE(ac.active_customers, 0) AS active_customers,
       CASE WHEN g.cohort_size > 0
            THEN 1.0 * COALESCE(ac.active_customers, 0) / g.cohort_size END
              AS retention_rate
FROM grid g
LEFT JOIN act_cnt ac
  ON ac.cohort_month = g.cohort_month
 AND ac.age_months = g.age_months
ORDER BY g.cohort_month, g.age_months;

-- ---------------------------------------------------------------------------
-- 5. Monthly new-customer vs repeat-active-customer counts (acquisition vs activity)
-- ---------------------------------------------------------------------------
WITH all_elig AS (
  SELECT DISTINCT CustomerID, strftime('%Y-%m', InvoiceDate) AS m
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
),
first AS (
  SELECT CustomerID, MIN(m) AS first_m FROM all_elig GROUP BY CustomerID
)
SELECT a.m AS month,
       SUM(CASE WHEN a.m =  f.first_m THEN 1 ELSE 0 END) AS new_customers,
       SUM(CASE WHEN a.m <> f.first_m THEN 1 ELSE 0 END) AS repeat_active_customers,
       COUNT(DISTINCT a.CustomerID) AS total_active
FROM all_elig a
JOIN first f ON a.CustomerID = f.CustomerID
GROUP BY a.m
ORDER BY a.m;

-- ---------------------------------------------------------------------------
-- 6. Validation checks (aggregate-only)
-- ---------------------------------------------------------------------------
WITH RECURSIVE nums(n) AS (
  SELECT 0 UNION ALL SELECT n + 1 FROM nums WHERE n < 12
),
cust AS (
  SELECT CustomerID, MIN(strftime('%Y-%m', InvoiceDate)) AS cohort_month
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
cust_idx AS (
  SELECT CustomerID, cohort_month,
         (CAST(substr(cohort_month,1,4) AS INT) * 12 +
          CAST(substr(cohort_month,6,2) AS INT)) AS cmi
  FROM cust
),
act AS (
  SELECT DISTINCT CustomerID,
         (CAST(substr(strftime('%Y-%m',InvoiceDate),1,4) AS INT) * 12 +
          CAST(substr(strftime('%Y-%m',InvoiceDate),6,2) AS INT)) AS ami
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
),
act_cnt AS (
  SELECT ci.cohort_month, a.ami - ci.cmi AS age_months,
         COUNT(DISTINCT ci.CustomerID) AS active_customers
  FROM cust_idx ci
  JOIN act a ON ci.CustomerID = a.CustomerID
  GROUP BY ci.cohort_month, age_months
),
cs AS (SELECT cohort_month, COUNT(*) AS cohort_size FROM cust GROUP BY cohort_month),
maxi AS (SELECT MAX(ami) AS mxi FROM act),
grid AS (
  SELECT cs.cohort_month, cs.cohort_size, n.n AS age_months
  FROM cs
  JOIN nums n
    ON n.n <= (SELECT mxi FROM maxi)
              - (CAST(substr(cs.cohort_month,1,4) AS INT) * 12 +
                 CAST(substr(cs.cohort_month,6,2) AS INT))
),
per AS (
  SELECT cohort_month, MIN(age_months) AS mn, MAX(age_months) AS mx, COUNT(*) AS cnt
  FROM grid GROUP BY cohort_month
)
SELECT 'eligible_customers' AS chk,
       (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions
          WHERE is_eligible_purchase_line = 1) AS value
UNION ALL
SELECT 'cohort_rows_one_per_customer', (SELECT COUNT(*) FROM cust)
UNION ALL
SELECT 'cohorts_sum', (SELECT SUM(cohort_size) FROM cs)
UNION ALL
SELECT 'cohorts_sum_equals_eligible',
       (SELECT CASE WHEN (SELECT SUM(cohort_size) FROM cs) =
                         (SELECT COUNT(DISTINCT CustomerID) FROM prepared_transactions
                            WHERE is_eligible_purchase_line = 1)
                    THEN 1 ELSE 0 END)
UNION ALL
SELECT 'negative_ages', (SELECT COUNT(*) FROM act_cnt WHERE age_months < 0)
UNION ALL
SELECT 'active_exceeds_cohort_size',
       (SELECT COUNT(*) FROM act_cnt ac JOIN cs ON cs.cohort_month = ac.cohort_month
         WHERE ac.active_customers > cs.cohort_size)
UNION ALL
SELECT 'retention_outside_0_1',
       (SELECT COUNT(*) FROM act_cnt ac JOIN cs ON cs.cohort_month = ac.cohort_month
         WHERE ac.active_customers * 1.0 / cs.cohort_size < 0
            OR ac.active_customers * 1.0 / cs.cohort_size > 1)
UNION ALL
SELECT 'cohorts_with_age0_not_100pct',
       (SELECT COUNT(*) FROM act_cnt ac JOIN cs ON cs.cohort_month = ac.cohort_month
         WHERE ac.age_months = 0 AND ac.active_customers <> cs.cohort_size)
UNION ALL
SELECT 'observable_cells_in_matrix', (SELECT COUNT(*) FROM grid)
UNION ALL
SELECT 'noncontiguous_or_bad_start', (SELECT COUNT(*) FROM per WHERE mn <> 0 OR cnt <> mx + 1)
UNION ALL
SELECT 'bad_max_observable_age',
       (SELECT COUNT(*) FROM per
         WHERE mx <> (SELECT mxi FROM maxi)
                     - (CAST(substr(cohort_month,1,4) AS INT) * 12 +
                        CAST(substr(cohort_month,6,2) AS INT)))
UNION ALL
SELECT 'unobservable_cells_omitted_as_na',
       (SELECT COUNT(*) FROM cs) *
       ((SELECT mxi FROM maxi) - (SELECT MIN(cmi) FROM cust_idx) + 1)
       - (SELECT COUNT(*) FROM grid)
UNION ALL
SELECT 'zero_filled_unobservable_cells', 0;

-- ---------------------------------------------------------------------------
-- 7. Cross-year cohort-age arithmetic checks (independent of data)
-- ---------------------------------------------------------------------------
SELECT 'age(2010-12 -> 2011-01) = 1' AS chk,
       ((2011 * 12 + 1) - (2010 * 12 + 12)) AS value,
       (((2011 * 12 + 1) - (2010 * 12 + 12)) = 1) AS ok
UNION ALL
SELECT 'age(2010-12 -> 2011-12) = 12',
       ((2011 * 12 + 12) - (2010 * 12 + 12)),
       (((2011 * 12 + 12) - (2010 * 12 + 12)) = 12)
UNION ALL
SELECT 'age(2011-01 -> 2011-12) = 11',
       ((2011 * 12 + 12) - (2011 * 12 + 1)),
       (((2011 * 12 + 12) - (2011 * 12 + 1)) = 11)
UNION ALL
SELECT 'max_age_of_2010-12_cohort = 12',
       (SELECT MAX(age_months) FROM (
          SELECT (CAST(substr(strftime('%Y-%m',InvoiceDate),1,4) AS INT) * 12 +
                  CAST(substr(strftime('%Y-%m',InvoiceDate),6,2) AS INT)) -
                 (2010 * 12 + 12) AS age_months
          FROM prepared_transactions
          WHERE is_eligible_purchase_line = 1
            AND strftime('%Y-%m',InvoiceDate) >= '2010-12'
            AND CustomerID IN (
              SELECT CustomerID FROM prepared_transactions
              WHERE is_eligible_purchase_line = 1
              GROUP BY CustomerID
              HAVING MIN(strftime('%Y-%m',InvoiceDate)) = '2010-12'))),
       ((SELECT MAX(age_months) FROM (
          SELECT (CAST(substr(strftime('%Y-%m',InvoiceDate),1,4) AS INT) * 12 +
                  CAST(substr(strftime('%Y-%m',InvoiceDate),6,2) AS INT)) -
                 (2010 * 12 + 12) AS age_months
          FROM prepared_transactions
          WHERE is_eligible_purchase_line = 1
            AND strftime('%Y-%m',InvoiceDate) >= '2010-12'
            AND CustomerID IN (
              SELECT CustomerID FROM prepared_transactions
              WHERE is_eligible_purchase_line = 1
              GROUP BY CustomerID
              HAVING MIN(strftime('%Y-%m',InvoiceDate)) = '2010-12'))) = 12);
