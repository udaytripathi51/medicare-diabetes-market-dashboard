-- 05_validation.sql
-- What: two views that test whether the pipeline's numbers can be trusted.
--   * validation_reconciliation - by year, CMS's own National claim total vs our
--                                 51-state sum, for the same in-market products
--   * validation_checks         - a pass/fail list of data-quality checks
-- Why:  a dashboard is only useful if its numbers are right; these checks catch
--       loading, mapping and duplication mistakes before anyone reads a chart.


-- Reconciliation. CMS's National rows are used ONLY here. The same product rule as
-- the fact table applies (molecule stem AND brand_key join), so both sides cover the
-- same products. A gap is expected: National also includes prescribers in territories,
-- armed forces, unknown and foreign locations, which the 51-state sum leaves out.
CREATE OR REPLACE VIEW validation_reconciliation AS
WITH cms_national AS (
    SELECT
        r.data_year,
        CAST(sum(coalesce(TRY_CAST(r.Tot_Clms AS BIGINT), 0)) AS BIGINT) AS cms_national_claims
    FROM raw_geo_drug AS r
    JOIN dim_product  AS d
      ON lower(trim(r.Brnd_Name)) = d.brand_key
    WHERE r.Prscrbr_Geo_Lvl = 'National'
      AND is_market_molecule(r.Gnrc_Name)
    GROUP BY r.data_year
),
state_sum AS (
    SELECT
        data_year,
        CAST(sum(total_claims) AS BIGINT) AS state_sum_claims
    FROM fact_state_product_year
    GROUP BY data_year
)
SELECT
    n.data_year,
    n.cms_national_claims,
    s.state_sum_claims,
    n.cms_national_claims - s.state_sum_claims                               AS difference,
    100.0 * (n.cms_national_claims - s.state_sum_claims) / n.cms_national_claims AS pct_diff
FROM cms_national AS n
JOIN state_sum    AS s USING (data_year)
ORDER BY n.data_year;


