-- stg_ga4_events — camada STAGING (silver) dos eventos de web do GA4.
--
-- Papel desta camada: deduplicação, tipagem, padronização de texto (lower),
-- filtro de lixo técnico (bots/QA) e derivação de colunas (uf, engagement_time_sec).

with source as (

    select * from {{ source('raw', 'raw_ga4_events') }}

),

clean as (

    select
        -- Chaves / identificadores: passam direto (mapa não pede transformação).
        event_id,
        event_name,
        user_pseudo_id,
        ga_session_id,

        -- Datas / tempo:
        to_date(event_date::text, 'YYYYMMDD')      as event_date,       -- texto -> date
        to_timestamp(event_timestamp / 1000000.0)  as event_timestamp,  -- micros Unix -> timestamptz

        -- Códigos de categoria / atribuição: lower (marcados "minusculos" no mapa).
        lower(trim(operating_system))       as operating_system,     -- texto -> minúsculo
        lower(trim(geo_region))             as geo_region,           -- texto -> minúsculo
        lower(trim(traffic_source_source))  as traffic_source_source,-- texto -> minúsculo
        lower(trim(traffic_source_medium))  as traffic_source_medium,-- texto -> minúsculo
        lower(trim(traffic_source_name))    as traffic_source_name,  -- texto -> minúsculo
        lower(trim(utm_content))            as utm_content,          -- texto -> minúsculo

        -- UF: coluna nova. geo_region -> sigla do estado (GA4 traz por extenso).
        -- lower(trim()) para não depender de acento/maiúscula na comparação.
        case lower(trim(geo_region))
            when 'bahia'             then 'BA'
            when 'minas gerais'      then 'MG'
            when 'parana'            then 'PR'
            when 'rio de janeiro'    then 'RJ'
            when 'rio grande do sul' then 'RS'
            when 'santa catarina'    then 'SC'
            when 'sao paulo'         then 'SP'
        end as uf,                                   -- geo_region -> sigla (UF)

        -- Colunas sem transformação
        device_category,
        geo_country,
        page_location,
        gclid,
        transaction_id,
        event_params_json,
        _ingested_at,

        -- Engajamento: original (ms) + coluna nova derivada em segundos.
        engagement_time_msec,                                   -- original, intacta
        engagement_time_msec / 1000.0  as engagement_time_sec,  -- ms -> s (coluna nova)

        -- Receita: double precision -> numeric(18,2) via macro to_money.
        {{ to_money('purchase_revenue_brl') }}  as purchase_revenue_brl,

        -- data de processamento = carimbo de quando esta linha foi processada.
        current_timestamp as data_processamento

    from source

    -- FILTRO de lixo técnico (bots e QA interno)
    where user_pseudo_id not like 'bot_crawler_%'
      and traffic_source_source is distinct from 'internal_qa'

),

dedup as (

    -- DEDUP do event_id: mantém 1 linha por event_id — a de MENOR
    -- event_timestamp (o primeiro disparo; os demais são F5 do usuário).
    select
        *,
        row_number() over (
            partition by event_id
            order by event_timestamp asc
        ) as rn
    from clean

)

select
    event_id,
    event_name,
    user_pseudo_id,
    ga_session_id,
    event_date,
    event_timestamp,
    operating_system,
    geo_region,
    uf,
    traffic_source_source,
    traffic_source_medium,
    traffic_source_name,
    utm_content,
    device_category,
    geo_country,
    page_location,
    gclid,
    transaction_id,
    event_params_json,
    _ingested_at,
    engagement_time_msec,
    engagement_time_sec,
    purchase_revenue_brl,
    data_processamento
from dedup
where rn = 1
