with source as (
      select * from {{ source('raw', 'raw_ab_test_metadata') }}
  ),
  
  limpeza as (
      select
          test_id,
          test_name,
          variant_id,
          variant_label,
  
          campaign_id::text   as campaign_id,   -- BIGINT -> text (id sempre texto)
          campaign_name,
          utm_campaign,
          utm_content_prefix,
          landing_page_path,
          hypothesis,
  
          start_date::date    as start_date,     -- text -> date 
          end_date::date      as end_date,       -- text -> date
          is_control
      from source
  )
  
  select * from limpeza