# Aprendizados

> Registro das decisões técnicas e do **porquê** de cada boa prática adotada
> neste projeto. Cada aprendizado parte de algo concreto que eu fiz no código —
> não é teoria solta. A ordem segue a lógica de construção do pipeline: primeiro
> entender a ferramenta, depois o ponto de entrada dos dados, depois os detalhes
> de organização e nomenclatura.

---

## 1. O que é o dbt e por que ele muda a forma de transformar dados

O **dbt (data build tool)** é a ferramenta que transforma os dados **dentro do
banco**, já na camada de warehouse. Ele não extrai nem carrega dado — isso é
tarefa da ingestão (no meu caso, o `src/seed.py`, que leva os CSVs brutos para o
schema `raw` do Postgres). O papel do dbt começa **depois** que o dado já está lá.

A ideia central é simples e poderosa: **eu escrevo apenas `SELECT`s**, e o dbt
cuida do resto — criar as `VIEW`s/`TABLE`s, descobrir a ordem de execução,
gerenciar dependências e rodar os testes. Cada arquivo `.sql` em `models/` vira
um objeto no banco.

Por que isso importa:

- **Transformação como código versionado.** Em vez de SQL solto rodado na mão, o
  pipeline inteiro vive em arquivos `.sql` e `.yml` no Git. Dá para revisar,
  reverter e reproduzir.
- **O dbt monta o DAG sozinho.** Quando um modelo referencia outro com
  `{{ ref('outro_modelo') }}` ou uma fonte com `{{ source(...) }}`, o dbt entende
  a linhagem e executa na ordem certa. Eu não preciso orquestrar a mão.
- **`SELECT` puro, materialização declarativa.** Eu descrevo *o que* quero
  (a query); o dbt decide *como* persistir. No `dbt_project.yml` deste projeto,
  por exemplo, defini que `staging` é materializado como `view` e `marts` como
  `table` — e isso vale para todos os modelos de cada pasta sem repetir código:

  ```yaml
  models:
    marketing_analytics:
      staging:
        +materialized: view
        +schema: staging
      marts:
        +materialized: table
        +schema: marts
  ```

A diferença prática: `view` não ocupa espaço e sempre reflete o dado atual (bom
para staging, que é "limpeza barata"); `table` materializa o resultado (bom para
marts, onde a query é cara e consultada muitas vezes).

---

## 2. `_sources.yml` — declarar as fontes (tabelas que o dbt LÊ, mas não cria)

As 3 tabelas brutas (`raw_ga4_events`, `raw_google_ads_ad_report`,
`raw_ab_test_metadata`) **não são criadas pelo dbt** — elas chegam ao schema
`raw` pelo `src/seed.py`, que roda fora do dbt. Para o dbt poder *usá-las* sem
"criá-las", eu as declaro como **sources** num arquivo YAML.

Por que declarar a fonte em vez de escrever o nome da tabela direto no SQL:

- **Desacopla o nome físico do uso.** Nos modelos eu escrevo
  `{{ source('raw', 'raw_ga4_events') }}` em vez de `mkt_ads.raw.raw_ga4_events`.
  Se o schema ou o banco mudar, eu altero num lugar só (o `_sources.yml`).
- **Habilita linhagem automática.** O dbt passa a enxergar que o modelo depende
  daquela fonte e desenha isso no DAG.
- **Permite testar a FONTE e checar *freshness*.** Posso afirmar invariantes já
  na entrada (ex.: `variant_id` é `unique` e `not_null`) e, se a fonte tivesse
  carga incremental, verificar se o dado está atualizado.

O detalhe mais importante que aprendi aqui: **testar a regra certa na camada
certa.** No `_sources.yml` eu coloquei `unique` em `variant_id` (metadata do A/B),
mas **não** coloquei `unique` em `event_id` do GA4 — porque o dado bruto tem 845
duplicatas *de propósito*. A unicidade de `event_id` é um invariante do
**staging** (depois da deduplicação), não da fonte. Se eu testasse `unique` na
fonte, ela falharia por algo que ainda nem deveria estar resolvido.

```yaml
sources:
  - name: raw
    database: mkt_ads
    schema: raw
    tables:
      - name: raw_ab_test_metadata
        columns:
          - name: variant_id
            data_tests: [unique, not_null]   # invariante legítimo da FONTE
      - name: raw_ga4_events
        columns:
          - name: event_id
            data_tests: [not_null]           # 'unique' só valerá no STAGING
```

---

## 3. Por que o `_` na frente de `_sources.yml`

O underscore no começo do nome **não tem significado funcional** para o dbt — ele
lê qualquer arquivo `.yml` dentro de `model-paths` independentemente do nome. É
uma **convenção de organização**: arquivos iniciados por `_` sobem para o **topo**
da listagem alfabética da pasta.

Por que isso é útil: dentro de `models/staging/` convivem os modelos
(`stg_*.sql`) e os arquivos de configuração/documentação (`_sources.yml`,
e normalmente um `_stg__models.yml` com testes e descrições). Prefixar com `_`
mantém os arquivos "meta" agrupados no topo, separados visualmente dos modelos.
É o mesmo espírito de deixar o `README` no topo de um diretório: facilita achar
o que descreve a pasta antes do que a pasta contém.

---

## 4. A convenção `stg_` — nomenclatura das camadas no dbt

No dbt o **nome do arquivo é o nome do objeto no banco**. Por isso a nomenclatura
não é cosmética: ela comunica em que **camada** cada modelo vive e qual é seu
papel. O padrão consagrado da comunidade dbt usa prefixos:

| Prefixo | Camada | Papel |
| :--- | :--- | :--- |
| `stg_` | **staging** | Limpeza 1:1 com a fonte: renomear colunas, castar tipos, deduplicar, filtrar lixo. Uma fonte → um `stg_`. |
| `int_` | **intermediate** | Passos de transformação reutilizáveis (joins, funil, atribuição) que ainda não são o produto final. |
| `fct_` / `dim_` | **marts** | Modelo final de consumo: fatos (métricas/eventos) e dimensões (contexto). |

O `stg_` em particular marca a **primeira camada de confiança**: a partir dela,
nenhum modelo acima precisa saber das sujeiras do raw. É onde eu, por exemplo,
vou converter `cost_micros` para reais (÷ 1.000.000), padronizar as UTMs
despadronizadas e deduplicar os `event_id` do GA4. O nome `stg_ab_test_metadata`
já diz, só de bater o olho, que aquilo é staging da tabela de metadata.

Por que seguir essa convenção em vez de inventar a minha:

- **Legibilidade imediata do DAG.** Olhando os nomes dá para reconstruir o fluxo
  `source → stg_ → int_ → fct_/dim_` sem abrir os arquivos.
- **Padrão de mercado.** Qualquer engenheiro que já usou dbt entende o projeto na
  hora — e é exatamente o tipo de convenção que se espera num portfólio.
- **Disciplina de camada.** O prefixo me força a respeitar o papel de cada
  modelo: `stg_` não faz regra de negócio, `fct_`/`dim_` não limpa dado sujo.
