-- 04_rfm_scoring.sql
-- Read-only RFM scoring implementation using documented methodology
-- No tables/views created; all SELECT-only. No customer-level detail output.

-- D0: base + validation. Note: each score CASE has ELSE 0, so scores are
-- never NULL; genuine missing-score counts are reported as *_missing, while
-- in-range scores are counted by r_valid/f_valid/m_valid.
WITH customer_base AS (
  SELECT
    CAST(JULIANDAY(date('2011-12-10')) - JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days,
    COUNT(DISTINCT InvoiceNo) AS frequency,
    ROUND(SUM(gross_purchase_value), 2) AS monetary
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
),
scored AS (
  SELECT
    recency_days,
    frequency,
    monetary,
    CASE
      WHEN recency_days <= 13 THEN 5
      WHEN recency_days <= 33 THEN 4
      WHEN recency_days <= 72 THEN 3
      WHEN recency_days <= 180 THEN 2
      WHEN recency_days > 180 THEN 1
      ELSE 0
    END AS r_score,
    CASE
      WHEN frequency == 1 THEN 1
      WHEN frequency == 2 OR frequency == 3 THEN 2
      WHEN frequency == 4 OR frequency == 5 THEN 3
      WHEN frequency >= 6 THEN 4
      ELSE 0
    END AS f_score,
    CASE
      WHEN monetary <= 250.15 THEN 1
      WHEN monetary <= 490.22 THEN 2
      WHEN monetary <= 942.26 THEN 3
      WHEN monetary <= 2059.45 THEN 4
      WHEN monetary > 2059.45 THEN 5
      ELSE 0
    END AS m_score
  FROM customer_base
),
checks AS (
  SELECT
    COUNT(*) AS n_customers,
    SUM(CASE WHEN r_score IS NULL THEN 1 ELSE 0 END) AS n_r_missing,
    SUM(CASE WHEN f_score IS NULL THEN 1 ELSE 0 END) AS n_f_missing,
    SUM(CASE WHEN m_score IS NULL THEN 1 ELSE 0 END) AS n_m_missing,
    SUM(CASE WHEN r_score BETWEEN 1 AND 5 THEN 1 ELSE 0 END) AS r_valid,
    SUM(CASE WHEN f_score BETWEEN 1 AND 4 THEN 1 ELSE 0 END) AS f_valid,
    SUM(CASE WHEN m_score BETWEEN 1 AND 5 THEN 1 ELSE 0 END) AS m_valid,
    SUM(CASE WHEN monetary > 0 THEN 1 ELSE 0 END) AS mon_pos,
    (SELECT ROUND(ABS(SUM(monetary) - (SELECT ROUND(SUM(gross_purchase_value),2) FROM prepared_transactions WHERE is_eligible_purchase_line=1)),2)
       FROM scored) AS mon_recon
  FROM scored
)
SELECT * FROM checks;

-- D1: band counts (aggregate only)
WITH customer_base AS (
  SELECT CAST(JULIANDAY(date('2011-12-10'))-JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days,
         COUNT(DISTINCT InvoiceNo) AS frequency, ROUND(SUM(gross_purchase_value),2) AS monetary
  FROM prepared_transactions WHERE is_eligible_purchase_line=1 GROUP BY CustomerID
),
scored AS (
  SELECT recency_days, frequency, monetary,
    CASE WHEN recency_days <=13 THEN 5 WHEN recency_days <=33 THEN 4 WHEN recency_days <=72 THEN 3 WHEN recency_days <=180 THEN 2 ELSE 1 END AS r_score,
    CASE WHEN frequency==1 THEN 1 WHEN frequency==2 OR frequency==3 THEN 2 WHEN frequency==4 OR frequency==5 THEN 3 ELSE 4 END AS f_score,
    CASE WHEN monetary <=250.15 THEN 1 WHEN monetary <=490.22 THEN 2 WHEN monetary <=942.26 THEN 3 WHEN monetary <=2059.45 THEN 4 ELSE 5 END AS m_score
  FROM customer_base
)
SELECT 'r1' AS band, COUNT(*) AS count FROM scored WHERE r_score=1
UNION ALL SELECT 'r2', COUNT(*) FROM scored WHERE r_score=2
UNION ALL SELECT 'r3', COUNT(*) FROM scored WHERE r_score=3
UNION ALL SELECT 'r4', COUNT(*) FROM scored WHERE r_score=4
UNION ALL SELECT 'r5', COUNT(*) FROM scored WHERE r_score=5
UNION ALL SELECT 'f1', COUNT(*) FROM scored WHERE f_score=1
UNION ALL SELECT 'f2', COUNT(*) FROM scored WHERE f_score=2
UNION ALL SELECT 'f3', COUNT(*) FROM scored WHERE f_score=3
UNION ALL SELECT 'f4', COUNT(*) FROM scored WHERE f_score=4
UNION ALL SELECT 'm1', COUNT(*) FROM scored WHERE m_score=1
UNION ALL SELECT 'm2', COUNT(*) FROM scored WHERE m_score=2
UNION ALL SELECT 'm3', COUNT(*) FROM scored WHERE m_score=3
UNION ALL SELECT 'm4', COUNT(*) FROM scored WHERE m_score=4
UNION ALL SELECT 'm5', COUNT(*) FROM scored WHERE m_score=5;

-- D2: boundary equality checks
WITH customer_base AS (
  SELECT CAST(JULIANDAY(date('2011-12-10'))-JULIANDAY(date(MAX(InvoiceDate))) AS INTEGER) AS recency_days,
         ROUND(SUM(gross_purchase_value),2) AS monetary
  FROM prepared_transactions WHERE is_eligible_purchase_line=1 GROUP BY CustomerID
)
SELECT 'r_bound13_eq' AS k, COUNT(*) AS val FROM customer_base WHERE recency_days==13
UNION ALL SELECT 'r_bound33_eq', COUNT(*) FROM customer_base WHERE recency_days==33
UNION ALL SELECT 'r_bound72_eq', COUNT(*) FROM customer_base WHERE recency_days==72
UNION ALL SELECT 'r_bound180_eq', COUNT(*) FROM customer_base WHERE recency_days==180
UNION ALL SELECT 'm_bound250.15_eq', COUNT(*) FROM customer_base WHERE monetary==250.15
UNION ALL SELECT 'm_bound490.22_eq', COUNT(*) FROM customer_base WHERE monetary==490.22
UNION ALL SELECT 'm_bound942.26_eq', COUNT(*) FROM customer_base WHERE monetary==942.26
UNION ALL SELECT 'm_bound2059.45_eq', COUNT(*) FROM customer_base WHERE monetary==2059.45;
