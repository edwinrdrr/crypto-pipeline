"""Crypto pipeline orchestration (local Airflow).

One scheduled, monitored unit instead of a blind timer:

    extract_load  ->  dbt_run  ->  dbt_test

- extract_load : pull CoinGecko prices -> GCS -> BigQuery (crypto_raw_dev)
- dbt_run      : build the dbt models   (crypto_analytics_dev)
- dbt_test     : run dbt data-quality tests

Each task only runs if the previous one succeeded (that's the orchestration point).
Runs against the DEV datasets so it never collides with the CI/CD-managed prod.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT = "/opt/airflow/project"

# dbt env, shared by the dbt tasks. Auth uses the mounted service-account key.
DBT_ENV = (
    "export DBT_PROFILES_DIR={p}/dbt DBT_METHOD=service-account "
    "GCP_PROJECT=$GCP_PROJECT "
    "DBT_DATASET=crypto_analytics_dev RAW_DATASET=crypto_raw_dev && "
    "cd {p}/dbt && dbt deps "
).format(p=PROJECT)

default_args = {
    "retries": 2,                       # orchestration perk: auto-retry flaky tasks
    "retry_delay": timedelta(minutes=1),
}

with DAG(
    dag_id="crypto_pipeline",
    description="ingest -> dbt run -> dbt test (dev), hourly",
    start_date=datetime(2026, 1, 1),
    schedule="@hourly",
    catchup=False,                      # don't backfill every hour since start_date
    default_args=default_args,
    tags=["crypto", "elt"],
) as dag:

    extract_load = BashOperator(
        task_id="extract_load",
        bash_command=(
            "GCP_PROJECT=$GCP_PROJECT RAW_BUCKET=$RAW_BUCKET BQ_DATASET=crypto_raw_dev "
            f"python {PROJECT}/ingestion/main.py"
        ),
    )

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=DBT_ENV + "&& dbt run --target dev",
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=DBT_ENV + "&& dbt test --target dev",
    )

    extract_load >> dbt_run >> dbt_test
