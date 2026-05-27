{{
  config(
    materialized = 'incremental',
    unique_key = ['coin', 'ingested_at'],
    partition_by = {
      'field': 'ingested_at',
      'data_type': 'timestamp',
      'granularity': 'day'
    },
    cluster_by = ['coin'],
    incremental_strategy = 'merge'
  )
}}

-- Time-series fact: every coin price snapshot, enriched with the change
-- since the previous snapshot. Incremental = each run only reads NEW rows,
-- so it stays well inside BigQuery's free 1 TB/month.

with prices as (
    select * from {{ ref('stg_crypto__prices') }}

    {% if is_incremental() %}
      -- Only pull rows newer than what we've already loaded.
      -- Look back a little to catch any late-arriving data.
      where ingested_at > (
        select timestamp_sub(max(ingested_at), interval 1 hour) from {{ this }}
      )
    {% endif %}
),

with_change as (
    select
        coin,
        price_usd,
        market_cap_usd,
        volume_24h_usd,
        change_24h_pct,
        source_updated_at,
        ingested_at,
        price_usd - lag(price_usd) over (
            partition by coin order by ingested_at
        ) as price_change_since_prev,
        date(ingested_at) as ingest_date
    from prices
)

select * from with_change
