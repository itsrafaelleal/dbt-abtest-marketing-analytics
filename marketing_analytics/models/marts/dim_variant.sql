with variantes as (

    select * from {{ ref('stg_ab_test_metadata') }}

)
select
    variant_id,
    variant_label,
    is_control,
    hypothesis,
    campaign_id,
    campaign_name,
    utm_content_prefix,
    start_date,          
    end_date    
from variantes           