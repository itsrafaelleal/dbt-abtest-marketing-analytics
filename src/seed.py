#%%
import io
import logging
import os
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

# ---------------------------------------------------------------------------
# 1. Caminhos e variáveis de ambiente
# ---------------------------------------------------------------------------
# BASE_DIR = pasta onde este arquivo (seed.py) está.
# resolve() transforma em caminho absoluto; parent pega o diretório.
BASE_DIR = Path(__file__).resolve().parent.parent


# Carrega as variáveis do .env para dentro de os.environ
load_dotenv(BASE_DIR / ".env")

# Pasta onde estão os arquivos da camada landing (Parquet)
PASTA_LANDING = BASE_DIR / "data" / "landing"

DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_NAME = os.getenv("DB_NAME")
SCHEMA = "raw"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("seed")


# ---------------------------------------------------------------------------
# 2. Mapeamento: qual Parquet vira qual tabela
# ---------------------------------------------------------------------------
# Chave = caminho do Parquet (relativo a PASTA_LANDING); valor = nome da tabela.
# Parquet (e não CSV) preserva os tipos de origem — padrão de intercâmbio.
PARQUETS = {
    "ab_test_metadata/raw_ab_test_metadata.parquet": "raw_ab_test_metadata",
    "ga4_events/raw_ga4_events.parquet": "raw_ga4_events",
    "google_ads/raw_google_ads_ad_report.parquet": "raw_google_ads_ad_report",
}


# ---------------------------------------------------------------------------
# 3. Conexão com o banco
# ---------------------------------------------------------------------------
def criar_engine():
    url = (
        f"postgresql+psycopg://{DB_USER}:{DB_PASSWORD}"
        f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )
    return create_engine(url)


#%% ---------------------------------------------------------------------------
# 4. Carga dos Parquets
# ---------------------------------------------------------------------------
def garantir_schema(engine, schema: str):
    """Cria o schema se ele ainda não existir (idempotente)."""
    with engine.begin() as conn:  # begin() abre transação e dá commit no fim
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema}"))


def carregar_parquet(engine, df: pd.DataFrame, nome_tabela: str):
    """Dropa a tabela, recria e faz bulk load via COPY (full refresh do zero)."""
    # DROP ... CASCADE derruba a tabela e TUDO que depende dela (as views stg_ do
    # dbt). Por isso: rode 'dbt run' depois do seed para reconstruir o staging.
    with engine.begin() as conn:
        conn.execute(text(f"DROP TABLE IF EXISTS {SCHEMA}.{nome_tabela} CASCADE"))

    # head(0) recria a tabela só com o schema (zero linhas), respeitando os
    # tipos vindos do Parquet. O COPY abaixo insere os dados em massa.
    df.head(0).to_sql(
        name=nome_tabela,
        con=engine,
        schema=SCHEMA,
        if_exists="append",
        index=False,
    )

    # COPY é o bulk loader nativo do Postgres: muito mais rápido que INSERTs.
    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False)
    buffer.seek(0)

    colunas = ", ".join(f'"{c}"' for c in df.columns)
    sql = (
        f'COPY {SCHEMA}.{nome_tabela} ({colunas}) '
        f"FROM STDIN WITH (FORMAT csv)"
    )
    # Acessa a conexão psycopg crua para usar o COPY em streaming.
    raw = engine.raw_connection()
    try:
        with raw.cursor() as cur:
            with cur.copy(sql) as copy:
                copy.write(buffer.read())
        raw.commit()
    finally:
        raw.close()


def carregar_arquivos(engine):
    """Lê cada Parquet da landing e grava como tabela no schema raw."""
    for caminho_relativo, nome_tabela in PARQUETS.items():
        caminho = PASTA_LANDING / caminho_relativo

        if not caminho.exists():
            log.warning("Arquivo não encontrado, pulando: %s", caminho)
            continue

        log.info("Lendo %s ...", caminho)
        df = pd.read_parquet(caminho)

        # Colunas de auditoria: quando e de onde a linha foi carregada (medallion).
        df["_loaded_at"] = datetime.now(timezone.utc)
        df["_source_file"] = caminho.name

        log.info("  -> gravando %d linhas em %s.%s", len(df), SCHEMA, nome_tabela)
        carregar_parquet(engine, df, nome_tabela)

        # Validação: confere se o banco tem o mesmo número de linhas do DataFrame.
        with engine.begin() as conn:
            total = conn.execute(
                text(f"SELECT count(*) FROM {SCHEMA}.{nome_tabela}")
            ).scalar_one()
        if total != len(df):
            raise ValueError(
                f"{nome_tabela}: esperado {len(df)} linhas, banco tem {total}"
            )
        log.info("  -> OK, %d linhas confirmadas", total)

    log.info("Carga concluída.")


#%% ---------------------------------------------------------------------------
# 5. Ponto de entrada
# ---------------------------------------------------------------------------
def main():
    engine = criar_engine()
    garantir_schema(engine, SCHEMA)
    carregar_arquivos(engine)


if __name__ == "__main__":
    main()

# %%
