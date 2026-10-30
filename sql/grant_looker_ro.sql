-- Role dedicado para o Looker Studio: SOMENTE LEITURA, restrito ao schema `marts`.
--
-- o Looker conecta num endereço alcançável pela internet (via ngrok).
-- Este role só pode LER as tabelas de consumo (`marts`) — nunca `raw`/`staging`,
-- nunca escrever. Reduz o estrago ao mínimo caso o endereço vaze.


-- Cria o usuário de login. LOGIN = pode conectar; PASSWORD = senha dele.
CREATE ROLE looker_ro LOGIN PASSWORD 'SENHA-FORTE';

-- Permite conectar no database.
GRANT CONNECT ON DATABASE mkt_ads TO looker_ro;

-- Permite "enxergar" o schema marts (USAGE = pode referenciar objetos dele).
GRANT USAGE ON SCHEMA marts TO looker_ro;

-- Permite LER (SELECT) todas as tabelas que já existem no marts hoje.
GRANT SELECT ON ALL TABLES IN SCHEMA marts TO looker_ro;

-- Garante SELECT também nas tabelas FUTURAS do marts.
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT TO looker_ro;
