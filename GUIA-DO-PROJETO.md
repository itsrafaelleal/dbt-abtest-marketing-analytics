# Guia do Projeto — Marketing Analytics & Teste A/B (ELT batch no Postgres)

> **Formato deste documento:** é um roteiro de MENTOR. Ele diz **o que** fazer e,
> principalmente, **por quê**. O código é seu — eu não escrevo por você. Em cada
> fase há um bloco **"Critério de pronto"**: só avance quando conseguir *provar*
> aquilo com um comando, não "achar" que está pronto. Essa disciplina (provar o
> invariante em vez de confiar no happy-path) é o que separa um pipeline de dados
> sério de um script que "funcionou na minha máquina".
>
> Ao longo do texto há blocos **[OPINIÃO DO SÊNIOR]** — são recomendações de
> boas práticas. Você pode discordar, mas discorde com um argumento.

---

## 0. A decisão que define o projeto (e por que ela está certa)

A ideia original era CDC (Debezium + Kafka). **Você descartou — e acertou.** Vale
registrar o raciocínio, porque ele *é* o entregável intelectual desta decisão:

- **CDC existe para capturar mudança de estado linha a linha num banco
  transacional (OLTP).** O caso clássico é um pedido que vai de `created` para
  `shipped`. É sobre *mutação de estado*.
- **Seus dados são append-only / agregados.** Um evento de GA4 acontece e nunca
  muda. O relatório do Google Ads do dia 01/09 não é "reescrito". Não há estado
  mutável para o CDC capturar. Forçar Debezium aqui seria uma solução procurando
  um problema.

> **Narrativa para entrevista:** "Avaliei CDC, mas meus dados são append-only.
> Usar Debezium ali seria teatro de arquitetura. Escolhi um ELT batch, que é a
> ferramenta certa para dados que chegam em lote e não mutam." Saber **quando
> NÃO usar** uma ferramenta vale tanto quanto saber usá-la.

### Arquitetura escolhida

```
   CSV (data lake / bronze)          Script de ingestão (pandas)
   • raw_ab_test_metadata            carrega os 3 arquivos
   • raw_google_ads_ad_report   ──►  "as-is", sem limpar nada
   • raw_ga4_events                  (sujeira preservada de propósito)
                                            │
                                            ▼
                               ┌─────────────────────────────┐
                               │   PostgreSQL (único motor)    │
                               │                               │
                               │  schema raw     ← ingestão    │
                               │  schema staging ← dbt limpa   │
                               │  schema marts   ← dbt agrega  │
                               └─────────────────────────────┘
                                            │
                                            ▼
                                  Looker Studio
                             (conector Postgres nativo)
                       scorecard, funil, ROAS, resultado do Z-test
```

### Decisões já travadas (não reabrir sem motivo)

| Decisão | Escolha | Por quê |
|---|---|---|
| Warehouse | **Postgres, e só ele** | É o substituto local e gratuito do BigQuery/Snowflake do catálogo. Sem DuckDB: duas engines sem CDC no meio seria complexidade sem propósito. |
| Ingestão | **Script Python (pandas)** | Controle sobre tipos, encoding e carga em lote. Veja por que *não* `dbt seed` na Fase 2. |
| BI | **Looker Studio + conector Postgres** | Agora que há um Postgres de verdade, o conector nativo é mais limpo que exportar para Sheets. |

---

## 1. Separe as camadas com SCHEMAS, não com bancos

Erro comum de quem começa: jogar tudo numa tabela só, ou criar vários bancos.
Dentro **do mesmo** Postgres, use schemas para materializar as camadas
bronze → silver → gold que o catálogo já desenha:

| Schema | Papel | Quem escreve |
|---|---|---|
| `raw` | Dados brutos, exatamente como vieram do CSV (sujeira e tudo) | seu script de ingestão |
| `staging` | Dados limpos, tipados, deduplicados (1 modelo por fonte) | dbt |
| `marts` | Tabelas de negócio: funil, atribuição, resultado do A/B | dbt |

> **[OPINIÃO DO SÊNIOR]** A camada `raw` nunca deve ser "arrumada" na ingestão.
> Carregue o CSV sujo como está. O motivo: se você limpar na carga, perde a
> fonte de verdade para *comparar* e *testar* sua limpeza depois. A auditoria
> ("95.000 eventos viraram 94.000 — cadê os 1.000::") só é possível se o bruto
> continua intacto em algum lugar. Limpeza é trabalho do dbt, com código
> versionado e testado — não de um script de carga.

