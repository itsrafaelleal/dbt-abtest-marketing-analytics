-- Invariante (7.2): o join de fct_ad_gasto_diario com dim_variant (para trazer
-- variant_id) NÃO pode multiplicar linhas. Hoje há 1 campanha por variante, logo
-- o join é 1:1 e a contagem antes e depois do join tem que ser idêntica.
--
-- Como provamos: comparamos a contagem do fato (pós-join) com a contagem do grão
-- dia × campanha × device vinda direto do staging (pré-join). Se o fato tiver
-- MAIS linhas, dim_variant tem campaign_id duplicado (fan-out) e o teste falha.
--
-- Teste singular: retorna ZERO linhas quando o invariante vale.

with contagem_fato as (

    select count(*) as n_linhas
    from {{ ref('fct_ad_gasto_diario') }}

),

contagem_esperada as (

    -- grão natural da mídia antes de qualquer join com a dimensão
    select count(*) as n_linhas
    from (
        select date_day, campaign_id, device
        from {{ ref('stg_google_ads_ad_report') }}
        group by date_day, campaign_id, device
    ) as grao

)

select
    f.n_linhas as linhas_fato,
    e.n_linhas as linhas_esperadas
from contagem_fato as f
cross join contagem_esperada as e
where f.n_linhas <> e.n_linhas
