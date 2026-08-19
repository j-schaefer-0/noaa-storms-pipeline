#!/usr/bin/env bash
#
# pipeline.sh
#
# Downloads and merges the 12 monthly NOAA Storm Events "locations" and "details"
# CSV files for a given year, joins them through event_id, and converts the result
# to a single GeoParquet file (point geometry from lat/lon).
# using ogr2ogr.
#
# Usage:
#   ./pipeline.sh <YEAR>
#
# Example:
#   ./pipeline.sh 2023
#
# Requirements: curl, gunzip, gdal (ogr2ogr) built with Parquet/Arrow support.

set -euo pipefail

START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <YEAR>" >&2
    echo "  YEAR          e.g. 2023" >&2
    echo "" >&2
    echo "Example: $0 2023" >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    usage
fi

YEAR="$1"

# Basic sanity checks on the arguments
if ! [[ "${YEAR}" =~ ^[0-9]{4}$ ]]; then
    echo "Error: YEAR must be a 4-digit number, got '${YEAR}'." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE_URL="https://www.ncei.noaa.gov/data/storm-events/access/original"
YEAR_URL="${BASE_URL}/${YEAR}"

RAW_DIR="data/raw"
PROCESSED_DIR="data/processed"

MERGED_LOCATIONS_CSV="${RAW_DIR}/StormEvents_locations_${YEAR}.csv"
MERGED_DETAILS_CSV="${RAW_DIR}/StormEvents_details_${YEAR}.csv"
OUT_PARQUET="${PROCESSED_DIR}/storms_${YEAR}.parquet"
JOIN_DB="${PROCESSED_DIR}/.storms_${YEAR}_join.gpkg"

mkdir -p "${RAW_DIR}" "${PROCESSED_DIR}"

# ---------------------------------------------------------------------------
# 1. Find and download the 12 monthly CSV files
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    echo "script failed to execute, curl must be installed" >&2
    exit 1
fi

download_and_merge() {
    local prefix="$1"
    local merged_csv="$2"
    local csv_files
    local filename
    local csv_path
    local url
    local first_file=true

    csv_files=$(curl -fSL --retry 3 "${YEAR_URL}/" \
        | grep -oE "${prefix}_s${YEAR}[0-9]{4}_e${YEAR}[0-9]{4}_c[0-9]{8}\.csv" \
        | sort -u)

    if [ "$(printf '%s\n' "${csv_files}" | sed '/^$/d' | wc -l)" -ne 12 ]; then
        echo "Error: expected 12 ${prefix} CSV files for ${YEAR}, found $(printf '%s\n' "${csv_files}" | sed '/^$/d' | wc -l)." >&2
        exit 1
    fi

    rm -f "${merged_csv}"
    while IFS= read -r filename; do
        [ -z "${filename}" ] && continue
        csv_path="${RAW_DIR}/${filename}"
        url="${YEAR_URL}/${filename}"
        if [ -s "${csv_path}" ]; then
            echo "Using existing: ${csv_path}"
        else
            echo "Downloading: ${url}"
            temp_csv="${csv_path}.tmp.$$"
            curl -fSL --retry 3 -o "${temp_csv}" "${url}"
            mv -f "${temp_csv}" "${csv_path}"
        fi

        if [ "${first_file}" = true ]; then
            cat "${csv_path}" > "${merged_csv}"
            first_file=false
        else
            tail -n +2 "${csv_path}" >> "${merged_csv}"
        fi
    done <<< "${csv_files}"
}

echo "Finding monthly location and detail CSV files in: ${YEAR_URL}"
download_and_merge "StormEvents_locations" "${MERGED_LOCATIONS_CSV}"
download_and_merge "StormEvents_details" "${MERGED_DETAILS_CSV}"

# ---------------------------------------------------------------------------
# 2. Validate merged CSV
# ---------------------------------------------------------------------------
for csv_path in "${MERGED_LOCATIONS_CSV}" "${MERGED_DETAILS_CSV}"; do
    echo "Merged monthly files into: ${csv_path}"
    if [ ! -s "${csv_path}" ]; then
        echo "Error: merged CSV is missing or empty: ${csv_path}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 3. Convert to GeoParquet with ogr2ogr