---

## 2. Fases do projeto

Cada fase é um marco verificável. Faça na ordem — cada uma depende da anterior.

### Fase 1 — Subir o Postgres (Docker)

**O que fazer:** um `docker-compose.yml` com um serviço Postgres. Crie o banco
(ex: `mkt_analytics`), usuário e senha. Monte um volume para os dados
persistirem entre `docker compose down/up`.

**Porquês que você precisa defender:**

- **Por que Docker e não instalar o Postgres na máquina:** reprodutibilidade.
  Qualquer pessoa (ou o CI, ou você daqui a 6 meses) sobe o ambiente idêntico
  com um comando. É a diferença entre "funciona na minha máquina" e "funciona".
- **Por que volume nomeado:** sem volume, derrubar o container apaga os dados.
  Com volume, o estado sobrevive. (Mas veja a nota abaixo.)

> **[OPINIÃO DO SÊNIOR]** Fixe (*pin*) a versão da imagem — `postgres:17.6`, não
> `postgres:latest`. `latest` muda sem avisar e quebra seu projeto no pior
> momento. Pinning é higiene básica de produção. No `healthcheck`, use
> `pg_isready` para que a Fase 2 possa assumir um banco pronto em vez de dormir
> um `sleep 10` torto.

**Critério de pronto:**
- `docker compose up -d` sobe o Postgres e o healthcheck fica `healthy`.
- `psql` (ou `docker exec`) conecta e `\l` lista o banco criado.
- Os 3 schemas (`raw`, `staging`, `marts`) existem.

---

### Fase 2 — Ingestão dos CSVs para o schema `raw` (pandas)

**O que fazer:** um script Python que lê os 3 CSVs de
`data/dados-mkt/raw/` e grava 3 tabelas no schema `raw` do Postgres:
`raw.ab_test_metadata`, `raw.google_ads_ad_report`, `raw.ga4_events`.

**Decisões de implementação que você precisa entender:**

- **Por que script pandas e NÃO `dbt seed`:** `dbt seed` foi feito para
  pequenos CSVs de apoio (listas de-para, mapeamentos de país), tipicamente
  poucas centenas de linhas. Seus 97.278 eventos de GA4 fariam o `seed` rastejar
  e versionariam um CSV gigante no git. Ingestão de volume é trabalho de um
  carregador dedicado. **Saber essa fronteira é conhecimento de dbt que
  entrevistador cobra.**

- **Como carregar com performance:** `df.to_sql(..., method='multi')` já ajuda,
  mas a forma canônica e rápida no Postgres é o `COPY` (via
  `copy_expert`/`copy_from` do psycopg, ou escrevendo um buffer CSV). Insert
  linha-a-linha para 97k linhas é lento e errado. Aprenda o `COPY` — é o caminho
  colunar nativo do Postgres.

- **Tipos na carga:** aqui você tem uma escolha de filosofia. O caminho mais
  honesto para a camada `raw` é carregar **tudo como texto** (`TEXT`) e deixar
  os `CAST` para o dbt no staging. Por quê: se você tentar tipar `cost_micros`
  como inteiro já na carga e uma linha vier suja, a carga inteira falha e você
  perde a sujeira que queria estudar. `raw` recebe; `staging` valida e tipa.

> **[OPINIÃO DO SÊNIOR]** Seu script de ingestão precisa ser **idempotente**:
> rodar duas vezes não pode duplicar dados. O padrão simples é `TRUNCATE`
> (ou `DROP/CREATE`) a tabela `raw` antes de carregar — a fonte de verdade é o
> CSV, então recarregar do zero é seguro e previsível. Um `append` cego é o bug
> clássico que dobra sua base silenciosamente. Deixe isso explícito no código.

**Critério de pronto (prove, não confie):**
- `SELECT count(*) FROM raw.ga4_events` → **97.278**.
- `SELECT count(*) FROM raw.google_ads_ad_report` → **720**.
- `SELECT count(*) FROM raw.ab_test_metadata` → **2**.
- Rodar o script 2x **não** muda nenhuma dessas contagens (idempotência).

---

### Fase 3 — Conectar o dbt ao Postgres

