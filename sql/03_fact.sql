-- 03_fact.sql
-- What: builds fact_state_product_year - one row per year x state x product with
--       total claims, standardized 30-day fills and gross drug cost.
-- Why:  this is the single source for every analysis and for Power BI. Everything
--       else is a sum or a ratio of these three numbers.
--
-- Which raw rows are used:
-- * Prscrbr_Geo_Lvl = 'State' with a FIPS code from 1 to 56 = the 50 states + DC.
--   Territories (e.g. 72 Puerto Rico), armed forces (9A-9C), unknown (9D), foreign
--   (9E) and the one blank-code row are left out. TRY_CAST turns codes like '9A' into
--   NULL, and NULL is never "between 1 and 56", so those rows drop out automatically.
-- * The row's generic name must match a market molecule stem AND its brand must join
--   to dim_product on brand_key. Both conditions together mean a brand that shares a
--   name with an unrelated drug can never get in.
--
-- Numbers: TRY_CAST converts text to a number and gives NULL (instead of an error) when
-- it can't; COALESCE(..., 0) then counts blanks as 0. Claims are whole numbers (BIGINT);
-- fills and cost have decimals (DOUBLE). Tot_Drug_Cst is GROSS cost, before rebates.
-- Tot_Prscrbrs and Tot_Benes are deliberately not used: the same person is counted
-- under several drugs, so they can't be added up across products.

CREATE OR REPLACE TABLE fact_state_product_year AS
SELECT
    r.data_year,
    lpad(trim(r.Prscrbr_Geo_Cd), 2, '0')                               AS state_fips,
    max(trim(r.Prscrbr_Geo_Desc))                                      AS state_name,
    d.product_id,
    CAST(sum(coalesce(TRY_CAST(r.Tot_Clms        AS BIGINT), 0)) AS BIGINT) AS total_claims,
    sum(coalesce(TRY_CAST(r.Tot_30day_Fills AS DOUBLE), 0))            AS total_30day_fills,
    sum(coalesce(TRY_CAST(r.Tot_Drug_Cst    AS DOUBLE), 0))            AS total_drug_cost
FROM raw_geo_drug AS r
JOIN dim_product  AS d
  ON lower(trim(r.Brnd_Name)) = d.brand_key
WHERE r.Prscrbr_Geo_Lvl = 'State'
  AND TRY_CAST(r.Prscrbr_Geo_Cd AS INTEGER) BETWEEN 1 AND 56
  AND is_market_molecule(r.Gnrc_Name)
-- GROUP BY guarantees exactly one row per year / state / product
GROUP BY r.data_year, lpad(trim(r.Prscrbr_Geo_Cd), 2, '0'), d.product_id
ORDER BY r.data_year, state_fips, d.product_id;
