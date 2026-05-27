# Dashboard (free)

How to put a **free, always-on dashboard** on top of this pipeline — no extra infrastructure.
(For getting notified when the pipeline *breaks*, see **`alerts.md`**.)

---

## Refresh cadence (what the dashboard shows)

- **Raw** (`crypto_raw.prices`) refreshes **every 5 min** (Cloud Scheduler → function).
- **Analytics** (`crypto_analytics.*`) refreshes **every 6 h** (GitHub Actions cron → dbt).

A dashboard built on the analytics tables updates roughly **every 6 hours** — that's when dbt
rebuilds them. (Want it fresher? Run the dbt cron more often — but watch GitHub Actions minutes.)

---

## Dashboard with Looker Studio (recommended — free, no infra)

Looker Studio (Google's free BI tool) connects natively to BigQuery, hosts the report for you,
and gives a shareable URL.

**Tables to point it at (in `crypto_analytics`):**
- `mart_latest_prices` — **one row per coin** (latest price, 24h change, direction). Great for
  scorecards and a "current prices" table.
- `fct_crypto_prices` — the full time-series. Great for a price-over-time line chart.

**Build it (~5 min):**
1. https://lookerstudio.google.com → **Create → Report**.
2. **Add data → BigQuery** → project `crypto-pipeline-260527-18241` → dataset `crypto_analytics`
   → table `mart_latest_prices` (add `fct_crypto_prices` too for the time-series).
3. Add charts:
   - **Scorecard**: metric `price_usd`, filtered to one coin (e.g. bitcoin).
   - **Table**: dims `coin`, `price_direction`; metrics `price_usd`, `change_24h_pct` (from `mart_latest_prices`).
   - **Time series**: date `ingested_at`, metric `price_usd`, breakdown `coin` (from `fct_crypto_prices`).
4. **Share** → done; it auto-refreshes when opened.

**Cost:** free. Each refresh runs a small BigQuery query; at a few MB it's negligible against the
1 TB/month free tier, and Looker Studio caches results.

### Make it public (for a portfolio / recruiters)

Yes — Looker Studio can be shared publicly so **anyone with the link can view, no Google login,
no GCP access**:
- **Share → Manage access →** set link access to **"Anyone on the internet can view."**
- Viewers see only the *report*; they can't touch your BigQuery. Queries run through your project
  (tiny/free here). Crypto prices are public data, so nothing sensitive is exposed.
- Tip: in the data source, use **"Owner's credentials"** (default) so public viewers don't need
  their own access.

> Alternatives if you'd rather code it: **Streamlit** on Streamlit Community Cloud (free hosting,
> Python). Self-hosted **Metabase/Grafana** are powerful but you must run a server (local = only
> while your laptop is up; or a free `e2-micro` VM) — same trade-off as local Airflow.

---

## What we added for this
- `dbt/models/marts/mart_latest_prices.sql` — the one-row-per-coin view the dashboard reads.
- See `howto-playbook.md` to add more marts; `faq.md` for the cost/free-tier details.

> **Want to be notified when the pipeline breaks?** That's a separate concern — see
> **`alerts.md`** for free monitoring/notification options.