**O que fazer:** inicializar um projeto dbt com o adapter `dbt-postgres`.
Configurar o `profiles.yml` apontando para o Postgres do Docker, e o
`dbt_project.yml` com a materialização por camada.

**Porquês:**

- **Por que `dbt-postgres` e não outro adapter:** é o adapter do seu warehouse.
  Trivial, mas é onde gente erra ao copiar tutorial de BigQuery.
- **Materialização por camada:** configure `staging` como `view` (barato,
  sempre fresco) e `marts` como `table` (materializado, rápido para o Looker
  ler). Essa é a convenção padrão e o entrevistador espera que você saiba o
  trade-off: view não ocupa espaço mas recalcula a cada query; table ocupa
  espaço mas serve leitura rápida ao BI.

> **[OPINIÃO DO SÊNIOR]** Nunca versione segredos. A senha do Postgres vai no
> `profiles.yml` via variável de ambiente (`{{ env_var('PG_PASSWORD') }}`),
> nunca hard-coded. E coloque `profiles.yml` com credenciais fora do git se ele
> contiver segredo literal. Credencial em commit é o erro de segurança nº 1 de
> projeto júnior.

**Critério de pronto:**
- `dbt debug` conecta com sucesso ("All checks passed").
- `dbt source freshness` (se você declarar as fontes `raw`) ou ao menos um
  `dbt run` trivial materializa no schema certo.

---

### Fase 4 — Modelar com dbt: staging → marts

Esta é a fase onde está o trabalho de engenharia de verdade. Camadas:

#### 4.1 — staging (limpar e tipar)

Um modelo por fonte (`stg_ga4_events`, `stg_google_ads`, `stg_ab_test`). Aqui
você trata **todas** as anomalias do catálogo (seção 5). Regras críticas:

- **`cost_micros` → dividir por 1.000.000** no staging do Ads. Se esquecer,
  CPA e ROAS erram por um fator de **um milhão**. É o erro mais caro do projeto.
- **Normalizar UTMs** (`trim` + `lower`) ANTES de qualquer join de atribuição.
  `"Google "` e `"google"` são a mesma origem; sem normalizar, o join de
  atribuição perde ~4,5% do tráfego silenciosamente.
- **Deduplicar GA4 por `event_id`.** Mas atenção à ordem: rankear e pegar 1 por
  `event_id`. Dedup mal feito ou superdimensiona (não dedupa) ou derruba demais.
- **Filtrar bots e QA interno** (`user_pseudo_id LIKE 'bot_crawler_%'` e
  `traffic_source_source = 'internal_qa'`).

> **[OPINIÃO DO SÊNIOR]** Cada transformação de limpeza deve ter um **comentário
> dizendo quantas linhas ela afeta e por quê**. Não é decoração: é documentação
> de linhagem. "-- remove 845 duplicatas por event_id (F5 do usuário)" vale mais
> que qualquer README. E facilita o próximo item: testar.

#### 4.2 — intermediate (opcional, mas recomendado)

Modelos de apoio: a atribuição (ligar evento GA4 à variante via `utm_content`),
e a montagem do funil por sessão. Separar isso de `marts` mantém cada modelo
pequeno e testável.

#### 4.3 — marts (negócio)

- **`fct_ga4_events`** — eventos limpos, atribuídos à variante A/B.
- **`fct_ads_daily`** — gasto diário por campanha/variante, com `cost` em reais.
- **`mart_ab_test_result`** — o entregável. Por variante: sessões, conversões,
  taxa de conversão, CPA, ROAS, e o **Z-test de proporções** entre A e B
  (a diferença de conversão é estatisticamente significativa ou é ruído::).

> **[OPINIÃO DO SÊNIOR]** O Z-test é o que transforma este projeto de "dashboard
> bonito" em "decisão de negócio". Qualquer um soma conversões; poucos juniores
> sabem responder *"essa diferença é significativa a 95% de confiança::"*.
> Calcule a estatística Z e o p-valor no SQL do mart (dá para fazer com as
> funções de agregação + uma aproximação da normal, ou materialize os números
> base e faça o teste numa view). Documente a hipótese nula no comentário.

---

### Fase 5 — Testes de invariante (o que separa júnior de júnior bom)

