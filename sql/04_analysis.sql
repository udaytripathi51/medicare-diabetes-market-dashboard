-- 04_analysis.sql
-- What: one view per business question (Q1-Q5). A view is a saved query: it stores
--       no data of its own and always recalculates from the fact table.
-- Why:  keeping each answer as a named view makes it easy to check, export and explain.
--
-- Shared rules:
-- * "National" here = the sum of the 50 states + DC in the fact table.
-- * Shares use claims (Tot_Clms). Cost per fill uses standardized 30-day fills.
-- * Shares are percentages (0-100). Values are kept at full precision here; rounding
--   happens only when exporting (06_export.sql).


-- Q1. How did each drug class's share of claims change from 2019 to 2024?
-- Window functions do a calculation across related rows without collapsing them:
-- SUM() OVER (PARTITION BY data_year) = the whole market's claims in that row's year;
-- LAG() OVER (... ORDER BY data_year) = the same class's share in the previous year.
CREATE OR REPLACE VIEW q1_class_share_by_year AS
WITH class_year AS (
    SELECT
        f.data_year,
        d.drug_class,
        CAST(sum(f.total_claims) AS BIGINT) AS claims
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year, d.drug_class
),
with_share AS (
    SELECT
        data_year,
        drug_class,
        claims,
        100.0 * claims / sum(claims) OVER (PARTITION BY data_year) AS share_pct
    FROM class_year
),
with_change AS (
    SELECT
        data_year,
        drug_class,
        claims,
        share_pct,
        -- percentage-point change; NULL in 2019 because there is no prior year
        share_pct - LAG(share_pct) OVER (PARTITION BY drug_class ORDER BY data_year)
            AS change_vs_prior_year_pp
    FROM with_share
)
SELECT *
FROM with_change
ORDER BY data_year, drug_class;


-- Q2. How did the Januvia family (Januvia, Janumet, Janumet XR) perform, by year?
-- Two shares: of the whole market, and of the 'DPP-4' class only (the
-- 'DPP-4 + SGLT2 combo' class is not in that denominator).
-- SUM(CASE WHEN ... THEN claims ELSE 0 END) adds up only the rows that meet a condition.
CREATE OR REPLACE VIEW q2_januvia_family AS
WITH by_year AS (
    SELECT
        f.data_year,
        sum(CASE WHEN d.januvia_family = 1  THEN f.total_claims ELSE 0 END) AS family_claims,
        sum(CASE WHEN d.drug_class = 'DPP-4' THEN f.total_claims ELSE 0 END) AS dpp4_claims,
        sum(f.total_claims)                                                  AS market_claims
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year
)
SELECT
    data_year,
    CAST(family_claims AS BIGINT)                     AS claims,
    100.0 * family_claims / market_claims             AS share_of_market_pct,
    100.0 * family_claims / NULLIF(dpp4_claims, 0)    AS share_of_dpp4_pct
FROM by_year
ORDER BY data_year;


-- Q3. In 2024, which states over- or under-index on GLP-1 share vs the national level?
-- glp1_index = state GLP-1 share / national GLP-1 share x 100
--   (100 = same as national, 120 = 20% higher, 80 = 20% lower).
-- The national share is computed once (CTE "national") and attached to every state
-- with CROSS JOIN. RANK() numbers the states from highest index (1) down.
-- A state here is where the prescriber practises, not where the patient lives.
CREATE OR REPLACE VIEW q3_state_glp1_index_2024 AS
WITH state_totals AS (
    SELECT
        f.state_fips,
        max(f.state_name)                                                    AS state_name,
        sum(CASE WHEN d.drug_class = 'GLP-1' THEN f.total_claims ELSE 0 END) AS glp1_claims,
        sum(f.total_claims)                                                  AS market_claims
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    WHERE f.data_year = 2024
    GROUP BY f.state_fips
),
national AS (
    SELECT 100.0 * sum(glp1_claims) / sum(market_claims) AS national_glp1_share_pct
    FROM state_totals
),
state_share AS (
    SELECT
        s.state_name,
        100.0 * s.glp1_claims / s.market_claims AS glp1_share_pct,
        n.national_glp1_share_pct
    FROM state_totals AS s
    CROSS JOIN national AS n
)
SELECT
    state_name,
    glp1_share_pct,
    national_glp1_share_pct,
    100.0 * glp1_share_pct / national_glp1_share_pct           AS glp1_index,
    RANK() OVER (ORDER BY glp1_share_pct / national_glp1_share_pct DESC) AS "rank"
FROM state_share
ORDER BY "rank";


-- Q4. What is the gross cost per standardized 30-day fill, by class and year?
-- Gross cost = Tot_Drug_Cst, before manufacturer rebates. UNION ALL stacks an extra
-- 'All classes' row under each year's class rows. NULLIF(x, 0) avoids dividing by zero.
CREATE OR REPLACE VIEW q4_cost_per_fill_by_class AS
WITH totals AS (
    SELECT
        f.data_year,
        d.drug_class,
        sum(f.total_drug_cost)   AS gross_cost,
        sum(f.total_30day_fills) AS fills_30day
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year, d.drug_class

    UNION ALL

    SELECT
        data_year,
        'All classes',
        sum(total_drug_cost),
        sum(total_30day_fills)
    FROM fact_state_product_year
    GROUP BY data_year
)
SELECT
    data_year,
    drug_class,
    gross_cost / NULLIF(fills_30day, 0) AS gross_cost_per_30day_fill
FROM totals
ORDER BY data_year, drug_class = 'All classes', drug_class;


-- Q5. Which brands lead the market each year, and where does Januvia rank?
-- RANK() OVER (PARTITION BY data_year ORDER BY claims DESC) restarts the ranking at 1
-- for every year. Ties share a rank. Keep the top 10 plus every Januvia-family row,
-- even when it falls outside the top 10.
CREATE OR REPLACE VIEW q5_top_brands_by_year AS
WITH brand_year AS (
    SELECT
        f.data_year,
        d.brand_name,
        d.drug_class,
        d.januvia_family,
        CAST(sum(f.total_claims) AS BIGINT) AS claims
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year, d.brand_name, d.drug_class, d.januvia_family
),
ranked AS (
    SELECT
        *,
        100.0 * claims / sum(claims) OVER (PARTITION BY data_year)        AS share_pct,
        RANK() OVER (PARTITION BY data_year ORDER BY claims DESC)        AS rank_in_year
    FROM brand_year
)
SELECT
    data_year,
    brand_name,
    drug_class,
    claims,
    share_pct,
    rank_in_year
FROM ranked
WHERE rank_in_year <= 10
   OR januvia_family = 1
ORDER BY data_year, rank_in_year;