-- Checks. Each CTE prepares the facts for one or more checks; the final SELECT stacks
-- one row per check with UNION ALL. passed is true/false, or NULL for "report only".
CREATE OR REPLACE VIEW validation_checks AS
WITH
-- the exact raw rows the fact table is built from (same filters as 03_fact.sql)
fact_source_rows AS (
    SELECT r.*
    FROM raw_geo_drug AS r
    JOIN dim_product  AS d
      ON lower(trim(r.Brnd_Name)) = d.brand_key
    WHERE r.Prscrbr_Geo_Lvl = 'State'
      AND TRY_CAST(r.Prscrbr_Geo_Cd AS INTEGER) BETWEEN 1 AND 56
      AND is_market_molecule(r.Gnrc_Name)
),
states_per_year AS (
    SELECT data_year, count(DISTINCT state_fips) AS n_states
    FROM fact_state_product_year
    GROUP BY data_year
),
duplicate_keys AS (
    SELECT data_year, state_fips, product_id
    FROM fact_state_product_year
    GROUP BY data_year, state_fips, product_id
    HAVING count(*) > 1
),
class_years_with_claims AS (
    SELECT f.data_year, d.drug_class
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year, d.drug_class
    HAVING sum(f.total_claims) > 0
),
-- brand spot checks: the brand (as a LIKE pattern on brand_key) and its expected result.
-- Soliqua and Xultophy carry a strength in their brand name ('Soliqua 100-33'), so they
-- are matched by prefix; all others must match exactly.
spot_list(ord, brand_label, brand_pattern, expected) AS (
    VALUES
        ( 1, 'Januvia',    'januvia',    'DPP-4'),
        ( 2, 'Janumet',    'janumet',    'DPP-4'),
        ( 3, 'Janumet XR', 'janumet xr', 'DPP-4'),
        ( 4, 'Tradjenta',  'tradjenta',  'DPP-4'),
        ( 5, 'Jardiance',  'jardiance',  'SGLT2'),
        ( 6, 'Farxiga',    'farxiga',    'SGLT2'),
        ( 7, 'Ozempic',    'ozempic',    'GLP-1'),
        ( 8, 'Trulicity',  'trulicity',  'GLP-1'),
        ( 9, 'Mounjaro',   'mounjaro',   'GLP-1'),
        (10, 'Rybelsus',   'rybelsus',   'GLP-1'),
        (11, 'Glyxambi',   'glyxambi',   'DPP-4 + SGLT2 combo'),
        (12, 'Steglujan',  'steglujan',  'DPP-4 + SGLT2 combo'),
        (13, 'Wegovy',     'wegovy',     'excluded'),
        (14, 'Zepbound',   'zepbound',   'excluded'),
        (15, 'Saxenda',    'saxenda',    'excluded'),
        (16, 'Soliqua',    'soliqua%',   'excluded'),
        (17, 'Xultophy',   'xultophy%',  'excluded')
),
spot_results AS (
    SELECT
        s.ord,
        s.brand_label,
        s.expected,
        CASE
            WHEN EXISTS (SELECT 1 FROM dim_product d WHERE d.brand_key LIKE s.brand_pattern)
                THEN (SELECT max(d.drug_class) FROM dim_product d WHERE d.brand_key LIKE s.brand_pattern)
            WHEN EXISTS (SELECT 1 FROM excluded_products e WHERE lower(e.brand_name) LIKE s.brand_pattern)
                THEN 'excluded'
            WHEN NOT EXISTS (SELECT 1 FROM raw_geo_drug r WHERE lower(trim(r.Brnd_Name)) LIKE s.brand_pattern)
                THEN 'not in raw data'
            ELSE 'missing'
        END AS actual
    FROM spot_list AS s
),
all_checks AS (
    SELECT 1 AS sort_key,
           '1. 51 states in every year' AS check_name,
           '51 in each of 6 years' AS expected,
           'min ' || min(n_states) || ', max ' || max(n_states) || ', across ' || count(*) || ' years' AS actual,
           (min(n_states) = 51 AND max(n_states) = 51 AND count(*) = 6) AS passed
    FROM states_per_year

    UNION ALL
    SELECT 2, '2. No duplicate (data_year, state_fips, product_id) rows in the fact table',
           '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM duplicate_keys

    -- 3. a cast failure = a value that is not blank but TRY_CAST still turned into NULL
    UNION ALL
    SELECT 3, '3a. Cast failures in Tot_Clms', '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM fact_source_rows
    WHERE trim(coalesce(Tot_Clms, '')) <> '' AND TRY_CAST(Tot_Clms AS BIGINT) IS NULL

    UNION ALL
    SELECT 4, '3b. Cast failures in Tot_30day_Fills', '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM fact_source_rows
    WHERE trim(coalesce(Tot_30day_Fills, '')) <> '' AND TRY_CAST(Tot_30day_Fills AS DOUBLE) IS NULL

    UNION ALL
    SELECT 5, '3c. Cast failures in Tot_Drug_Cst', '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM fact_source_rows
    WHERE trim(coalesce(Tot_Drug_Cst, '')) <> '' AND TRY_CAST(Tot_Drug_Cst AS DOUBLE) IS NULL

    UNION ALL
    SELECT 6, '4. Blank (suppressed) claim values in the rows used (report only)',
           'report only', CAST(count(*) AS VARCHAR), CAST(NULL AS BOOLEAN)
    FROM fact_source_rows
    WHERE trim(coalesce(Tot_Clms, '')) = ''

    UNION ALL
    SELECT 6 + ord, '5. Spot check: ' || brand_label, expected, actual,
           actual = expected OR (expected = 'excluded' AND actual = 'not in raw data')
    FROM spot_results

    UNION ALL
    SELECT 30, '6. Every drug_class has claims in every year',
           '24 (4 classes x 6 years)', CAST(count(*) AS VARCHAR), count(*) = 24
    FROM class_years_with_claims
)
SELECT check_name, expected, actual, passed
FROM all_checks
ORDER BY sort_key;
