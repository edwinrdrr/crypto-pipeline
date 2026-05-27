"""CoinGecko -> Cloud Storage -> BigQuery ingestion.

The ELT 'EL' steps:
  1. Extract: pull current crypto prices from the CoinGecko API.
  2. Land:    write the raw JSON to Cloud Storage (the data lake / replay copy).
  3. Load:    batch-load that file into a BigQuery raw table (batch loads are free).

Runs two ways:
  - Locally:        `python main.py`            (uses your gcloud / ADC credentials)
  - As a Cloud Function: entry point `ingest`   (triggered every 5 min by Cloud Scheduler)
"""

import json
import os
from datetime import datetime, timezone

import requests
from google.cloud import bigquery, storage

# --- Config (env vars let dev/prod differ without code changes) ---
PROJECT_ID = os.environ.get("GCP_PROJECT")              # e.g. "my-learning-project"
RAW_BUCKET = os.environ["RAW_BUCKET"]                   # e.g. "my-project-crypto-raw"
BQ_DATASET = os.environ.get("BQ_DATASET", "crypto_raw") # dev: crypto_raw_dev, prod: crypto_raw
BQ_TABLE = os.environ.get("BQ_TABLE", "prices")

COINS = os.environ.get("COINS", "bitcoin,ethereum,solana,cardano")
COINGECKO_URL = "https://api.coingecko.com/api/v3/simple/price"


def extract():
    """Call CoinGecko and return (rows, raw_response)."""
    params = {
        "ids": COINS,
        "vs_currencies": "usd",
        "include_market_cap": "true",
        "include_24hr_vol": "true",
        "include_24hr_change": "true",
        "include_last_updated_at": "true",
    }
    resp = requests.get(COINGECKO_URL, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    # Stamp the moment we ingested so every poll is a distinct time-series row.
    ingested_at = datetime.now(timezone.utc).isoformat()
    rows = []
    for coin, fields in data.items():
        rows.append(
            {
                "coin": coin,
                "price_usd": fields.get("usd"),
                "market_cap_usd": fields.get("usd_market_cap"),
                "volume_24h_usd": fields.get("usd_24h_vol"),
                "change_24h_pct": fields.get("usd_24h_change"),
                "source_updated_at": fields.get("last_updated_at"),  # epoch seconds
                "ingested_at": ingested_at,
            }
        )
    return rows, data


def land_in_gcs(rows, raw_response):
    """Write newline-delimited JSON to GCS, partitioned by date in the path."""
    now = datetime.now(timezone.utc)
    # date-partitioned prefix = easy to find/replay a day's files, common DE convention
    blob_path = (
        f"raw/coingecko/dt={now:%Y-%m-%d}/"
        f"prices_{now:%Y%m%dT%H%M%S}.jsonl"
    )
    ndjson = "\n".join(json.dumps(r) for r in rows)

    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(RAW_BUCKET)
    bucket.blob(blob_path).upload_from_string(ndjson, content_type="application/json")

    gcs_uri = f"gs://{RAW_BUCKET}/{blob_path}"
    print(f"Landed {len(rows)} rows -> {gcs_uri}")
    return gcs_uri


def load_to_bigquery(gcs_uri):
    """Batch-load the GCS file into BigQuery (free). Appends to the raw table."""
    client = bigquery.Client(project=PROJECT_ID)
    table_id = f"{client.project}.{BQ_DATASET}.{BQ_TABLE}"

    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        autodetect=True,  # fine for learning; pin a schema later for stability
        # Partition by ingest day so dbt incremental models scan only new data (cheap).
        time_partitioning=bigquery.TimePartitioning(field="ingested_at"),
    )
    load_job = client.load_table_from_uri(gcs_uri, table_id, job_config=job_config)
    load_job.result()  # wait for completion
    print(f"Loaded into {table_id}")


def run():
    rows, raw = extract()
    gcs_uri = land_in_gcs(rows, raw)
    load_to_bigquery(gcs_uri)
    return f"ingested {len(rows)} rows"


def ingest(request):
    """Cloud Function HTTP entry point (called by Cloud Scheduler)."""
    return run()


if __name__ == "__main__":
    print(run())
