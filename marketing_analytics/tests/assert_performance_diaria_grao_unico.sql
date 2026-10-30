-- Invariante (7.3): o grão de fct_performance_diaria é dia × variante × device.
-- Uma combinação dessas três colunas pode aparecer NO MÁXIMO uma vez.
--
-- Como teste singular do dbt funciona: ele é uma query que deve retornar ZERO
-- linhas para passar. Aqui retornamos as chaves que aparecem mais de uma vez;
-- se vier qualquer linha, o grão quebrou (fan-out) e o teste fica VERMELHO.

select
    date_day,
    variant_id,
    device,
    count(*) as qtd_linhas
from {{ ref('fct_performance_diaria') }}
group by
    date_day,
    variant_id,
    device
having count(*) > 1
