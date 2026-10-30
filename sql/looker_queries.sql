
-- Queries de consumo para o Looker Studio (camada `marts`)

--
-- POR QUE ESTE ARQUIVO EXISTE
-- O conector PostgreSQL do Looker lista tabelas do schema `public` por padrão —
-- e no nosso banco o `public` está vazio (tudo vive em `marts`). Por isso o
-- Looker mostra "não há tabelas disponíveis" na conexão básica. A saída é usar
-- a opção CUSTOM QUERY (consulta personalizada) e qualificar o schema: `marts.<tabela>`.

-- Cada fato do `marts` tem um GRÃO diferente (o que define uma linha única):
--   - fct_performance_diaria -> (dia, variante, device)
--   - fct_funil              -> (dia, variante, device, etapa_funil)
--   - fct_ad_gasto_diario    -> (dia, campanha, variante, device)
--   - fct_ab_test_results    -> (variante)   [já é o resumo do teste]
--
-- COMO USAR NO LOOKER
--   Create -> Data source -> PostgreSQL -> CUSTOM QUERY -> colar uma das queries.
--   Uma fonte de dados por query abaixo.




-- Query A — Performance diária enriquecida  (fonte principal do dashboard)

SELECT
    f.date_day,
    f.variant_id,
    v.variant_label,
    v.is_control,
    v.hypothesis,
    f.device,
    d.dia_semana,
    d.is_weekend,
    f.sessoes,
    f.qtd_compras,
    f.receita_brl,
    f.qtd_custo_brl,
    f.qtd_cliques,
    f.qtd_impressoes
FROM marts.fct_performance_diaria AS f
LEFT JOIN marts.dim_variant AS v ON f.variant_id = v.variant_id
LEFT JOIN marts.dim_date    AS d ON f.date_day   = d.date_day;



-- Query B — Resultado do teste A/B 
SELECT
    r.variant_id,
    v.variant_label,
    v.is_control,
    v.hypothesis,
    r.sessoes,
    r.conversoes,
    r.receita_brl,
    r.custo_brl,
    r.taxa_conversao,
    r.cpa_brl,
    r.roas,
    r.ticket_medio_brl,
    r.z_stat,
    r.p_valor
FROM marts.fct_ab_test_results AS r
LEFT JOIN marts.dim_variant AS v ON r.variant_id = v.variant_id;



-- Query C — Funil  (aba de etapas)

SELECT
    f.date_day,
    f.variant_id,
    v.variant_label,
    f.device,
    f.etapa_funil,
    f.qtd_eventos,
    f.usuarios_unicos,
    f.sessoes,
    f.qtd_compras,
    f.receita_brl
FROM marts.fct_funil AS f
LEFT JOIN marts.dim_variant AS v ON f.variant_id = v.variant_id;



-- Query D — Gasto de mídia diário

SELECT
    f.date_day,
    f.campaign_id,
    f.variant_id,
    v.variant_label,
    f.device,
    f.qtd_impressoes,
    f.qtd_cliques,
    f.qtd_custo_brl
FROM marts.fct_ad_gasto_diario AS f
LEFT JOIN marts.dim_variant AS v ON f.variant_id = v.variant_id;
