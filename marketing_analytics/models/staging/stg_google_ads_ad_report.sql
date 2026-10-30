-- stg_google_ads_ad_report — camada STAGING (silver) do relatório diário do Google Ads.
--
-- Papel desta camada: limpeza 1:1 com a fonte. Aqui NÃO há regra de negócio
-- (isso é marts); aqui há tipagem correta, padronização e preparação para join.
--
-- Decisões aplicadas (validadas no planejamento):
--   - IDs (campaign/ad_group/ad) -> text: identificador é rótulo, não número.
--   - date_day -> date: formato ISO (YYYY-MM-DD) casta direto.
--   - cost_micros -> dividido por 1e6 e renomeado p/ cost_brl (a correção mais
--     cara do projeto; sem ela, CPA/ROAS erram por um fator de 1.000.000).
--   - lower+trim SÓ no que entra em join/comparação (UTMs) e nos códigos de
--     categoria (device, campaign_status). Texto descritivo e URL: só trim.
--   - surrogate key = hash da chave natural (determinística, reprodutível).
--   - data_processamento: audit column própria do silver (quando a linha passou aqui).

with source as (

    select * from {{ source('raw', 'raw_google_ads_ad_report') }}

),

clean as (

    select
        -- Surrogate key: chave sintetica usando hash da chave concatenando campos
        -- date_day + campaign_id + ad_group_id + ad_id + device.
        md5(
            date_day
            || '|' || campaign_id::text
            || '|' || ad_group_id::text
            || '|' || ad_id::text
            || '|' || device
        ) as ad_report_sk,

        -- Chaves / identificadores: bigint -> text (rótulo, não número).
        campaign_id::text   as campaign_id,
        ad_group_id::text   as ad_group_id,
        ad_id::text         as ad_id,
        account_id          as account_id,

        -- text -> date
        date_day::date      as date_day,

        -- Códigos de categoria: lower+trim (remove espaços/converte para minusculos).
        lower(trim(device))           as device,
        lower(trim(campaign_status))  as campaign_status,
        lower(trim(ad_type))          as ad_type,
        lower(trim(utm_source))     as utm_source,
        lower(trim(utm_medium))     as utm_medium,
        lower(trim(utm_campaign))   as utm_campaign,
        lower(trim(utm_content))    as utm_content,

        -- Texto descritivo e URL: só trim (tira espaço das pontas).
        trim(campaign_name)   as campaign_name,
        trim(ad_group_name)   as ad_group_name,
        trim(ad_name)         as ad_name,
        trim(final_url)       as final_url,

        -- Métricas: já são bigint, mantém.
        impressions as impressoes,
        clicks      as cliques,

        -- via macro to_money.a divisão é a regra do micros; a macro só padroniza o tipo de dinheiro
        {{ to_money('cost_micros / 1000000.0') }}  as custo_brl,

        -- data de processamento = carimbo de quando esta linha foi processada.
        current_timestamp as data_processamento

    from source

)

select * from clean
