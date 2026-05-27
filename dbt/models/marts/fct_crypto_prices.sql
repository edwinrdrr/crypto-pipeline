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
    incremental_strategy = 'merge',
    on_schema_change = 'append_new_columns'
  )
}}

{#
  on_schema_change='append_new_columns': add newly-introduced columns to the existing
  table on incremental runs. dbt's default ('ignore') silently drops new columns until
  a full refresh, so a new column never reaches an already-built prod table.
  Note: comments around a config block must be Jinja-style, not SQL dash-dash.
#}

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
        -- % change vs the previous snapshot (safe-divide avoids /0)
        round(
            safe_divide(
                price_usd - lag(price_usd) over (partition by coin order by ingested_at),
                lag(price_usd) over (partition by coin order by ingested_at)
            ) * 100, 4
        ) as price_change_pct_since_prev,
        -- simple direction flag vs the previous snapshot (demoes Slim CI)
        case
            when price_usd > lag(price_usd) over (partition by coin order by ingested_at) then 'up'
            when price_usd < lag(price_usd) over (partition by coin order by ingested_at) then 'down'
            else 'flat'
        end as price_direction,
        date(ingested_at) as ingest_date
    from prices
)

select * from with_change
