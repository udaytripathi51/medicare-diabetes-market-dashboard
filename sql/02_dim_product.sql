-- 02_dim_product.sql
-- What: builds the product list for the Type 2 diabetes market:
--   * dim_product       - one row per in-market product (brand), with its drug class
--                         and MSD flags
--   * excluded_products - products that contain a market molecule but are left out
--                         on purpose, with the reason
-- Why:  every analysis needs to know which drug class a product belongs to. Doing the
--       mapping once, here, keeps the rule in one place.

-- ---------------------------------------------------------------------------------
-- 1. The molecule rule, written once as small reusable SQL functions (macros).
--    Molecules are matched by STEM because CMS cuts some generic names short, e.g.
--    'Dapaglifloz Propaned/Metformin' and 'Empaglifloz/Linaglip/Metformin'.
--    On the raw data, the stems add exactly 3 brand/generic pairs compared with full
--    names (Xigduo XR 2023-24, Dapagliflozin-Metformin ER 2024, Trijardy XR) and match
--    no unrelated drug (glipizide, glutamine, sotagliflozin, teduglutide don't match).
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE MACRO has_dpp4(generic) AS
    regexp_matches(lower(generic), 'sitaglip|saxaglip|linaglip|aloglip');

CREATE OR REPLACE MACRO has_sglt2(generic) AS
    regexp_matches(lower(generic), 'canaglifloz|dapaglifloz|empaglifloz|ertuglifloz|bexaglifloz');

CREATE OR REPLACE MACRO has_glp1(generic) AS
    regexp_matches(lower(generic), 'semaglut|dulaglut|liraglut|exenat|lixisenat|tirzepat|albiglut');

CREATE OR REPLACE MACRO is_market_molecule(generic) AS
    has_dpp4(generic) OR has_sglt2(generic) OR has_glp1(generic);

-- ---------------------------------------------------------------------------------
-- 2. product_mapping: every candidate product with its class and (if any) exclusion
--    reason. It is a TEMP table: a working step that disappears when the pipeline
--    ends, and both final tables below are cut from it.
--
--    One product = one brand name (brand_key = trimmed, lower-cased brand), so a change
--    in capitalisation or in the generic name across years doesn't split a product.
--    Display spelling = the one from the latest year the brand appears.
--
--    Brands whose generic name changes across years (found while profiling):
--      * Steglujan: 'Ertugliflozin/Sitagliptin' (2019-2021)
--                   -> 'Ertugliflozin/Sitagliptin Phos' (2022-2024)
--      * Xigduo XR: 'Dapagliflozin/Metformin Hcl' (2019-2022)
--                   -> 'Dapaglifloz Propaned/Metformin' (2023-2024)
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE product_mapping AS
WITH candidates AS (
    -- every raw row whose generic name contains a market molecule
    SELECT
        lower(trim(Brnd_Name)) AS brand_key,
        trim(Brnd_Name)        AS brand_name,
        trim(Gnrc_Name)        AS generic_name,
        data_year
    FROM raw_geo_drug
    WHERE is_market_molecule(Gnrc_Name)
),
latest AS (
    -- one row per brand; arg_max(x, data_year) = "the value of x in the latest year"
    SELECT
        brand_key,
        arg_max(brand_name,   data_year) AS brand_name,
        arg_max(generic_name, data_year) AS generic_name
    FROM candidates
    GROUP BY brand_key
)
SELECT
    brand_key,
    brand_name,
    generic_name,
    -- CASE checks the rules top to bottom and stops at the first one that is true,
    -- so a DPP-4 + SGLT2 product is caught by rule 1 before rules 2 and 3.
    -- Metformin / pioglitazone partners are ignored, so those combos keep the class
    -- of their other molecule.
    CASE
        WHEN has_dpp4(generic_name) AND has_sglt2(generic_name) THEN 'DPP-4 + SGLT2 combo'
        WHEN has_dpp4(generic_name)  THEN 'DPP-4'
        WHEN has_sglt2(generic_name) THEN 'SGLT2'
        WHEN has_glp1(generic_name)  THEN 'GLP-1'
    END AS drug_class,
    CASE
        WHEN lower(generic_name) LIKE '%insulin%'
            THEN 'Insulin combination (generic name contains insulin)'
        WHEN brand_key IN ('wegovy', 'zepbound', 'saxenda')
            THEN 'Obesity brand (weight management, not Type 2 diabetes)'
    END AS exclusion_reason
FROM latest;

-- ---------------------------------------------------------------------------------
-- 3. dim_product: the in-market products. product_id is a simple number (1, 2, 3...)
--    given by ROW_NUMBER(), ordered by class then brand so the IDs are stable.
--    brand_family rolls up pack and device variants that CMS lists as separate brand
--    names, so the brand ranking (Q5) doesn't split one medicine into several rows:
--      Victoza 2-Pak, Victoza 3-Pak                    -> Victoza
--      Bydureon, Bydureon Bcise, Bydureon Pen          -> Bydureon
--    Every other product's brand_family is its own brand_name.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_product AS
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY drug_class, brand_key) AS INTEGER) AS product_id,
    brand_key,
    brand_name,
    CASE
        WHEN brand_key IN ('victoza 2-pak', 'victoza 3-pak')               THEN 'Victoza'
        WHEN brand_key IN ('bydureon', 'bydureon bcise', 'bydureon pen')   THEN 'Bydureon'
        ELSE brand_name
    END AS brand_family,
    generic_name,
    drug_class,
    CASE WHEN brand_key IN ('januvia', 'janumet', 'janumet xr',
                            'steglatro', 'segluromet', 'steglujan')
         THEN 1 ELSE 0 END AS is_msd_brand,
    -- Januvia family = Januvia, Janumet, Janumet XR only (not Zituvio or generic sitagliptin)
    CASE WHEN brand_key IN ('januvia', 'janumet', 'janumet xr')
         THEN 1 ELSE 0 END AS januvia_family
FROM product_mapping
WHERE exclusion_reason IS NULL
ORDER BY product_id;

-- ---------------------------------------------------------------------------------
-- 4. excluded_products: matched a molecule but left out on purpose, with the reason.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE TABLE excluded_products AS
SELECT
    brand_name,
    generic_name,
    exclusion_reason AS reason
FROM product_mapping
WHERE exclusion_reason IS NOT NULL
ORDER BY brand_name;
