-- 03_rfm_scoring_diagnostics.sql
-- Read-only diagnostics for RFM scoring decisions against
-- data/processed/customer_retention.sqlite3 (table prepared_transactions).
--
-- This stage does NOT assign RFM scores or segments or cohorts. It
-- characterises distributions for Recency, Frequency, Monetary to
-- support a design decision.

-- D0: sanity checks (split to avoid SQLite WITH-in-UNION edge cases)
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT 'n_customers' AS label, COUNT(*) AS value FROM customer_base;

WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT 'mon_nonneg_count' AS label, COUNT(*) AS value FROM customer_base WHERE monetary > 0;

WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT 'mon_total_reconciles_result' AS label, CASE WHEN ROUND(ABS(
    (SELECT ROUND(SUM(monetary), 2) FROM customer_base) -
    (SELECT ROUND(SUM(gross_purchase_value), 2) FROM prepared_transactions WHERE is_eligible_purchase_line=1)
), 2) < 0.01 THEN 0 ELSE 1 END AS value;

-- D1: Recency distribution and nearest-rank cutpoints (p20,p40,p60,p80)
WITH customer_base AS (
    SELECT CAST(JULIANDAY(date('2011-12-10')) - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
),
ordered AS (
    SELECT recency_days, ROW_NUMBER() OVER (ORDER BY recency_days) AS rn, COUNT(*) OVER () AS n
    FROM customer_base
)
SELECT 'R_p20' AS label, (SELECT MIN(recency_days) FROM ordered WHERE rn = CAST(0.20*n AS INT)+1) AS value
UNION ALL
SELECT 'R_p40', (SELECT MIN(recency_days) FROM ordered WHERE rn = CAST(0.40*n AS INT)+1)
UNION ALL
SELECT 'R_p60', (SELECT MIN(recency_days) FROM ordered WHERE rn = CAST(0.60*n AS INT)+1)
UNION ALL
SELECT 'R_p80', (SELECT MIN(recency_days) FROM ordered WHERE rn = CAST(0.80*n AS INT)+1)
UNION ALL
SELECT 'R_min', MIN(recency_days) FROM ordered
UNION ALL
SELECT 'R_max', MAX(recency_days) FROM ordered
UNION ALL
SELECT 'R_n', n FROM (SELECT DISTINCT n FROM ordered);

-- D1b: Recency bands
WITH customer_base AS (
    SELECT CAST(JULIANDAY(date('2011-12-10')) - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT
    CASE WHEN recency_days <= 15 THEN '1-15d' WHEN recency_days <= 30 THEN '16-30d' WHEN recency_days <= 45 THEN '31-45d'
         WHEN recency_days <= 60 THEN '46-60d' WHEN recency_days <= 90 THEN '61-90d' WHEN recency_days <= 120 THEN '91-120d'
         WHEN recency_days <= 180 THEN '121-180d' ELSE '181-374d' END AS rband,
    COUNT(*) AS customers, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM customer_base), 2) AS pct
FROM customer_base GROUP BY rband ORDER BY MIN(recency_days);

-- D2: Frequency counts and percent (F 1..5, 6+)
WITH customer_base AS (
    SELECT COUNT(DISTINCT InvoiceNo) AS frequency
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT
    CASE WHEN frequency = 1 THEN 'F=1' WHEN frequency = 2 THEN 'F=2' WHEN frequency = 3 THEN 'F=3'
         WHEN frequency = 4 THEN 'F=4' WHEN frequency = 5 THEN 'F=5' ELSE 'F>=6' END AS fband,
    COUNT(*) AS customers, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM customer_base), 2) AS pct,
    MIN(frequency) AS min_f, MAX(frequency) AS max_f
FROM customer_base GROUP BY fband ORDER BY min_f;

-- D2b: Candidate ordinal F scheme
WITH customer_base AS (
    SELECT COUNT(DISTINCT InvoiceNo) AS frequency
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
)
SELECT CASE WHEN frequency = 1 THEN 'one-time' WHEN frequency BETWEEN 2 AND 3 THEN 'low'
            WHEN frequency BETWEEN 4 AND 5 THEN 'medium' ELSE 'high' END AS candidate_band,
       COUNT(*) AS customers, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM customer_base), 2) AS pct
