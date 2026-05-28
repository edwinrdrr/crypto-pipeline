# Dashboard (free) — Level 3

How to put a **free, always-on dashboard** on top of this pipeline — no extra infrastructure.
(For getting notified when the pipeline *breaks*, see **`alerts.md`**.)

---

## Refresh cadence (what the dashboard shows)

- **Raw** (`crypto-pipeline-prod-260528.crypto_raw.prices`) refreshes **every 5 min** —
  Cloud Scheduler → Cloud Function (prod project).
- **Analytics** (`crypto-pipeline-prod-260528.crypto_analytics.*`) refreshes **every 6 h** —
  GitHub Actions cron (`scheduled-dbt.yml`) → `dbt build --target prod` (waits for
  required-reviewer approval before publishing).

A dashboard built on the analytics tables updates roughly **every 6 hours** — when the
prod dbt run lands (and I approve it). To make it fresher, run the dbt cron more often or
dispatch it manually (`gh workflow run "scheduled dbt (prod refresh)"`).

---

## Dashboard with Looker Studio (recommended — free, no infra)

Looker Studio (Google's free BI tool) connects natively to BigQuery, hosts the report for
you, and gives a shareable URL.

**Tables to point it at** (always in `crypto-pipeline-prod-260528.crypto_analytics`):
- `mart_latest_prices` — **one row per coin** (latest price, 24h change, direction). Great
  for scorecards and a "current prices" table.
- `fct_crypto_prices` — the full time-series. Great for a price-over-time line chart.

**Build it (~5 min):**
1. https://lookerstudio.google.com → **Create → Report**.
2. **Add data → BigQuery** → project `crypto-pipeline-prod-260528` → dataset `crypto_analytics`
   → table `mart_latest_prices` (add `fct_crypto_prices` too for time-series).
3. Charts:
   - **Scorecard**: metric `price_usd`, filtered to one coin (e.g. bitcoin).
   - **Table**: dims `coin`, `price_direction`; metrics `price_usd`, `change_24h_pct` (from `mart_latest_prices`).
   - **Time series**: date `ingested_at`, metric `price_usd`, breakdown `coin` (from `fct_crypto_prices`).
4. **Share** → done; auto-refreshes on open.

**Cost:** free. Each refresh runs a small BigQuery query; tables are MB-scale, well within
the 1 TB/month free tier; Looker Studio caches results.

### Make it public (for a portfolio / recruiters)

Looker Studio reports can be made publicly viewable, **no Google login, no GCP access**:
- **Share → Manage access →** set link access to **"Anyone on the internet can view."**
- Viewers see only the *report*; they can't touch your BigQuery. Queries run through your
  prod project (tiny/free here). Crypto prices are public data, so nothing sensitive
  is exposed.
- Tip: in the data source, use **"Owner's credentials"** (default) so public viewers don't
  need their own access.

> Alternatives if you'd rather code it: **Streamlit** on Streamlit Community Cloud (free
> hosting, Python). Self-hosted **Metabase/Grafana** are powerful but you must run a
> server — same trade-off as local Airflow.

---

## What we added for this
- `dbt/models/marts/mart_latest_prices.sql` — the one-row-per-coin view the dashboard reads.
- See `howto-playbook.md` to add more marts; `faq.md` for the cost/free-tier details.

> **Want to be notified when the pipeline breaks?** That's a separate concern — see
> **`alerts.md`** for free monitoring/notification options.
