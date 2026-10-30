-- to_money — converte numeros inteiros em float (INT  50050 = float 500,50)

{% macro to_money(column) %}
    cast({{ column }} as numeric(18, 2))
{% endmacro %}
