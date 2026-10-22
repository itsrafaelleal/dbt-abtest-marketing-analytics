-- stg_ga4_events — camada STAGING (silver) dos eventos de web do GA4.
--
-- Papel desta camada: limpeza 1:1 com a fonte. Aqui NÃO há regra de negócio
-- (funil, atribuição, conversão = marts); aqui há tipagem correta, padronização,
-- deduplicação e remoção do lixo técnico (bots/QA) que o catálogo mapeia.
--
-- Decisões aplicadas (da tabela de tipos + catálogo de anomalias):
--   - event_date (YYYYMMDD) -> date via to_date (NÃO casta direto: é texto de data).
--   - event_timestamp (micros Unix) -> timestamptz via to_timestamp(.../1e6).
--   - IDs (event_id, user_pseudo_id, ga_session_id) -> text: rótulo, não número
--     (aprendizado 5). ga_session_id vinha bigint; vira text.
--   - purchase_revenue_brl -> macro to_money (numeric(18,2)): dinheiro exato,
--     padrão da casa (aprendizados 8 e 9). NÃO preencher NULL (é NULL fora de
--     purchase, por design) e NÃO testar not_null nessa coluna.
--   - engagement_time_msec: mantém original + deriva engagement_time_sec (/1000.0).
--   - lower+trim SÓ no que entra em join/comparação e códigos de categoria
--     (UTMs, traffic_source_*, device_category, operating_system, geo_*).
--   - URL e gclid: só trim (não mexer no case — URL e token são sensíveis a isso).
--   - DEDUP: event_id tem 845 duplicatas de propósito (F5). Fica único AQUI, não
--     na fonte. Uso row_number() por event_id, mantendo o evento mais antigo.
--   - FILTRO: remove bots (user_pseudo_id LIKE 'bot_crawler_%') e QA interno
--     (traffic_source_source = 'internal_qa') — contaminam taxa de conversão.

with source as (

    select * from {{ source('raw', 'raw_ga4_events') }}

),

clean as (

    select
        -- Surrogate key: hash da chave natural do grão (1 linha por evento).
        md5(event_id::text) as event_sk,

        -- Chaves / identificadores: tudo text (rótulo, não número).
        event_id::text        as event_id,
        user_pseudo_id::text  as user_pseudo_id,
        ga_session_id::text   as ga_session_id,

        -- Datas/tempo:
        -- event_date é texto YYYYMMDD -> to_date com a máscara explícita.
        to_date(event_date::text, 'YYYYMMDD')            as event_date,
        -- event_timestamp é micros Unix -> segundos -> timestamptz.
        to_timestamp(event_timestamp / 1000000.0)        as event_timestamp,

        -- Códigos de categoria / dimensões: lower+trim (padroniza p/ agrupar).
        lower(trim(event_name))             as event_name,
        lower(trim(device_category))        as device_category,
        lower(trim(operating_system))       as operating_system,
        lower(trim(geo_country))            as geo_country,
        -- geo_region = a UF / estado de origem do visitante.
        lower(trim(geo_region))             as geo_region,

        -- Atribuição (entram em JOIN com Ads): lower+trim é pré-requisito.
        -- Sem isso, "Google " e "google" não batem (aprendizado 6).
        lower(trim(traffic_source_source))  as traffic_source_source,
        lower(trim(traffic_source_medium))  as traffic_source_medium,
        lower(trim(traffic_source_name))    as traffic_source_name,
        lower(trim(utm_content))            as utm_content,

        -- URL e token de clique: só trim (case é significativo aqui).
        trim(page_location)   as page_location,
        trim(gclid)           as gclid,

        -- Engajamento: mantém o original (ms) e deriva segundos (coluna nova).
        engagement_time_msec,                                   -- original, intacta
        engagement_time_msec / 1000.0  as engagement_time_sec,  -- derivada (ms -> s)

        -- Receita: macro to_money -> numeric(18,2). NULL continua NULL.
        {{ to_money('purchase_revenue_brl') }}  as purchase_revenue_brl,

        -- Transação e payload: só trim (JSON mantém o conteúdo original).
        trim(transaction_id)    as transaction_id,
        trim(event_params_json) as event_params_json,

        -- Audit column do silver: carimbo de quando a linha foi processada.
        current_timestamp as data_processamento

    from source

    -- FILTRO de lixo técnico (bots e QA interno): fora da taxa de conversão.
    where user_pseudo_id not like 'bot_crawler_%'
      and traffic_source_source is distinct from 'internal_qa'

),

dedup as (

    -- DEDUP do event_id: ~845 duplicatas (F5 do usuário, mesmo id ~0,5s depois).
    -- Mantém 1 linha por event_id — a de MENOR event_timestamp (o 1º disparo).
    select
        *,
        row_number() over (
            partition by event_id
            order by event_timestamp asc
        ) as rn
    from clean

)

select
    -- Postgres não tem "* EXCLUDE (col)" (isso é BigQuery/DuckDB).
    -- Listo as colunas explicitamente e deixo a técnica 'rn' de fora.
    event_sk,
    event_id,
    user_pseudo_id,
    ga_session_id,
    event_date,
    event_timestamp,
    event_name,
    device_category,
    operating_system,
    geo_country,
    geo_region,
    traffic_source_source,
    traffic_source_medium,
    traffic_source_name,
    utm_content,
    page_location,
    gclid,
    engagement_time_msec,
    engagement_time_sec,
    purchase_revenue_brl,
    transaction_id,
    event_params_json,
    data_processamento
from dedup
where rn = 1
