-- 05_validation.sql
-- What: two views that test whether the pipeline's numbers can be trusted.
--   * validation_reconciliation - by year, CMS's own National claim total vs our
--                                 51-state sum, for the same in-market products
--   * validation_checks         - a pass/fail list of data-quality checks
-- Why:  a dashboard is only useful if its numbers are right; these checks catch
--       loading, mapping and duplication mistakes before anyone reads a chart.
--
-- Both views read the row-selection views defined once in 03_fact.sql
-- (in_market_raw_rows and fact_source_rows), so they test exactly the rows the fact
-- table is built from.


-- Reconciliation. CMS's National rows are used ONLY here. Both sides use the same
-- in-market rows (in_market_raw_rows), so they cover the same products. A gap is
-- expected: National also includes prescribers outside the 50 states + DC. Those
-- geographies are added back one group at a time, and whatever is left over is the
-- residual gap:
--   puerto_rico       = code 72
--   other_territories = any other numeric code above 56 (60 American Samoa, 66 Guam,
--                       69 Northern Mariana Islands, 78 Virgin Islands)
--   armed_forces      = 9A, 9B, 9C
--   unknown           = 9D
--   foreign           = 9E
-- (A few State rows have a blank code; none of them are in-market products.)
-- residual_gap = difference - all five groups. The residual is expected to be small
-- and positive: CMS leaves out State rows with fewer than 11 claims, but still counts
-- those claims in the National total.
CREATE OR REPLACE VIEW validation_reconciliation AS
WITH in_market AS (
    SELECT
        data_year,
        Prscrbr_Geo_Lvl,
        trim(Prscrbr_Geo_Cd)                          AS geo_code,
        coalesce(TRY_CAST(Tot_Clms AS BIGINT), 0)     AS claims
    FROM in_market_raw_rows
),
cms_national AS (
    SELECT data_year, CAST(sum(claims) AS BIGINT) AS cms_national_claims
    FROM in_market
    WHERE Prscrbr_Geo_Lvl = 'National'
    GROUP BY data_year
),
non_state AS (
    -- sum(CASE ...) puts each geography group into its own column
    SELECT
        data_year,
        CAST(sum(CASE WHEN geo_code = '72' THEN claims ELSE 0 END) AS BIGINT) AS puerto_rico_claims,
        CAST(sum(CASE WHEN TRY_CAST(geo_code AS INTEGER) > 56 AND geo_code <> '72'
                      THEN claims ELSE 0 END) AS BIGINT)                       AS other_territories_claims,
        CAST(sum(CASE WHEN geo_code IN ('9A', '9B', '9C') THEN claims ELSE 0 END) AS BIGINT) AS armed_forces_claims,
        CAST(sum(CASE WHEN geo_code = '9D' THEN claims ELSE 0 END) AS BIGINT) AS unknown_claims,
        CAST(sum(CASE WHEN geo_code = '9E' THEN claims ELSE 0 END) AS BIGINT) AS foreign_claims
    FROM in_market
    WHERE Prscrbr_Geo_Lvl = 'State'
    GROUP BY data_year
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
    n.cms_national_claims - s.state_sum_claims                                   AS difference,
    100.0 * (n.cms_national_claims - s.state_sum_claims) / n.cms_national_claims AS pct_diff,
    g.puerto_rico_claims,
    g.other_territories_claims,
    g.armed_forces_claims,
    g.unknown_claims,
    g.foreign_claims,
    (n.cms_national_claims - s.state_sum_claims)
      - (g.puerto_rico_claims + g.other_territories_claims + g.armed_forces_claims
         + g.unknown_claims + g.foreign_claims)                                  AS residual_gap
FROM cms_national AS n
JOIN state_sum    AS s USING (data_year)
JOIN non_state    AS g USING (data_year)
ORDER BY n.data_year;


-- Checks. Each CTE prepares the facts for one or more checks; the final SELECT stacks
-- one row per check with UNION ALL. passed is true or false.
-- Expected counts of years and classes are read from the data, not typed in:
--   n_years   = distinct data years loaded into raw_geo_drug
--   n_classes = distinct drug classes in dim_product
-- (A class that vanished from dim_product entirely would lower n_classes too; the
--  brand spot checks in check 5 cover all four classes, so that case still fails.)
CREATE OR REPLACE VIEW validation_checks AS
WITH
counts AS (
    SELECT
        (SELECT count(DISTINCT data_year)  FROM raw_geo_drug) AS n_years,
        (SELECT count(DISTINCT drug_class) FROM dim_product)  AS n_classes
),
states_per_year AS (
    SELECT data_year, count(DISTINCT state_fips) AS n_states
    FROM fact_state_product_year
    GROUP BY data_year
),
-- raw rows repeated for the same year x geography x brand, BEFORE any adding up
-- (the fact table's GROUP BY would otherwise sum such repeats silently)
duplicate_raw_rows AS (
    SELECT data_year, Prscrbr_Geo_Lvl, Prscrbr_Geo_Cd, brand_key
    FROM in_market_raw_rows
    GROUP BY data_year, Prscrbr_Geo_Lvl, Prscrbr_Geo_Cd, brand_key
    HAVING count(*) > 1
),
files_per_year AS (
    SELECT data_year, count(DISTINCT filename) AS n_files
    FROM raw_geo_drug
    GROUP BY data_year
),
class_years_with_claims AS (
    SELECT f.data_year, d.drug_class
    FROM fact_state_product_year AS f
    JOIN dim_product AS d USING (product_id)
    GROUP BY f.data_year, d.drug_class
    HAVING sum(f.total_claims) > 0
),
-- brands whose generic spellings (across years) would give different classes
brands_with_mixed_class AS (
    SELECT lower(trim(Brnd_Name)) AS brand_key
    FROM raw_geo_drug
    WHERE is_market_molecule(Gnrc_Name)
    GROUP BY lower(trim(Brnd_Name))
    HAVING count(DISTINCT drug_class_of(Gnrc_Name)) > 1
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
           '51 in each of ' || c.n_years || ' years' AS expected,
           'min ' || min(s.n_states) || ', max ' || max(s.n_states) || ', across ' || count(*) || ' years' AS actual,
           (min(s.n_states) = 51 AND max(s.n_states) = 51 AND count(*) = c.n_years) AS passed
    FROM states_per_year AS s, counts AS c
    GROUP BY c.n_years

    UNION ALL
    SELECT 2, '2. No duplicate raw rows per data_year x geography x brand_key (before aggregation)',
           '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM duplicate_raw_rows

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

    -- 4. CMS suppresses small counts by leaving rows out, not by blanking values,
    --    so no blank claim values are expected (see check 7)
    UNION ALL
    SELECT 6, '4. Blank claim values (expected 0)',
           '0', CAST(count(*) AS VARCHAR), count(*) = 0
    FROM fact_source_rows
    WHERE trim(coalesce(Tot_Clms, '')) = ''

    UNION ALL
    SELECT 10 + ord, '5. Spot check: ' || brand_label, expected, actual,
           actual = expected OR (expected = 'excluded' AND actual = 'not in raw data')
    FROM spot_results

    UNION ALL
    SELECT 40, '6. Every drug_class has claims in every year',
           (c.n_classes * c.n_years) || ' (' || c.n_classes || ' classes x ' || c.n_years || ' years)',
           CAST(count(k.data_year) AS VARCHAR),
           count(k.data_year) = c.n_classes * c.n_years
    FROM counts AS c
    LEFT JOIN class_years_with_claims AS k ON true
    GROUP BY c.n_classes, c.n_years

    -- 7. CMS leaves out State rows with fewer than 11 claims, so every value used
    --    should be 11 or more
    UNION ALL
    SELECT 41, '7. Smallest in-market State claim value is at least 11',
           '>= 11', CAST(min(TRY_CAST(Tot_Clms AS BIGINT)) AS VARCHAR),
           min(TRY_CAST(Tot_Clms AS BIGINT)) >= 11
    FROM fact_source_rows

    -- 8. a second file for the same year would double every number without breaking
    --    any other check
    UNION ALL
    SELECT 42, '8. Each data_year comes from exactly one file',
           '1 file for each of ' || c.n_years || ' years',
           'min ' || min(f.n_files) || ', max ' || max(f.n_files) || ' files per year',
           (min(f.n_files) = 1 AND max(f.n_files) = 1)
    FROM files_per_year AS f, counts AS c
    GROUP BY c.n_years

    UNION ALL
    SELECT 43, '9. Each brand gets the same drug_class from every year''s generic spelling',
           '0',
           CAST(count(*) AS VARCHAR)
             || CASE WHEN count(*) > 0 THEN ' (' || string_agg(brand_key, ', ') || ')' ELSE '' END,
           count(*) = 0
    FROM brands_with_mixed_class
)
SELECT check_name, expected, actual, passed
FROM all_checks
ORDER BY sort_key;
