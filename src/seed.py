#%%
import os
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

# Pasta onde estão os CSVs brutos
PASTA_RAW = BASE_DIR / "data" / "raw"

DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_NAME = os.getenv("DB_NAME")
SCHEMA = "raw"


# ---------------------------------------------------------------------------
# 2. Mapeamento: qual CSV vira qual tabela
# ---------------------------------------------------------------------------
# Chave = caminho do CSV (relativo a PASTA_RAW); valor = nome da tabela no banco.
# Deixar explícito evita surpresas e dá nomes limpos às tabelas.
CSVS = {
    "ab_test_metadata/raw_ab_test_metadata.csv": "raw_ab_test_metadata",
    "ga4_events/raw_ga4_events.csv": "raw_ga4_events",
    "google_ads/raw_google_ads_ad_report.csv": "raw_google_ads_ad_report",
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
# 4. Carga dos CSVs
# ---------------------------------------------------------------------------
def garantir_schema(engine, schema: str):
    """Cria o schema se ele ainda não existir (idempotente)."""
    with engine.begin() as conn:  # begin() abre transação e dá commit no fim
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema}"))


def carregar_csvs(engine):
    """Lê cada CSV e grava como tabela no schema raw."""
    for caminho_relativo, nome_tabela in CSVS.items():
        caminho_csv = PASTA_RAW / caminho_relativo

        if not caminho_csv.exists():
            print(f"[AVISO] CSV não encontrado, pulando: {caminho_csv}")
            continue

        print(f"Lendo {caminho_csv} ...")
        df = pd.read_csv(caminho_csv)

        print(f"  -> gravando {len(df)} linhas em {SCHEMA}.{nome_tabela}")
        # if_exists='replace' recria a tabela toda vez que rodamos o seed.
        # Para dados brutos reprocessáveis isso é aceitável; se quiser apenas
        # adicionar, troque para 'append'.
        df.to_sql(
            name=nome_tabela,
            con=engine,
            schema=SCHEMA,
            if_exists="replace",
            index=False,  # não grava o índice do pandas como coluna
        )

    print("Carga concluída.")


#%% ---------------------------------------------------------------------------
# 5. Ponto de entrada
# ---------------------------------------------------------------------------
def main():
    engine = criar_engine()
    garantir_schema(engine, SCHEMA)
    carregar_csvs(engine)


if __name__ == "__main__":
    main()

# %%