FROM customer_base GROUP BY candidate_band ORDER BY MIN(frequency);

-- D3a: Monetary (raw) cutpoints
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
),
ordered AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base)
SELECT 'M_raw_p20' AS label, MIN(monetary) FILTER (WHERE rn = CAST(0.20*n AS INT)+1) AS value FROM ordered
UNION ALL SELECT 'M_raw_p40', MIN(monetary) FILTER (WHERE rn = CAST(0.40*n AS INT)+1) FROM ordered
UNION ALL SELECT 'M_raw_p60', MIN(monetary) FILTER (WHERE rn = CAST(0.60*n AS INT)+1) FROM ordered
UNION ALL SELECT 'M_raw_p80', MIN(monetary) FILTER (WHERE rn = CAST(0.80*n AS INT)+1) FROM ordered
UNION ALL SELECT 'M_raw_min', MIN(monetary) FROM ordered
UNION ALL SELECT 'M_raw_max', MAX(monetary) FROM ordered
UNION ALL SELECT 'M_raw_n', n FROM (SELECT DISTINCT n FROM ordered);

-- D3b: Monetary (raw) bands
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
),
ordered AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts AS (SELECT (SELECT MIN(monetary) FROM ordered WHERE rn = CAST(0.20*n AS INT)+1) AS p20,
                (SELECT MIN(monetary) FROM ordered WHERE rn = CAST(0.40*n AS INT)+1) AS p40,
                (SELECT MIN(monetary) FROM ordered WHERE rn = CAST(0.60*n AS INT)+1) AS p60,
                (SELECT MIN(monetary) FROM ordered WHERE rn = CAST(0.80*n AS INT)+1) AS p80 FROM ordered LIMIT 1)
SELECT CASE WHEN monetary <= (SELECT p20 FROM cpts) THEN 'r1 (<=p20)' WHEN monetary <= (SELECT p40 FROM cpts) THEN 'r2 (<=p40)'
            WHEN monetary <= (SELECT p60 FROM cpts) THEN 'r3 (<=p60)' WHEN monetary <= (SELECT p80 FROM cpts) THEN 'r4 (<=p80)' ELSE 'r5 (>p80)' END AS mband,
       COUNT(*) AS customers, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM customer_base), 2) AS pct,
       MIN(monetary) AS min_m, MAX(monetary) AS max_m
FROM customer_base, cpts GROUP BY mband ORDER BY MIN(monetary);

-- D4a: Monetary (LN) cutpoints
WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
),
ordered AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base)
SELECT 'M_log_p20' AS label, MIN(monetary_log) FILTER (WHERE rn = CAST(0.20*n AS INT)+1) AS value FROM ordered
UNION ALL SELECT 'M_log_p40', MIN(monetary_log) FILTER (WHERE rn = CAST(0.40*n AS INT)+1) FROM ordered
UNION ALL SELECT 'M_log_p60', MIN(monetary_log) FILTER (WHERE rn = CAST(0.60*n AS INT)+1) FROM ordered
UNION ALL SELECT 'M_log_p80', MIN(monetary_log) FILTER (WHERE rn = CAST(0.80*n AS INT)+1) FROM ordered;

-- D4b: Monetary (LN) bands
WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log, ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
),
ordered AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts AS (SELECT (SELECT MIN(monetary_log) FROM ordered WHERE rn = CAST(0.20*n AS INT)+1) AS lp20,
                (SELECT MIN(monetary_log) FROM ordered WHERE rn = CAST(0.40*n AS INT)+1) AS lp40,
                (SELECT MIN(monetary_log) FROM ordered WHERE rn = CAST(0.60*n AS INT)+1) AS lp60,
                (SELECT MIN(monetary_log) FROM ordered WHERE rn = CAST(0.80*n AS INT)+1) AS lp80 FROM ordered LIMIT 1)
