# Alerts & monitoring (free)

How to get notified — for **$0** — when the pipeline breaks: ingestion stops landing data, or a
scheduled run fails. Options below are ordered easiest-first.

## What you actually want to catch
- **A scheduled run fails** (the 6-hourly dbt transform errors out).
- **Ingestion stops** (the 5-min function stops landing rows → data goes stale).
- (Optionally) **the function itself errors** at runtime.

---

## 1. GitHub Actions failure email — already on, zero setup
GitHub emails you automatically when a scheduled workflow run fails. So if the 6-hourly
`scheduled-dbt` job breaks (bad data, auth, a dbt error), you get a mail with no configuration.
(If you don't see them: GitHub → Settings → Notifications → Actions.)

## 2. dbt source freshness — detects "ingestion stopped"
Your sources already declare freshness (`warn_after: 15m`, `error_after: 60m` on
`crypto_raw.prices`). Run it on a schedule and a stale raw table (the function stopped landing
data) becomes a **failure → email** via #1:
```bash
dbt source freshness --target prod      # add as a step in scheduled-dbt.yml to alert on stale data
```

## 3. GCP Cloud Monitoring — alert on the function erroring
Console → **Monitoring → Alerting → Create policy** → metric *Cloud Function → Execution count*
(filter `status != ok`), or a log-based alert on errors → notification channel **Email** (free).
Cloud Monitoring has a free allotment that easily covers one project.

## 4. Slack / Discord webhook — nicer alerts, still free
Create an incoming webhook (free) and `curl` it from a workflow step or a tiny Cloud Function
when a check fails — e.g. post "⚠️ crypto ingestion stale" to a channel.

---

## Recommended minimum (all free, low effort)
Rely on **(1) GitHub failure emails**, and add **(2) `dbt source freshness`** to the scheduled
workflow so a *stopped ingestion* alerts you too. That covers both "a run failed" and "data
stopped flowing" without any new infrastructure.

> Data values themselves (e.g. "BTC moved >10%") are a different kind of alert — encode those as
> a dbt test or a scheduled query that posts to a webhook. See `howto-playbook.md` recipe 4.

Related: `dashboard.md` (view the data), `faq.md` → Orchestration (the scheduled-jobs picture).
