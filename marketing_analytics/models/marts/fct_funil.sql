with eventos as (
select * from {{ ref('stg_ga4_events') }} 
),

variantes as (

select *,
    case
        when utm_content like 'variant_a_desconto15%' then 'A'
        when utm_content like 'variant_b_frete24h%'   then 'B'
        else null
    end as variant_id
from eventos
)

select
event_date      as date_day,
variant_id,
device_category as device,
event_name      as etapa_funil,
count(*)                        as qtd_eventos,
count(distinct user_pseudo_id)  as usuarios_unicos,
count(distinct ga_session_id)   as sessoes,
count(distinct transaction_id)  as qtd_compras,
sum(purchase_revenue_brl)       as receita_brl 

from variantes
group by
    event_date,
    variant_id,
    device_category,
    event_name