SELECT CASE WHEN monetary_log <= (SELECT lp20 FROM cpts) THEN 'l1 (<=lp20)' WHEN monetary_log <= (SELECT lp40 FROM cpts) THEN 'l2 (<=lp40)'
            WHEN monetary_log <= (SELECT lp60 FROM cpts) THEN 'l3 (<=lp60)' WHEN monetary_log <= (SELECT lp80 FROM cpts) THEN 'l4 (<=lp80)' ELSE 'l5 (>lp80)' END AS mband_log,
       COUNT(*) AS customers, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM customer_base), 2) AS pct,
       ROUND(MIN(monetary), 2) AS min_m_raw, ROUND(MAX(monetary), 2) AS max_m_raw
FROM customer_base, cpts GROUP BY mband_log ORDER BY MIN(monetary_log);

-- D5a: Equality checks raw
WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_m AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_m AS (SELECT (SELECT MIN(monetary) FROM ordered_m WHERE rn = CAST(0.20*n AS INT)+1) AS p20 FROM ordered_m LIMIT 1)
SELECT 'raw_p20_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_m WHERE monetary = (SELECT p20 FROM cpts_m);

WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_m AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_m AS (SELECT (SELECT MIN(monetary) FROM ordered_m WHERE rn = CAST(0.40*n AS INT)+1) AS p40 FROM ordered_m LIMIT 1)
SELECT 'raw_p40_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_m WHERE monetary = (SELECT p40 FROM cpts_m);

WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_m AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_m AS (SELECT (SELECT MIN(monetary) FROM ordered_m WHERE rn = CAST(0.60*n AS INT)+1) AS p60 FROM ordered_m LIMIT 1)
SELECT 'raw_p60_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_m WHERE monetary = (SELECT p60 FROM cpts_m);

WITH customer_base AS (
    SELECT ROUND(SUM(gross_purchase_value), 2) AS monetary
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_m AS (SELECT monetary, ROW_NUMBER() OVER (ORDER BY monetary) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_m AS (SELECT (SELECT MIN(monetary) FROM ordered_m WHERE rn = CAST(0.80*n AS INT)+1) AS p80 FROM ordered_m LIMIT 1)
SELECT 'raw_p80_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_m WHERE monetary = (SELECT p80 FROM cpts_m);

-- D5b: Equality checks log
WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_l AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_l AS (SELECT (SELECT MIN(monetary_log) FROM ordered_l WHERE rn = CAST(0.20*n AS INT)+1) AS lp20 FROM ordered_l LIMIT 1)
SELECT 'log_p20_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_l WHERE monetary_log = (SELECT lp20 FROM cpts_l);

WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_l AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_l AS (SELECT (SELECT MIN(monetary_log) FROM ordered_l WHERE rn = CAST(0.40*n AS INT)+1) AS lp40 FROM ordered_l LIMIT 1)
SELECT 'log_p40_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_l WHERE monetary_log = (SELECT lp40 FROM cpts_l);

WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_l AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_l AS (SELECT (SELECT MIN(monetary_log) FROM ordered_l WHERE rn = CAST(0.60*n AS INT)+1) AS lp60 FROM ordered_l LIMIT 1)
SELECT 'log_p60_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_l WHERE monetary_log = (SELECT lp60 FROM cpts_l);

WITH customer_base AS (
    SELECT LN(SUM(gross_purchase_value)) AS monetary_log
    FROM prepared_transactions WHERE is_eligible_purchase_line = 1 GROUP BY CustomerID
), ordered_l AS (SELECT monetary_log, ROW_NUMBER() OVER (ORDER BY monetary_log) AS rn, COUNT(*) OVER () AS n FROM customer_base),
cpts_l AS (SELECT (SELECT MIN(monetary_log) FROM ordered_l WHERE rn = CAST(0.80*n AS INT)+1) AS lp80 FROM ordered_l LIMIT 1)
SELECT 'log_p80_eq_count' AS label, COUNT(*) AS value FROM customer_base, cpts_l WHERE monetary_log = (SELECT lp80 FROM cpts_l);
