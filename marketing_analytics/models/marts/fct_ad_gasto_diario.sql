-- fct_ad_gasto_diario — fato de mídia (investimento) do Google Ads.
--
-- Grão: dia × campanha × device (não desce a ad_group/ad — ver camada-gold.md 3.2).
--
-- 7.2: trazemos variant_id para o fato de mídia via join com dim_variant por
-- campaign_id. Hoje há exatamente 1 campanha por variante, então o join é 1:1 e
-- NÃO multiplica linhas (invariante provado por teste em _models.yml). Resolver a
-- tradução campaign_id -> variant_id aqui (no dbt) evita blend frágil no Looker.

with gastos as (

    select * from {{ ref('stg_google_ads_ad_report') }}

),

-- Agrega a mídia no grão do fato: dia × campanha × device.
gasto_agregado as (

    select
        date_day,
        campaign_id,
        device,
        sum(impressoes) as qtd_impressoes,
        sum(cliques)    as qtd_cliques,
        sum(custo_brl)  as qtd_custo_brl
    from gastos
    group by
        date_day,
        campaign_id,
        device

)

select
    g.date_day,
    g.campaign_id,
    v.variant_id,          -- 7.2: chave de análise pronta (A/B) vinda da dim
    g.device,
    g.qtd_impressoes,
    g.qtd_cliques,
    g.qtd_custo_brl
from gasto_agregado as g
left join {{ ref('dim_variant') }} as v
    on g.campaign_id = v.campaign_id
