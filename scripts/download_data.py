"""Download the CMS "Medicare Part D Prescribers - by Geography and Drug" CSVs.

Reads the CMS data catalog (data.json), finds the dataset with exactly that
title, and downloads the CSV for each data year 2019-2024 to
data/raw/geo_drug_<year>.csv. Years that are already downloaded are skipped.

Run from the project root:  python scripts/download_data.py
"""

import json
import re
import time
from pathlib import Path

import requests

CATALOG_URL = "https://data.cms.gov/data.json"
DATASET_TITLE = "Medicare Part D Prescribers - by Geography and Drug"
YEARS = range(2019, 2025)
RAW_DIR = Path("data") / "raw"


def find_csv_urls():
    """Return {year: downloadURL} for the CSV distributions of the dataset."""
    catalog = requests.get(CATALOG_URL, timeout=120).json()
    matches = [d for d in catalog["dataset"] if d.get("title") == DATASET_TITLE]
    if len(matches) != 1:
        raise SystemExit(f"Expected 1 dataset titled {DATASET_TITLE!r}, found {len(matches)}")

    urls = {}
    for dist in matches[0].get("distribution", []):
        if dist.get("mediaType") != "text/csv":
            continue
        # Entry titles look like "<dataset title> : 2024-12-01"; the year is
        # the 4 digits right after " : ".
        found = re.search(r" : (\d{4})", dist.get("title", ""))
        if not found:
            continue
        year = int(found.group(1))
        if year in YEARS:
            if year in urls:
                raise SystemExit(f"More than one CSV entry for {year}")
            urls[year] = dist["downloadURL"]
    return urls


def download(url, dest):
    """Stream url to dest via a temporary .part file; return size in MB."""
    tmp = dest.with_name(dest.name + ".part")
    with requests.get(url, stream=True, timeout=120) as resp:
        resp.raise_for_status()
        with open(tmp, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
    tmp.replace(dest)
    return dest.stat().st_size / 1024 / 1024


def main():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    urls = find_csv_urls()
    missing = [y for y in YEARS if y not in urls]
    if missing:
        raise SystemExit(f"No CSV found in the catalog for years: {missing}")

    for year in YEARS:
        dest = RAW_DIR / f"geo_drug_{year}.csv"
        if dest.exists():
            print(f"{year}: already downloaded, skipping ({dest})")
            continue
        start = time.time()
        size_mb = download(urls[year], dest)
        print(f"{year}: {size_mb:.1f} MB in {time.time() - start:.0f}s -> {dest}")


if __name__ == "__main__":
    main()
