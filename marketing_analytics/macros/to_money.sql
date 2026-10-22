-- to_money — padrão da casa para tipar DINHEIRO no staging em diante.
--
-- Por que existe: todo valor monetário do projeto (receita do GA4, custo do
-- Google Ads, e as métricas derivadas nos marts: CPA, CPC, ROAS) deve usar o
-- MESMO tipo exato. Centralizar aqui evita que uma tabela use numeric(12,2) e
-- outra numeric(18,2) por descuido — divergência que quebra JOINs e somas.
--
-- Escolha do tipo: numeric(18,2)
--   - numeric  -> ponto fixo, exato em base 10 (float/double acumula erro de
--                 arredondamento ao somar milhões de linhas — veneno p/ dinheiro).
--   - escala 2 -> reais com centavos; as fontes são receita/custo final em BRL,
--                 sem câmbio nem juros a proteger (2 casas basta e é honesto).
--   - precisão 18 -> aguenta AGREGAÇÃO. Uma venda cabe em poucos dígitos, mas um
--                 SUM() por variante/mês pode estourar numeric(12,2) (~9,9 bi).
--                 18 dígitos (~9,9 quadrilhões) é seguro barato contra overflow.
--
-- Se um dia entrar moeda estrangeira (USD/EUR) com conversão de câmbio ou juros,
-- troque para numeric(19,4) AQUI — todos os modelos acompanham sem editar nada.

{% macro to_money(column) %}
    cast({{ column }} as numeric(18, 2))
{% endmacro %}
