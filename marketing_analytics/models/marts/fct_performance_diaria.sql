-- fct_performance_diaria — fato diário agregado (funil + mídia) no grão certo.
--
-- Grão: dia × variante × device. UMA linha por combinação.
--
-- Por que este fato existe (ver GUIA-PROJETO.md 7.3):
--   1. Elimina o blend do Looker: mídia e funil moram na mesma tabela, então as
--      abas de Mídia, Economia (ROAS/CPA) e Grade leem de uma fonte só.
--   2. Resolve a NÃO-ADITIVIDADE do funil: o fct_funil tem grão por etapa, e
--      sessoes/usuarios NÃO podem ser somados entre etapas (a mesma sessão
--      aparece em page_view E em purchase). Ao tirar a dimensão de etapa, somar
--      sessões volta a ser seguro.
--
-- Todas as medidas aqui são ADITIVAS (podem ser somadas com segurança). Os
-- ratios (CTR, CPC, CPA, ROAS, CR) NÃO entram pré-calculados — ficam como
-- SUM(num)/SUM(den) no Looker, para não quebrar ao fatiar.

with eventos as (

    select * from {{ ref('stg_ga4_events') }}

),

-- Atribui a variante ao evento pelo prefixo do utm_content (mesma regra do
-- fct_funil, para os dois fatos contarem a mesma coisa).
eventos_atribuidos as (

    select
        *,
        case
            when utm_content like 'variant_a_desconto15%' then 'A'
            when utm_content like 'variant_b_frete24h%'   then 'B'
            else null
        end as variant_id
    from eventos

),

-- Funil agregado JÁ no grão final (dia × variante × device), SEM etapa.
-- Como contamos sessões distintas direto do evento (não somando o funil),
-- a sessão é contada UMA vez por recorte — sem a inflação do grão por etapa.
funil_diario as (

    select
        event_date                      as date_day,
        variant_id,
        device_category                 as device,
        count(distinct ga_session_id)   as sessoes,
        count(distinct transaction_id)  as qtd_compras,
        sum(purchase_revenue_brl)       as receita_brl
    from eventos_atribuidos
    group by
        event_date,
        variant_id,
        device_category

),

-- Mídia já no grão dia × variante × device (fct_ad_gasto_diario traz variant_id
-- desde a 7.2). Reagrupo por variant_id porque o fato de mídia tem campaign_id
-- na chave; aqui a chave de análise é a variante.
midia_diaria as (

    select
        date_day,
        variant_id,
        device,
        sum(qtd_impressoes) as qtd_impressoes,
        sum(qtd_cliques)    as qtd_cliques,
        sum(qtd_custo_brl)  as qtd_custo_brl
    from {{ ref('fct_ad_gasto_diario') }}
    where variant_id is not null
    group by
        date_day,
        variant_id,
        device

)

-- FULL OUTER JOIN: um dia×variante×device pode ter funil sem mídia (tráfego
-- orgânico) ou mídia sem evento registrado. O full join não perde nenhum lado;
-- coalesce nas chaves monta a chave composta vinda de qualquer um dos lados.
select
    coalesce(f.date_day, m.date_day)        as date_day,
    coalesce(f.variant_id, m.variant_id)    as variant_id,
    coalesce(f.device, m.device)            as device,

    -- Medidas do funil (aditivas neste grão, pois não há mais dimensão de etapa)
    coalesce(f.sessoes, 0)      as sessoes,
    coalesce(f.qtd_compras, 0)  as qtd_compras,
    coalesce(f.receita_brl, 0)  as receita_brl,

    -- Medidas de mídia (aditivas)
    coalesce(m.qtd_custo_brl, 0)   as qtd_custo_brl,
    coalesce(m.qtd_cliques, 0)     as qtd_cliques,
    coalesce(m.qtd_impressoes, 0)  as qtd_impressoes

from funil_diario as f
full outer join midia_diaria as m
    on  f.date_day   = m.date_day
    and f.variant_id = m.variant_id
    and f.device     = m.device

-- Fato dedicado à análise A/B: mantém só linhas atribuídas a uma variante.
-- Tráfego sem variante (utm_content nulo) fica fora daqui de propósito — ele
-- vive nos totais globais de site, não na comparação A vs B.
where coalesce(f.variant_id, m.variant_id) is not null