# ---------------------------------------------------------------------------
#    NOAA Storm Events locations files use lat / lon (WGS84, EPSG:4326) as the
#    event's point location. We build point geometry from those fields.
# ---------------------------------------------------------------------------
if ! command -v ogr2ogr >/dev/null 2>&1; then
    echo "Error: ogr2ogr not found. Install GDAL (with Parquet driver support)." >&2
    exit 1
fi

echo "Converting to GeoParquet: ${OUT_PARQUET}"
rm -f "${OUT_PARQUET}" "${JOIN_DB}" "${JOIN_DB}-shm" "${JOIN_DB}-wal"

ogr2ogr \
    -f "GPKG" \
    "${JOIN_DB}" \
    "${MERGED_LOCATIONS_CSV}" \
    -oo X_POSSIBLE_NAMES=lon \
    -oo Y_POSSIBLE_NAMES=lat \
    -oo KEEP_GEOM_COLUMNS=NO \
    -oo AUTODETECT_TYPE=YES \
    -oo EMPTY_STRING_AS_NULL=YES \
    -a_srs EPSG:4326 \
    -nln locations \
    -nlt POINT

ogr2ogr \
    -update \
    -append \
    -f "GPKG" \
    "${JOIN_DB}" \
    "${MERGED_DETAILS_CSV}" \
    -nln details \
    -oo AUTODETECT_TYPE=YES \
    -oo EMPTY_STRING_AS_NULL=YES

ogr2ogr \
    -f "Parquet" \
    "${OUT_PARQUET}" \
    "${JOIN_DB}" \
    -dialect SQLITE \
    -sql "SELECT l.*, d.last_date_modified, d.last_date_certified, d.state, d.state_fips, d.year, d.month_name, d.event_type, d.cz_type, d.cz_fips, d.cz_name, d.wfo, d.begin_date_time, d.cz_timezone, d.end_date_time, d.injuries_direct, d.injuries_indirect, d.deaths_direct, d.deaths_indirect, d.damage_property, d.damage_crops, d.source, d.magnitude, d.magnitude_type, d.flood_cause, d.category, d.tor_f_scale, d.tor_length, d.tor_width, d.tor_other_wfo, d.tor_other_cz_state, d.tor_other_cz_fips, d.tor_other_cz_name, d.episode_title, d.episode_narrative, d.event_narrative FROM locations l LEFT JOIN details d ON l.event_id = d.event_id" \
    -nln "storms_${YEAR}"

if [ -f "${OUT_PARQUET}" ]; then
    GEOMETRY_INFO=$(ogrinfo -so "${OUT_PARQUET}" "storms_${YEAR}" 2>&1)
    if [[ "${GEOMETRY_INFO}" != *"Geometry: Point"* ]]; then
        echo "Error: output was created but has no Point geometry: ${OUT_PARQUET}" >&2
        rm -f "${OUT_PARQUET}"
        exit 1
    fi
    rm -f "${JOIN_DB}" "${JOIN_DB}-shm" "${JOIN_DB}-wal"
    END_TIME=$(date +%s)
    ELAPSED_SECONDS=$((END_TIME - START_TIME))
    ELAPSED_HOURS=$((ELAPSED_SECONDS / 3600))
    ELAPSED_MINUTES=$(((ELAPSED_SECONDS % 3600) / 60))
    ELAPSED_REMAINDER=$((ELAPSED_SECONDS % 60))
    echo "Runtime: $(printf '%02d:%02d:%02d' \
        "${ELAPSED_HOURS}" "${ELAPSED_MINUTES}" "${ELAPSED_REMAINDER}") (hh:mm:ss)"
    echo "Done. GeoParquet output written to: ${OUT_PARQUET}"
else
    echo "Error: conversion failed, no output file produced." >&2
    exit 1
fi