Os testes genéricos do dbt (`unique`, `not_null`, `accepted_values`,
`relationships`) são o mínimo. Declare-os nos `.yml` das fontes e modelos. Mas o
diferencial são os **testes de invariante** — asserções sobre regras que *têm*
que valer e que os genéricos não pegam:

- **Reconciliação de contagem:** `stg_ga4_events` após limpeza deve ter
  exatamente **97.278 − 845 (dups) − 304 (bots/QA) = 96.129** linhas. Escreva um
  teste singular (`tests/assert_ga4_rowcount.sql`) que falha se o número mudar.
  Isso pega tanto "esqueci de dedupar" quanto "dedupei demais".
- **O join de atribuição não pode multiplicar linhas:** depois de ligar evento →
  variante, a contagem de eventos tem que ser a mesma de antes do join. Se
  inflou, seu join tem fan-out (chave duplicada do lado da dimensão).
- **Toda conversão (`purchase`) tem `purchase_revenue_brl` não-nulo** e todo
  evento que não é `purchase` tem receita nula. Invariante do catálogo.
- **`cost` em reais está num intervalo plausível** (não ficou em micros por
  engano). Um teste que falha se o custo médio diário passar de, digamos,
  R$ 100.000 pega o erro do fator 1e6 na hora.

> **[OPINIÃO DO SÊNIOR — o mais importante do guia]** **Prove que o teste pega o
> erro.** Corrompa de propósito: remova 10 linhas de um fato, ou comente a
> divisão de `cost_micros`, rode `dbt test` e confirme que ele fica **vermelho**.
> Um teste que nunca falhou não prova nada — passa à toa até numa tabela vazia.
> Essa prática ("red before green") é o que distingue quem *entende* teste de
> quem *copia* teste.

**Critério de pronto:**
- `dbt build` roda modelos + testes e passa inteiro.
- Você conseguiu fazer cada teste de invariante falhar com uma corrupção
  proposital, e depois voltar ao verde.

---

### Fase 6 — Looker Studio (conector Postgres)

**O que fazer:** conectar o Looker Studio ao schema `marts` do seu Postgres via
conector PostgreSQL nativo.

**Atenção prática (não tropece aqui):**
- O Looker Studio é um serviço do Google na nuvem — ele precisa **alcançar** seu
  Postgres. Um Postgres em `localhost` no seu homelab não é visível para a
  internet. Você vai precisar de um túnel (ex: `cloudflared`/`ngrok`) ou expor a
  porta de forma controlada. **Decida e documente como.**
- Exponha **apenas** o schema `marts`, com um usuário Postgres **somente-leitura**
  dedicado ao Looker. Nunca o superusuário.

> **[OPINIÃO DO SÊNIOR]** Expor banco para a internet é ação de risco. Crie um
> role `looker_ro` com `GRANT SELECT` só em `marts`, senha forte, e prefira um
> túnel autenticado a abrir a porta 5432 para o mundo. Mencionar essa
> preocupação de segurança num projeto de portfólio impressiona — mostra que
> você pensa em superfície de ataque, não só em "funcionou".

**Dashboards a construir (o catálogo sugere):**
- Scorecard da variante vencedora (conversão, CPA, ROAS).
- Funil de drop-off: `page_view → view_item → add_to_cart → begin_checkout →
  purchase`.
- Curva de ROAS por variante ao longo dos 30 dias.
- Resultado do Z-test: a Variante B é estatisticamente melhor, ou é ruído::

**Critério de pronto:** o dashboard responde à pergunta de negócio —
*"a Variante B (Frete Grátis + Entrega 24h) converteu significativamente melhor
que a A (15% OFF)::"* — com número, intervalo de confiança e uma decisão
("adotar B" / "inconclusivo, rodar mais tempo").

---

## 3. Ordem de ataque sugerida (não pule etapas)

1. Subir Postgres no Docker, criar banco e os 3 schemas (Fase 1).
2. Script pandas idempotente: CSV → `raw.*` (Fase 2).
3. Conectar dbt, `dbt debug` verde (Fase 3).
4. Modelar staging (limpeza das anomalias) → marts (funil, atribuição, Z-test)
   (Fase 4).
5. Testes de invariante + prova de que falham quando devem (Fase 5).
6. Looker Studio no `marts` via conector Postgres (Fase 6).

