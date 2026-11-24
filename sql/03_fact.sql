-- 03_fact.sql
-- What: defines WHICH raw rows the analysis uses (two views), then builds
--       fact_state_product_year - one row per year x state x product with total
--       claims, standardized 30-day fills and gross drug cost.
-- Why:  the fact table is the single source for every analysis and for Power BI.
--       The row-selection rules are written once here, as views, and 05_validation.sql
--       reuses the same views, so the checks always test exactly the rows the fact
--       table is built from and the two can't drift apart.


-- in_market_raw_rows: raw rows of in-market products, at ANY geography level.
-- A row counts only if its generic name matches a market molecule stem AND its brand
-- joins to dim_product on brand_key. Both conditions together mean a brand that
-- shares a name with an unrelated drug can never get in.
-- (Used by the fact table below and by the reconciliation in 05.)
CREATE OR REPLACE VIEW in_market_raw_rows AS
SELECT
    r.*,
    d.brand_key,
    d.product_id
FROM raw_geo_drug AS r
JOIN dim_product  AS d
  ON lower(trim(r.Brnd_Name)) = d.brand_key
WHERE is_market_molecule(r.Gnrc_Name);


-- fact_source_rows: the in-market rows for the 50 states + DC only.
-- Prscrbr_Geo_Lvl = 'State' with a FIPS code from 1 to 56. Territories (e.g. 72 Puerto
-- Rico), armed forces (9A-9C), unknown (9D), foreign (9E) and blank codes are left out:
-- TRY_CAST turns codes like '9A' into NULL, and NULL is never "between 1 and 56".
CREATE OR REPLACE VIEW fact_source_rows AS
SELECT *
FROM in_market_raw_rows
WHERE Prscrbr_Geo_Lvl = 'State'
  AND TRY_CAST(trim(Prscrbr_Geo_Cd) AS INTEGER) BETWEEN 1 AND 56;


-- The fact table.
-- Numbers: TRY_CAST converts text to a number and gives NULL (instead of an error) when
-- it can't; COALESCE(..., 0) then counts blanks as 0. Claims are whole numbers (BIGINT);
-- fills and cost have decimals (DOUBLE). Tot_Drug_Cst is GROSS cost, before rebates.
-- Tot_Prscrbrs and Tot_Benes are deliberately not used: the same person is counted
-- under several drugs, so they can't be added up across products.
CREATE OR REPLACE TABLE fact_state_product_year AS
SELECT
    data_year,
    lpad(trim(Prscrbr_Geo_Cd), 2, '0')                                 AS state_fips,
    max(trim(Prscrbr_Geo_Desc))                                        AS state_name,
    product_id,
    CAST(sum(coalesce(TRY_CAST(Tot_Clms        AS BIGINT), 0)) AS BIGINT) AS total_claims,
    sum(coalesce(TRY_CAST(Tot_30day_Fills AS DOUBLE), 0))              AS total_30day_fills,
    sum(coalesce(TRY_CAST(Tot_Drug_Cst    AS DOUBLE), 0))              AS total_drug_cost
FROM fact_source_rows
-- GROUP BY guarantees exactly one row per year / state / product
GROUP BY data_year, lpad(trim(Prscrbr_Geo_Cd), 2, '0'), product_id
ORDER BY data_year, state_fips, product_id;
