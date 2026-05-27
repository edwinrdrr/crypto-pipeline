{{ config(materialized = 'view') }}

-- Dashboard-friendly: ONE row per coin = its most recent snapshot.
-- A view, so it's always current off fct_crypto_prices (free to maintain).
-- Looker Studio plots this directly for scorecards / "latest price" tables.

select
    coin,
    price_usd,
    market_cap_usd,
    volume_24h_usd,
    change_24h_pct,
    price_change_pct_since_prev,
    price_direction,
    ingested_at as last_updated
from {{ ref('fct_crypto_prices') }}
qualify row_number() over (partition by coin order by ingested_at desc) = 1
