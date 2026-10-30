
with calendario as (

    select
        generate_series(
            '2026-09-01'::date,   -- primeira data (início da janela)
            '2026-09-30'::date,   -- última data (fim da janela, inclusiva)
            '1 day'::interval     -- o passo: soma 1 dia por linha
        )::date as date_day

)

select
    date_day,
    extract(year  from date_day)::int           as ano,
    extract(month from date_day)::int           as mes,
    extract(day   from date_day)::int           as dia,
    -- Nome do dia da semana em português.
    case extract(dow from date_day)
        when 0 then 'domingo'
        when 1 then 'segunda'
        when 2 then 'terca'
        when 3 then 'quarta'
        when 4 then 'quinta'
        when 5 then 'sexta'
        when 6 then 'sabado'
    end                                         as dia_semana,

    -- is_weekend: dow (day of week) no Postgres é 0=domingo .. 6=sábado.
    -- Então fim de semana = dow in (0, 6).
    extract(dow from date_day) in (0, 6)        as is_weekend

from calendario
