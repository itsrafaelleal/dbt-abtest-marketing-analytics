# Marketing Analytics & Teste A/B — ELT batch com dbt no Postgres

![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![dbt](https://img.shields.io/badge/dbt-Core-FF694B?logo=dbt&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-warehouse-4169E1?logo=postgresql&logoColor=white)
![pandas](https://img.shields.io/badge/pandas-ingestão-150458?logo=pandas&logoColor=white)
![SQLAlchemy](https://img.shields.io/badge/SQLAlchemy-2.x-D71F00?logo=sqlalchemy&logoColor=white)
![uv](https://img.shields.io/badge/uv-env%20%26%20deps-DE5FE9?logo=astral&logoColor=white)

Pipeline de dados **ELT em batch** que ingere dados brutos de **marketing digital**
— eventos de web do **GA4**, relatório de mídia do **Google Ads** e os metadados de
um **experimento A/B** — carrega tudo *as-is* num Postgres e transforma em modelos
limpos e analíticos com **dbt Core**, para decidir qual variante do teste vence.

A ingestão é feita em **Python/pandas** (`src/seed.py` → schema `raw` do Postgres).
A partir daí, o **dbt** assume: declara as fontes, cria a camada de **staging**
(limpeza e padronização) e os **marts** finais, aplicando testes de integridade em
cada camada. O projeto roda no **homelab** e serve de estudo de boas práticas de
engenharia analítica.

> **Documentação e aprendizados:**
>
> * [aprendizados.md](aprendizados.md) — decisões técnicas e o *porquê* de cada boa prática (o que é dbt, sources, convenção `stg_`).
> * [data/raw/catalogo-dados-mkt.md](data/raw/catalogo-dados-mkt.md) — **catálogo e dicionário de dados** da camada bronze: esquemas, tipos, granularidade e o mapa das anomalias propositais.

---

## Contexto do Projeto

**Problema:** avaliar um teste A/B de marketing exige cruzar três fontes que não
falam a mesma língua e vêm sujas de propósito (reproduzindo dado real):

* **Custo em micros:** o `cost_micros` do Google Ads vem multiplicado por 1.000.000. Sem corrigir, o CPA e o ROAS saem distorcidos em um milhão de vezes.
* **UTMs despadronizadas:** ~4,5% dos eventos do GA4 têm espaços e maiúsculas (`"Google "`, `"CPC"`), o que quebra os `JOIN`s de atribuição com as campanhas de Ads.
* **Eventos duplicados:** ~0,9% dos eventos do GA4 repetem o mesmo `event_id` (F5 do usuário), superdimensionando tráfego e receita.
* **Bots e QA interno:** ~0,3% dos eventos são não-humanos e contaminam as taxas de conversão.

**Objetivo:** construir um pipeline ELT que:

* Carrega os 3 datasets brutos no schema `raw` do Postgres, preservando o dado original.
* **Declara as fontes** no dbt para habilitar linhagem, testes e `{{ source() }}`.
* Limpa e padroniza cada fonte na camada **staging** (`stg_*`): deduplicação, casts, correção de micros, normalização de UTMs, filtro de bots.
* Consolida o resultado em **marts** analíticos para medir a variante vencedora (conversão, CPA, ROAS).

**Resultado esperado:** modelos confiáveis e testados que respondem qual variante
(A = controle, B = tratamento) teve melhor desempenho, com a sujeira tratada na
camada certa.

---

## Arquitetura (ELT em camadas)

```text
Fontes de Marketing (CSV/Parquet em data/raw/)
   • GA4 web events        (raw_ga4_events)
   • Google Ads ad report  (raw_google_ads_ad_report)
   • Metadata do A/B       (raw_ab_test_metadata)
            │
   Ingestão — src/seed.py  (pandas + SQLAlchemy, if_exists='replace')
            │
   ┌──────────────── PostgreSQL (warehouse) ────────────────┐
   │  schema raw      → tabelas brutas carregadas as-is      │
   │  schema staging  → modelos stg_ (views, limpeza 1:1)    │
   │  schema marts    → modelos fct_/dim_ (tables, análise)  │
   └──────────────────────── dbt Core ──────────────────────┘
            │
   Análise do Teste A/B (variante vencedora, CPA, ROAS)
```

**Por que ELT e não ETL:** o dado bruto é carregado primeiro (Load) e só então
transformado (Transform) **dentro do banco**, com dbt. Isso mantém o raw auditável
e reprocessável, e concentra toda a lógica de transformação em SQL versionado.

### Camadas

| Camada | Onde vive | Papel |
| :--- | :--- | :--- |
| **raw** (bronze) | schema `raw` (via `src/seed.py`) | CSVs carregados *as-is*, sem limpeza. Fonte de verdade auditável. |
| **staging** | `models/staging/` → views em `staging` | Limpeza 1:1 com a fonte: dedup, casts, correção de micros, UTMs. |
| **marts** | `models/marts/` → tables em `marts` | Modelos analíticos finais (fatos e dimensões) para consumo. |

---

## As três fontes (camada bronze)

| Tabela | Grão | Volume | Observação |
| :--- | :--- | :--- | :--- |
| `raw_ab_test_metadata` | 1 linha por variante (A/B) | 2 | Dá significado de negócio às campanhas. |
| `raw_google_ads_ad_report` | dia × campanha × ad_group × ad × device | 720 | `cost_micros` em micros (÷ 1e6 no staging). |
| `raw_ga4_events` | 1 por evento disparado | 97.278 | Sujeira proposital: 845 duplicatas, bots, UTMs despadronizadas. |

Detalhamento coluna a coluna e o catálogo de anomalias estão em
[data/raw/catalogo-dados-mkt.md](data/raw/catalogo-dados-mkt.md).

---

## Tecnologias Utilizadas

| Ferramenta | Uso |
| :--- | :--- |
| **Python 3.12** | Linguagem da ingestão. |
| **pandas** | Leitura dos CSVs brutos e escrita no Postgres (`to_sql`). |
| **SQLAlchemy + psycopg** | Conexão e engine com o PostgreSQL. |
| **PostgreSQL** | Data warehouse (schemas `raw`, `staging`, `marts`). |
| **dbt Core + dbt-postgres** | Transformação, testes, sources e linhagem. |
| **python-dotenv** | Carregar credenciais do `.env` (fora do Git). |
| **uv** | Gerenciamento de ambiente e dependências. |
| **Markdown / Mermaid** | Documentação como código (catálogo e diagramas). |

---

## Estrutura do Projeto

```text
dbt-abtest-marketing-analytics/
├── .env                           # Credenciais do Postgres (NÃO versionado)
├── .gitignore                     # Protege dados brutos (.csv/.parquet) e segredos
├── pyproject.toml                 # Dependências do projeto (uv)
├── uv.lock
├── README.md                      # Este arquivo
├── aprendizados.md                # Decisões técnicas e lições aprendidas
│
├── src/
│   └── seed.py                    # Ingestão: CSVs (data/raw) → schema raw do Postgres
│
├── data/
│   └── raw/                       # Dados brutos (CSV + Parquet) — fora do Git
│       ├── ab_test_metadata/raw_ab_test_metadata.csv
│       ├── ga4_events/raw_ga4_events.csv
│       ├── google_ads/raw_google_ads_ad_report.csv
│       └── catalogo-dados-mkt.md  # Catálogo e dicionário de dados da bronze
│
└── marketing_analytics/           # Projeto dbt
    ├── dbt_project.yml            # Config: staging=view, marts=table
    ├── macros/
    │   └── get_custom_schema.sql  # Override do schema para nomes limpos
    └── models/
        ├── staging/
        │   ├── _sources.yml       # Declaração das 3 fontes (raw)
        │   └── stg_ab_test_metadata.sql
        └── marts/
```

> Os CSVs e Parquets de `data/raw/` ficam **fora do Git** (ver `.gitignore`), por
> serem pesados e brutos. A estrutura de pastas é versionada; o dado, não.

---

## Como Reproduzir

### Pré-requisitos

* Python 3.12 e [uv](https://docs.astral.sh/uv/) instalados.
* Um PostgreSQL acessível (local ou no homelab).
* Os CSVs brutos em `data/raw/` (ver catálogo de dados).

### 1. Instalar as dependências

```bash
uv sync
```

### 2. Configurar o `.env`

Crie um `.env` na raiz com as credenciais do Postgres:

```env
DB_HOST=localhost
DB_PORT=5432
DB_USER=seu_usuario
DB_PASSWORD=sua_senha
DB_NAME=mkt_ads
```

> O `.env` está no `.gitignore` e **não deve ser versionado**.

### 3. Carregar os dados brutos (ingestão)

```bash
uv run python src/seed.py
```

Isso cria o schema `raw` (se não existir) e carrega as 3 tabelas brutas no Postgres.

### 4. Rodar as transformações com dbt

```bash
cd marketing_analytics

dbt debug      # valida a conexão com o Postgres (profile)
dbt deps       # instala pacotes dbt, se houver
dbt build      # roda os modelos + testes (staging → marts)
```

> `dbt build` executa os modelos na ordem do DAG e roda os testes declarados
> (ex.: `unique` e `not_null` nas sources) na mesma passada.

---

## Lições Aprendidas

Detalhadas em [aprendizados.md](aprendizados.md). Em resumo:

* **ELT com dbt:** carregar o bruto primeiro e transformar dentro do banco mantém o raw auditável e a lógica versionada em SQL.
* **Sources desacoplam o físico do uso:** `{{ source('raw', ...) }}` habilita linhagem, testes e *freshness* sem fixar o nome da tabela nos modelos.
* **Testar a regra certa na camada certa:** `event_id` só é `unique` **depois** da deduplicação no staging — por isso o teste de unicidade não fica na fonte.
* **Convenção `stg_`:** o nome do modelo comunica a camada e o papel, deixando o DAG legível e o projeto no padrão de mercado.

---

## Próximos Passos

* [ ]  Modelos `stg_` completos para as 3 fontes (dedup, casts, micros, UTMs, filtro de bots).
* [ ]  `_stg__models.yml` com descrições e testes de cada coluna do staging.
* [ ]  Marts de análise do A/B: funil de conversão, CPA e ROAS por variante.
* [ ]  Teste estatístico (Z-Test de proporções) para declarar a variante vencedora.
* [ ]  Documentação navegável com `dbt docs generate` + diagrama de linhagem.
