select * from {{ source('raw', 'raw_ga4_events') }}

  