> **[OPINIÃO DO SÊNIOR]** Faça um `Makefile` com um alvo `rebuild` que roda a
> cadeia inteira do zero: sobe o Docker, trunca e recarrega o `raw`, roda
> `dbt build`. **Rode isso antes de cada push.** O rebuild limpo (não o run
> incremental) é o que revela os bugs que o estado acumulado esconde — por
> exemplo, uma ingestão que só era idempotente "por sorte" porque o banco já
> estava do jeito certo.

---

## 4. Perguntas para você responder antes de codar

Pense nelas (ou me chame para discutir) — mudam o desenho:

1. **Granularidade do `mart_ab_test_result`::** por variante (A vs B), ou por
   variante × dia (para ver a evolução no tempo):: Sugiro ter os dois: um
   agregado total para o Z-test, e um diário para a curva de ROAS.
2. **Qual é a "conversão" exatamente::** `purchase`:: Ou você quer medir cada
   etapa do funil:: Defina a métrica primária do teste antes de calcular o Z.
3. **Atribuição:** o evento GA4 se liga à variante por `utm_content`
   (prefixo `variant_a_` / `variant_b_`):: Confirme a chave de junção com o
   catálogo antes de escrever o join — é onde a sujeira de UTM morde.
4. **Como o Looker alcança o Postgres do homelab::** túnel:: porta exposta::
   Decida a topologia de rede e a segurança (role somente-leitura).

---

## 5. Armadilhas específicas dos SEUS dados (do catálogo) — trate TODAS no staging

| Anomalia | Tabela | Volume | Como tratar |
|---|---|---:|---|
| `cost_micros` ×1.000.000 | `raw.google_ads_ad_report` | 720 (100%) | dividir por 1e6 no staging; senão CPA/ROAS erram por 1M× |
| UTMs despadronizadas (`"Google "`, `"CPC"`) | `raw.ga4_events` | ~4.333 (~4,5%) | `trim` + `lower` ANTES de qualquer join de atribuição |
| Eventos duplicados por `event_id` | `raw.ga4_events` | 845 (~0,9%) | dedup no staging (rankear por `event_id`, pegar 1); senão superdimensiona tráfego e receita |
| Bots / QA interno | `raw.ga4_events` | 304 (~0,3%) | filtrar `user_pseudo_id LIKE 'bot_crawler_%'` e `traffic_source_source = 'internal_qa'` |
| Spike de CPC fim de semana | `raw.google_ads_ad_report` | 24 (dias 19–20/09) | **não apagar** — contextualizar no relatório; é dado real |

Conta de reconciliação do GA4 limpo: **97.278 − 845 − 304 = 96.129** linhas.
Use esse número no seu teste de invariante da Fase 5.

---

## 6. Dados de origem (referência rápida)

Local: `data/dados-mkt/raw/`

| Arquivo | Linhas | Grão | Chave(s) |
|---|---:|---|---|
| `ab_test_metadata/raw_ab_test_metadata.csv` | 2 | 1 por variante (A/B) | `test_id` + `variant_id` |
| `google_ads/raw_google_ads_ad_report.csv` | 720 | dia × campanha × ad_group × ad × device | `date_day`+`campaign_id`+`ad_group_id`+`ad_id`+`device` |
| `ga4_events/raw_ga4_events.csv` | 97.278 | 1 por evento disparado | `event_id` (com duplicatas a tratar) |

Catálogo completo (dicionário coluna a coluna + anomalias):
`data/dados-mkt/raw/catalogo-dados-mkt.md` — **leia antes da Fase 4.**

Semente do experimento (contexto de negócio):
- `EXP_2026_Q3_01` — teste de proposta de valor na landing page.
- Variante **A** (controle): "15% OFF Primeira Compra", campanha `20491001`,
  `utm_content` prefixo `variant_a_desconto15`, página `/oferta-especial-a`.
- Variante **B** (tratamento): "Frete Grátis + Entrega 24h", campanha `20491002`,
  `utm_content` prefixo `variant_b_frete24h`, página `/oferta-especial-b`.
- Hipótese: a B reduz fricção no checkout e eleva conversão em +20%. Janela:
  2026-09-01 a 2026-09-30.

---

*Guia de mentoria. Dúvida em qualquer fase, me chame para discutir a decisão —
mas o código é seu. Eu reviso, aponto riscos e sugiro boas práticas; a
implementação é sua para você aprender de verdade.*
