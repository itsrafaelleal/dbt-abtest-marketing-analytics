# Marketing Analytics & Teste A/B — ELT batch com dbt no Postgres

![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![dbt](https://img.shields.io/badge/dbt-Core-FF694B?logo=dbt&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-warehouse-4169E1?logo=postgresql&logoColor=white)
![pandas](https://img.shields.io/badge/pandas-ingestão-150458?logo=pandas&logoColor=white)
![Parquet](https://img.shields.io/badge/Apache%20Parquet-landing-50ABF1?logo=apacheparquet&logoColor=white)
![Looker Studio](https://img.shields.io/badge/Looker%20Studio-dashboard-4285F4?logo=looker&logoColor=white)
![uv](https://img.shields.io/badge/uv-env%20%26%20deps-DE5FE9?logo=astral&logoColor=white)

Pipeline de dados **ELT em batch** que ingere dados brutos de **marketing digital**
— eventos de web do **GA4**, relatório de mídia do **Google Ads** e os metadados de
um **experimento A/B** — carrega tudo *as-is* num Postgres e transforma em modelos
limpos e analíticos com **dbt Core**, alimentando um dashboard no **Looker Studio**
que responde qual variante do teste vence.

A ingestão é feita em **Python/pandas** (`src/seed.py`, lendo Parquet da camada
`data/landing/` → schema `raw` do Postgres). A partir daí, o **dbt** assume:
declara as fontes, cria a camada de **staging** (limpeza e padronização) e os
**marts** dimensionais (Star Schema), aplicando testes de integridade em cada
camada. O projeto roda no **homelab** e serve de estudo de boas práticas de
engenharia analítica.

> **Documentação e aprendizados:**
>
> * [catalogo-dados-mkt.md](catalogo-dados-mkt.md) — **catálogo e dicionário de dados**: esquemas, tipos, granularidade, linhagem, o mapa de anomalias propositais e a especificação do dashboard.
> * [aprendizados.md](aprendizados.md) — decisões técnicas e o *porquê* de cada boa prática (dbt, sources, convenção `stg_`, dinheiro em `numeric`, conexão do BI).
> * [camada-gold.md](camada-gold.md) — detalhamento de design da Gold (grão, atribuição de variante, Z-Test).
> * [conexao-looker-opcoes.md](conexao-looker-opcoes.md) — opções e passo a passo para conectar o Looker Studio ao Postgres do homelab.

---

## Contexto do Projeto

**Problema:** avaliar um teste A/B de marketing exige cruzar três fontes que não
falam a mesma língua e vêm sujas de propósito (reproduzindo dado real):

* **Custo em micros:** o `cost_micros` do Google Ads vem multiplicado por 1.000.000. Sem corrigir, o CPA e o ROAS saem distorcidos em um milhão de vezes.
* **UTMs despadronizadas:** ~4,5% dos eventos do GA4 têm espaços e maiúsculas (`"Google "`, `"CPC"`), o que quebra os `JOIN`s de atribuição com as campanhas de Ads.
* **Eventos duplicados:** ~0,9% dos eventos do GA4 repetem o mesmo `event_id` (F5 do usuário), superdimensionando tráfego e receita.
* **Bots e QA interno:** ~0,3% dos eventos são não-humanos e contaminam as taxas de conversão.

**Objetivo:** construir um pipeline ELT que:

* Carrega os 3 datasets brutos (Parquet) no schema `raw` do Postgres, preservando o dado original.
* **Declara as fontes** no dbt para habilitar linhagem, testes e `{{ source() }}`.
* Limpa e padroniza cada fonte na camada **staging** (`stg_*`): deduplicação, casts, correção de micros, normalização de UTMs, filtro de bots.
* Consolida o resultado em **marts** dimensionais (Star Schema) e mede a variante vencedora (conversão, CPA, ROAS, significância via Z-Test).
* Expõe a Gold ao **Looker Studio** para consumo visual.

**Resultado:** modelos confiáveis e testados, mais um dashboard que responde qual
variante (A = controle, B = tratamento) teve melhor desempenho, com a sujeira
tratada na camada certa.

---

## Arquitetura Medalhão

Fluxo completo nas camadas **Landing → Raw → Staging → Marts → Dashboard**:

```text
Fontes de Marketing Digital
   • GA4 web events        (export de eventos em lote diário)
   • Google Ads ad report  (conector Fivetran, D-1)
   • Metadata do A/B       (cadastro do experimento)
            │
   Landing — Apache Parquet (data/landing/)
   • ga4_events/*.parquet
   • google_ads/*.parquet
   • ab_test_metadata/*.parquet
            │
   Ingestão — src/seed.py  (pandas + SQLAlchemy, Parquet → Postgres)
            │
   ┌──────────────── PostgreSQL (warehouse) ────────────────┐
   │  schema raw      → tabelas brutas carregadas as-is      │
   │  schema staging  → modelos stg_ (views, limpeza 1:1)    │
   │  schema marts    → modelos fct_/dim_ (tables, análise)  │
   └──────────────────────── dbt Core ──────────────────────┘
            │
   Dashboard — Looker Studio (conector Postgres, lê o schema marts)
   • Scorecard da variante vencedora  • Funil de drop-off  • Curva de ROAS
```

**Por que ELT e não ETL:** o dado bruto é carregado primeiro (Load) e só então
transformado (Transform) **dentro do banco**, com dbt. Isso mantém o raw auditável
e reprocessável, e concentra toda a lógica de transformação em SQL versionado.

### Camadas

| Camada | Onde vive | Papel |
| :--- | :--- | :--- |
| **Landing** | Parquet em `data/landing/` | Formato de intercâmbio: como o dado chega do conector, antes de ir ao banco. |
| **raw** (bronze) | schema `raw` (via `src/seed.py`) | Parquet carregado *as-is*, sem limpeza. Fonte de verdade auditável. |
| **staging** (silver) | `models/staging/` → views em `staging` | Limpeza 1:1 com a fonte: dedup, casts, correção de micros, UTMs. |
| **marts** (gold) | `models/marts/` → tables em `marts` | Modelos dimensionais finais (fatos e dimensões) para consumo. |
| **Dashboard** | Looker Studio | Camada de visualização e KPIs de negócio. |

---

## As três fontes (camada bronze)

| Tabela | Grão | Volume | Observação |
| :--- | :--- | :--- | :--- |
| `raw_ab_test_metadata` | 1 linha por variante (A/B) | 2 | Dá significado de negócio às campanhas. |
| `raw_google_ads_ad_report` | dia × campanha × ad_group × ad × device | 720 | `cost_micros` em micros (÷ 1e6 no staging). |
| `raw_ga4_events` | 1 por evento disparado | 97.278 | Sujeira proposital: 845 duplicatas, bots, UTMs despadronizadas. |

Detalhamento coluna a coluna e o catálogo de anomalias estão em
[catalogo-dados-mkt.md](catalogo-dados-mkt.md).

---

## O modelo dimensional (camada gold)

Star Schema (Kimball) com **2 dimensões** e **4 fatos**, já construído e em uso:

| Tabela | Tipo | Grão | Volume |
| :--- | :--- | :--- | :--- |
| `dim_variant` | Dimensão | 1 por variante | 2 |
| `dim_date` | Dimensão | 1 por dia | 30 |
| `fct_funil` | Fato | dia × variante × device × etapa | 906 |
| `fct_performance_diaria` | Fato | dia × variante × device | 180 |
| `fct_ad_gasto_diario` | Fato | dia × campanha × variante × device | 180 |
| `fct_ab_test_results` | Fato | 1 por variante (resumo + Z-Test) | 2 |

A `fct_ab_test_results` é a tabela-resposta do projeto: além de CR, CPA, ROAS e
ticket médio, carrega `z_stat` e `p_valor` do **Z-Test de proporções**, que diz
se a diferença entre A e B é estatisticamente significativa.

---

## Tecnologias Utilizadas

| Ferramenta | Uso |
| :--- | :--- |
| **Python 3.12** | Linguagem da ingestão. |
| **pandas** | Leitura dos Parquet de `data/landing/` e escrita no Postgres. |
| **SQLAlchemy + psycopg** | Conexão e engine com o PostgreSQL. |
| **Apache Parquet** | Formato colunar da camada landing. |
| **PostgreSQL** | Data warehouse (schemas `raw`, `staging`, `marts`). |
| **dbt Core + dbt-postgres** | Transformação, testes, sources e linhagem. |
| **Looker Studio** | Dashboard de consumo (conector Postgres). |
| **python-dotenv** | Carregar credenciais do `.env` (fora do Git). |
| **uv** | Gerenciamento de ambiente e dependências. |
| **Markdown / Mermaid** | Documentação como código (catálogo e diagramas). |

---

## Estrutura do Projeto

```text
dbt-abtest-marketing-analytics/
├── .env                           # Credenciais do Postgres (NÃO versionado)
├── .gitignore                     # Protege dados brutos (.parquet) e segredos
├── pyproject.toml                 # Dependências do projeto (uv)
├── uv.lock
├── README.md                      # Este arquivo
├── aprendizados.md                # Decisões técnicas e lições aprendidas
├── catalogo-dados-mkt.md          # Catálogo e dicionário de dados
├── camada-gold.md                 # Design da Gold (grão, atribuição, Z-Test)
├── conexao-looker-opcoes.md       # Opções/passo a passo da conexão com o Looker
│
├── src/
│   └── seed.py                    # Ingestão: Parquet (data/landing) → schema raw
│
├── sql/
│   ├── grant_looker_ro.sql        # Role somente-leitura do BI (schema marts)
│   └── looker_queries.sql         # Queries de consumo (Custom Query no Looker)
│
├── data/
│   └── landing/                   # Dados brutos em Parquet — fora do Git
│       ├── ab_test_metadata/raw_ab_test_metadata.parquet
│       ├── ga4_events/raw_ga4_events.parquet
│       └── google_ads/raw_google_ads_ad_report.parquet
│
└── marketing_analytics/           # Projeto dbt
    ├── dbt_project.yml            # Config: staging=view, marts=table
    ├── macros/
    │   ├── get_custom_schema.sql  # Override do schema para nomes limpos
    │   └── to_money.sql           # Conversão de custo/receita para numeric
    ├── models/
    │   ├── staging/
    │   │   ├── _sources.yml       # Declaração das 3 fontes (raw)
    │   │   ├── stg_ab_test_metadata.sql
    │   │   ├── stg_ga4_events.sql
    │   │   └── stg_google_ads_ad_report.sql
    │   └── marts/
    │       ├── _models.yml
    │       ├── dim_date.sql
    │       ├── dim_variant.sql
    │       ├── fct_ab_test_results.sql
    │       ├── fct_ad_gasto_diario.sql
    │       ├── fct_funil.sql
    │       └── fct_performance_diaria.sql
    └── tests/                     # Testes singulares (anti-fan-out, grão único)
```

> Os Parquets de `data/landing/` ficam **fora do Git** (ver `.gitignore`), por
> serem pesados e brutos. A estrutura de pastas é versionada; o dado, não.

---

## Como Reproduzir

### Pré-requisitos

* Python 3.12 e [uv](https://docs.astral.sh/uv/) instalados.
* Um PostgreSQL acessível (local ou no homelab).
* Os Parquets brutos em `data/landing/` (ver catálogo de dados).

### 1. Instalar as dependências

```bash
uv sync
```

### 2. Configurar o `.env`

Crie um `.env` na raiz com as credenciais do Postgres:

```env
DB_HOST=localhost
DB_PORT=5430
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
> (ex.: `unique`/`not_null` nas sources, e os testes singulares anti-fan-out) na
> mesma passada.

---

## Conectar o Dashboard (Looker Studio)

O Looker Studio é um serviço na nuvem do Google e precisa alcançar o Postgres por
um `host:porta` público. O caminho adotado e as alternativas (ngrok para provar,
Postgres gerenciado para o permanente) estão documentados em
[conexao-looker-opcoes.md](conexao-looker-opcoes.md). Em resumo:

1. Criar um role **somente-leitura** restrito ao schema `marts`
   (`sql/grant_looker_ro.sql`) — o BI nunca usa o dono do banco.
2. Expor a porta do Postgres temporariamente (`ngrok tcp 5430`) para validar.
3. No Looker, conector **PostgreSQL** → **Custom Query** qualificando o schema
   (`SELECT * FROM marts.<tabela>`), pois o conector lista o schema `public`
   (vazio) por padrão. As queries prontas estão em `sql/looker_queries.sql`.

---

## Lições Aprendidas

Detalhadas em [aprendizados.md](aprendizados.md). Em resumo:

* **ELT com dbt:** carregar o bruto primeiro e transformar dentro do banco mantém o raw auditável e a lógica versionada em SQL.
* **Sources desacoplam o físico do uso:** `{{ source('raw', ...) }}` habilita linhagem, testes e *freshness* sem fixar o nome da tabela nos modelos.
* **Testar a regra certa na camada certa:** `event_id` só é `unique` **depois** da deduplicação no staging — por isso o teste de unicidade não fica na fonte.
* **Dinheiro nunca em `float`:** `cost_micros` (÷1e6) e `purchase_revenue_brl` convergem para `numeric` no staging — ponto fixo, exato.
* **Convenção `stg_`:** o nome do modelo comunica a camada e o papel, deixando o DAG legível e o projeto no padrão de mercado.
* **Conectar o BI é arquitetura, não só SQL:** `host:porta` alcançável, role somente-leitura, schema de busca e grão das fontes (anti-fan-out) ao preparar as queries do Looker.

---

## Próximos Passos

* [x]  Modelos `stg_` completos para as 3 fontes (dedup, casts, micros, UTMs, filtro de bots).
* [x]  Marts dimensionais: funil, performance diária, gasto de mídia e resultado do A/B (CPA, ROAS, Z-Test).
* [x]  Testes singulares anti-fan-out e de grão único no `marts`.
* [x]  Conexão do Looker Studio à Gold (role somente-leitura + Custom Query).
* [ ]  Montar as abas do dashboard (scorecard, funil, ROAS no tempo, auditoria).
* [ ]  Migrar o `marts` para Postgres gerenciado (Neon/Supabase) para o portfólio "sempre no ar".
* [ ]  Documentação navegável com `dbt docs generate` + diagrama de linhagem.
