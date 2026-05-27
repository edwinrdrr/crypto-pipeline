-- Clean + type the raw price snapshots. One row per coin per poll.
with source as (
    select * from {{ source('crypto_raw', 'prices') }}
),

renamed as (
    select
        coin,
        cast(price_usd as float64)                      as price_usd,
        cast(market_cap_usd as float64)                 as market_cap_usd,
        cast(volume_24h_usd as float64)                 as volume_24h_usd,
        cast(change_24h_pct as float64)                 as change_24h_pct,
        -- CoinGecko gives epoch seconds; turn it into a real timestamp
        timestamp_seconds(cast(source_updated_at as int64)) as source_updated_at,
        cast(ingested_at as timestamp)                  as ingested_at
    from source
    where coin is not null
)

select * from renamed
