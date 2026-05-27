# Local Airflow orchestration

Runs the whole pipeline as one scheduled, monitored DAG — the free, local
alternative to Cloud Composer (which costs ~$300+/mo, so we never use it).

```
extract_load  ──►  dbt_run  ──►  dbt_test
(API→GCS→BQ)      (build models)  (data-quality tests)
```
Each task runs only if the previous succeeded; failed tasks auto-retry (2×). Runs
against the **dev** datasets so it never collides with the CI/CD-managed prod.

## Run it

```bash
cd airflow
cp .env.example .env                 # set AIRFLOW_UID (run: id -u) and GCP_PROJECT

# A GCP key the container uses for BigQuery + GCS (gitignored). Reuse the CI SA:
gcloud iam service-accounts keys create gcp-key.json \
  --iam-account=dbt-ci@$GCP_PROJECT.iam.gserviceaccount.com

docker compose up airflow-init       # one-time: init metadata DB + admin user
docker compose up -d                 # start webserver + scheduler
# open http://localhost:8080  (login: airflow / airflow), unpause "crypto_pipeline",
# then "Trigger DAG" to run it now.

docker compose down                  # stop everything when done
```

## Why an orchestrator (vs the Cloud Scheduler we already have)

| Cloud Scheduler (a timer) | Airflow (an orchestrator) |
|---|---|
| Hits one URL on a cron | Runs a **graph** of tasks in dependency order |
| No retries, no memory | **Retries**, **backfills**, full run **history** |
| Can't express "B after A" | "run dbt **only if** ingest succeeded" |
| No visibility | **UI**: per-task status, logs, durations |

In production you'd schedule the dbt transforms here too (not just ingestion), add
alerting on failure, and orchestrate many dependent steps — which a timer can't do.

## Notes
- `gcp-key.json` and `.env` are gitignored — never commit them.
- This is **local only**. It runs when your machine + Docker are up; it does not
  replace the deployed Cloud Function (that keeps ingesting every 5 min independently).
