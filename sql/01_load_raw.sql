-- 01_load_raw.sql
-- What: loads all six yearly CMS CSV files (data/raw/geo_drug_<year>.csv) into one
--       table, raw_geo_drug, exactly as they are, plus a data_year column.
-- Why:  every later step reads from this single table, so the CSVs are parsed only once.
--
-- Notes:
-- * all_varchar = true reads every column as text. Nothing is converted yet, so a
--   strange value can never break the load; numbers are converted later with TRY_CAST.
-- * union_by_name = true lines up columns by their header name, not their position,
--   in case a year's file ever orders its columns differently.
-- * filename = true adds a "filename" column; the data year is the 4 digits in it.

CREATE OR REPLACE TABLE raw_geo_drug AS
SELECT
    *,
    CAST(regexp_extract(filename, 'geo_drug_(\d{4})\.csv', 1) AS INTEGER) AS data_year
FROM read_csv(
    'data/raw/geo_drug_*.csv',
    filename      = true,
    all_varchar   = true,
    union_by_name = true
);
