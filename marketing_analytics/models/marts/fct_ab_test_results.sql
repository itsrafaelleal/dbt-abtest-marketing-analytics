-- fct_ab_test_results — fato agregado do experimento A/B 


with funil_por_variante as (
    -- Lê de fct_performance_diaria (onde sessoes já é aditivo, sem a dimensão de etapa):
    select
        variant_id,
        sum(sessoes)      as sessoes,
        sum(qtd_compras)  as conversoes,
        sum(receita_brl)  as receita_brl
    from {{ ref('fct_performance_diaria') }}
    where variant_id is not null
    group by variant_id
),

gasto_por_variante as (

    -- Custo de mídia por variante. Depois da 7.2, fct_ad_gasto_diario já traz
    -- variant_id pronto (a ponte campaign_id -> variante vive lá), então aqui
    -- basta agrupar — não precisamos mais refazer o join com dim_variant.
    select
        variant_id,
        sum(qtd_custo_brl) as custo_brl
    from {{ ref('fct_ad_gasto_diario') }}
    where variant_id is not null
    group by variant_id

),

base as (

    -- Junta funil + mídia e calcula os KPIs
    select
        f.variant_id,
        f.sessoes,
        f.conversoes,
        f.receita_brl,
        g.custo_brl,

        f.conversoes::numeric / nullif(f.sessoes, 0)      as taxa_conversao,  -- CR
        g.custo_brl / nullif(f.conversoes, 0)             as cpa_brl,         -- CPA
        f.receita_brl / nullif(g.custo_brl, 0)            as roas,           -- ROAS
        f.receita_brl / nullif(f.conversoes, 0)           as ticket_medio_brl -- AOV

    from funil_por_variante as f
    inner join gasto_por_variante as g
        on f.variant_id = g.variant_id

),

z_test as (

    -- Z-test de proporções (duas amostras), A vs B.
    -- H0: CR_A = CR_B (não há diferença real). H1: CR_A <> CR_B (bicaudal).
    --
    -- Como o grão é 1 linha por variante, uso agregações sobre as 2 linhas para
    -- montar os totais de A e B num escalar só, e aí aplico a fórmula.
    select
        -- p combinado (pooled) sob H0 = conversões totais / sessões totais
        sum(conversoes)::numeric / sum(sessoes)                       as p_pool,
        -- CR de cada lado, isolados com filtro condicional
        max(case when variant_id = 'A' then taxa_conversao end)       as cr_a,
        max(case when variant_id = 'B' then taxa_conversao end)       as cr_b,
        max(case when variant_id = 'A' then sessoes end)              as n_a,
        max(case when variant_id = 'B' then sessoes end)              as n_b
    from base

),

z_calc as (

    select
        *,
        -- erro padrão da diferença de proporções usando o p combinado
        sqrt( p_pool * (1 - p_pool) * (1.0/n_a + 1.0/n_b) )           as erro_padrao
    from z_test

)

select
    b.variant_id,
    b.sessoes,
    b.conversoes,
    b.receita_brl,
    b.custo_brl,
    round(b.taxa_conversao, 4)   as taxa_conversao,
    round(b.cpa_brl, 2)          as cpa_brl,
    round(b.roas, 2)             as roas,
    round(b.ticket_medio_brl, 2) as ticket_medio_brl,

    -- z_stat: diferença (B - A) dividida pelo erro padrão. Mesmo valor nas 2
    -- linhas (é a estatística DO TESTE, não de cada variante).
    round( (z.cr_b - z.cr_a) / nullif(z.erro_padrao, 0), 4 )  as z_stat,

    -- p-valor BICAUDAL por APROXIMAÇÃO da normal (o Postgres não tem CDF normal
    -- nativa). Aproximação logística de Bowling (2009) para Phi(x), erro < 0.5%:
    --   Phi(z) ~ 1 / (1 + exp(-1.702 * z))
    --   p_bicaudal = 2 * (1 - Phi(|z|))
    -- Para rigor estatístico, confirmar no Python (scipy.stats.norm.sf).
    round(
        2 * (1 - 1 / (1 + exp(-1.702 * abs((z.cr_b - z.cr_a) / nullif(z.erro_padrao, 0)))))
    , 4)  as p_valor

from base as b
cross join z_calc as z
order by b.variant_id
