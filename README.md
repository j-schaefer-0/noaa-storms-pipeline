# NOAA Storms Pipeline

A one-command pipeline that downloads a year of NOAA Storm Events data, converts it to GeoParquet, and lands it ready for analysis in DuckDB, GeoPandas, or QGIS.

## What it does

`pipeline.sh` takes a year (default: 2024), pulls the raw monthly `locations` and `details`files from NOAA's public archive, merges them to yearly CSVs, joins them using the field `event_id` and converts the table to a single GeoParquet file at `data/processed/storms_{YEAR}.parquet`.

Total runtime: about 40 seconds for a typical year on a home internet connection.

## The data

- **Source:** [NOAA Storm Events Database](https://www.ncei.noaa.gov/data/storm-events/access/original/)
- **License:** Public domain (US federal data)
- **What's in it:** every recorded storm event in the United States for each month of the given year, including type, locatio and damages  

## How to run it

Requires GDAL (for `ogr2ogr`) and standard Unix utilities (`curl`, `gunzip`).

```bash
git clone https://github.com/j-schaefer-0/noaa-storms-pipeline.git
cd noaa-storms-pipeline
chmod +x pipeline.sh
./pipeline.sh
```

To run for a specific year:

```bash
./pipeline.sh 2023
```

## What I learned

automated download and processing of multiple source data that needs merging and joining before further processing
creating GIT repository and pushing files


## Stack

- bash
- curl
- GDAL / ogr2ogr
- GeoParquet
