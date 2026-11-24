-- 06_export.sql
-- What: writes the results to CSV files with a header row (COPY ... TO).
--   * powerbi/  - the fact and product tables at full precision, for Power BI to load
--                 and calculate its own measures on
--   * outputs/  - the answers to Q1-Q5, validation results and the exclusion list,
--                 rounded for reading: shares, percentage-point changes and the index
--                 to 1 decimal; costs and pct_diff to 2 decimals
-- Why:  CSV files can be opened anywhere (Excel, Power BI, GitHub), and every number in
--       the README must come from a file in outputs/.

-- Power BI model (full precision) -------------------------------------------------
COPY (SELECT * FROM fact_state_product_year ORDER BY data_year, state_fips, product_id)
  TO 'powerbi/fact_state_product_year.csv' (HEADER true, DELIMITER ',');

COPY (SELECT * FROM dim_product ORDER BY product_id)
  TO 'powerbi/dim_product.csv' (HEADER true, DELIMITER ',');

-- Analysis outputs (rounded) --------------------------------------------------------
COPY (
    SELECT data_year, drug_class, claims,
           round(share_pct, 1)               AS share_pct,
           round(change_vs_prior_year_pp, 1) AS change_vs_prior_year_pp
    FROM q1_class_share_by_year
    ORDER BY data_year, drug_class
) TO 'outputs/q1_class_share_by_year.csv' (HEADER true, DELIMITER ',');

COPY (
    SELECT data_year, claims,
           round(share_of_market_pct, 1) AS share_of_market_pct,
           round(share_of_dpp4_pct, 1)   AS share_of_dpp4_pct
    FROM q2_januvia_family
    ORDER BY data_year
) TO 'outputs/q2_januvia_family.csv' (HEADER true, DELIMITER ',');

COPY (
    SELECT state_name,
           round(glp1_share_pct, 1)          AS glp1_share_pct,
           round(national_glp1_share_pct, 1) AS national_glp1_share_pct,
           round(glp1_index, 1)              AS glp1_index,
           "rank"
    FROM q3_state_glp1_index_2024
    ORDER BY "rank", state_name
) TO 'outputs/q3_state_glp1_index_2024.csv' (HEADER true, DELIMITER ',');

COPY (
    SELECT data_year, drug_class,
           round(gross_cost_per_30day_fill, 2) AS gross_cost_per_30day_fill
    FROM q4_cost_per_fill_by_class
    ORDER BY data_year, drug_class = 'All classes', drug_class
) TO 'outputs/q4_cost_per_fill_by_class.csv' (HEADER true, DELIMITER ',');

COPY (
    SELECT data_year, brand_name, drug_class, claims,
           round(share_pct, 1) AS share_pct,
           rank_in_year
    FROM q5_top_brands_by_year
    ORDER BY data_year, rank_in_year, brand_name
) TO 'outputs/q5_top_brands_by_year.csv' (HEADER true, DELIMITER ',');

-- Validation and exclusions --------------------------------------------------------
COPY (
    SELECT data_year, cms_national_claims, state_sum_claims, difference,
           round(pct_diff, 2) AS pct_diff
    FROM validation_reconciliation
    ORDER BY data_year
) TO 'outputs/validation_reconciliation.csv' (HEADER true, DELIMITER ',');

COPY (SELECT * FROM validation_checks)
  TO 'outputs/validation_checks.csv' (HEADER true, DELIMITER ',');

COPY (SELECT * FROM excluded_products ORDER BY brand_name)
  TO 'outputs/excluded_products.csv' (HEADER true, DELIMITER ',');
