# Aprendizados

> Registro das decisões técnicas e do **porquê** de cada boa prática adotada
> neste projeto. Cada aprendizado parte de algo concreto que eu fiz no código. A ordem segue a lógica de construção do pipeline: primeiro
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

---

## 5. Identificadores são texto, mesmo quando parecem número

Ao tipar o staging do Google Ads, o `campaign_id` (e `ad_group_id`, `ad_id`)
tinha vindo como `bigint` do pandas — porque só continha dígitos. Mudei para
`text`. A regra geral de engenharia:

> **Identificadores são texto, mesmo quando parecem número.**

O raciocínio: eu nunca vou **somar** ou **tirar a média** de um `campaign_id`.
Então ele não é um número — é um **rótulo**. Número é aquilo com que se faz
conta (`clicks`, `impressions`, `cost`). Rótulo é aquilo que identifica
(`campaign_id`, `ad_id`).

Tratar ID como inteiro é uma fonte clássica de bug:

- **Perde zero à esquerda:** um id `"00101"` vira `101` como inteiro — e os dois
  deixam de bater num join.
- **Estoura o range:** ids muito grandes passam do limite do inteiro e
  truncam/arredondam silenciosamente.
- **Quebra o join:** se de um lado o id é `text` e do outro é `bigint`, a
  comparação falha ou exige cast na hora. No meu caso, `campaign_id` é a chave
  entre `raw_ab_test_metadata`, `raw_google_ads_ad_report` e os eventos — todos
  precisam ser `text` para o join funcionar sem surpresa.

Por isso, no `stg_google_ads_ad_report` eu fiz `campaign_id::text as campaign_id`
e tratei todos os ids como rótulo.

---

## 6. O que é UTM — a chave de atribuição do projeto

**UTM = Urchin Tracking Module.** "Urchin" era o nome da empresa que criou o
Google Analytics; o nome pegou. Na prática, UTMs são **parâmetros grudados no
final da URL** de um link, usados para rastrear de onde veio o visitante.

Quando alguém clica num anúncio, a URL de destino não é só
`loja.exemplo.com.br/oferta-a` — ela vem com os parâmetros:

```
https://loja.exemplo.com.br/oferta-a?utm_source=google&utm_medium=cpc&utm_campaign=search_ab_promo_q3&utm_content=variant_b_frete24h
                                     └──────────────────── os parâmetros UTM ────────────────────┘
```

Tudo depois do `?` são os UTMs. Quando o usuário chega no site, o GA4 **lê esses
parâmetros da URL e grava em cada evento**. É assim que o evento "sabe" de qual
anúncio veio.

Os quatro parâmetros, do mais amplo ao mais específico (funil de granularidade,
de "canal" até "anúncio individual"):

| Parâmetro | Responde | Exemplo no projeto |
| :--- | :--- | :--- |
| `utm_source` | **De qual plataforma?** A origem. | `google` |
| `utm_medium` | **Por qual tipo de mídia?** O canal. | `cpc` (custo por clique / pago) |
| `utm_campaign` | **De qual campanha?** O agrupamento de negócio. | `search_ab_promo_q3` |
| `utm_content` | **De qual anúncio/criativo específico?** | `variant_b_frete24h` |

O `utm_content` é o coração da atribuição deste projeto: o prefixo
(`variant_a_` / `variant_b_`) diz **qual variante o usuário viu**. É por ele que
eu ligo um evento do GA4 à variante A/B. Por isso normalizar UTM
(`lower` + `trim`) no staging é pré-requisito: sem isso, `"Google "` e `"google"`
não batem no join e eu perderia ~4,5% das conversões silenciosamente.

---

## 7. `cost_micros` — custo em micros e por que o Google faz isso

No `raw_google_ads_ad_report`, o custo vem como `cost_micros`: o valor monetário
real **multiplicado por 1.000.000**.

A regra de conversão:

```
1 real (R$ 1,00) = 1.000.000 micros
```

Então o valor na tabela:

```
cost_micros = 515570000  ->  515570000 / 1.000.000  =  R$ 515,57
```

**Por que o Google armazena assim:** é uma decisão de engenharia da API do Google
Ads (e de conectores como o Fivetran) para **evitar ponto flutuante** no
armazenamento e no tráfego de dados.

Dinheiro com casa decimal é problemático: `float`/`double` tem erro de
arredondamento (o clássico `0.1 + 0.2 = 0.30000000000000004`). Para uma API que
processa bilhões em gasto de anúncios no mundo todo, esse erro acumula e vira
divergência financeira.

A solução é guardar tudo como **inteiro**, numa unidade pequena o bastante para
nunca precisar de decimal. Em vez de `R$ 515,57` (decimal, perigoso), guarda
`515570000` (inteiro, exato). Micros = milionésimos — é o mesmo princípio de
guardar dinheiro em centavos, só que o Google foi para milionésimos para ter
precisão extra (frações de centavo em lances de leilão de anúncio).

No staging eu desfaço isso: `(cost_micros / 1000000.0)::numeric(12,2) as cost_brl`.
Dois cuidados que aprendi aqui:

- **O `.0` no divisor** (`1000000.0`): como `cost_micros` é inteiro, dividir por
  inteiro faria **divisão inteira** e truncaria os centavos (`515570000 / 1000000
  = 515`, perdendo o `,57`). O `.0` força resultado decimal.
- **Renomear para `cost_brl`:** depois de dividir, a unidade mudou. Deixar o nome
  `cost_micros` enganaria quem lesse o modelo. O nome da coluna é documentação.

Esse é o erro mais caro do projeto: esquecer a divisão faz CPA e ROAS errarem por
um fator de **um milhão**.

---

## 8. `purchase_revenue_brl` — por que `float`/`double` é veneno para dinheiro

Ao olhar o tipo da coluna `purchase_revenue_brl` no Postgres, ela estava como
`double precision` — porque o pandas inferiu `float64` ao ler o CSV. Para
**receita**, isso é um problema silencioso que precisa ser corrigido no staging.

### O defeito do ponto flutuante (IEEE 754)

`float`/`double` guardam o número em **binário**, e nem todo decimal tem
representação binária exata. O caso clássico:

```sql
select 0.1::double precision + 0.2::double precision;
-- 0.30000000000000004   (e não 0.3)
```

Isoladamente o erro é minúsculo. O problema é a **agregação**: somar milhões de
receitas num mart (receita total por variante, ROAS) acumula esses resíduos e
produz divergência financeira — a empresa "perde" ou "inventa" dinheiro no
relatório. Em finanças, isso é inaceitável.

### A solução: tipo de ponto fixo exato (`numeric` / `decimal`)

O tipo `numeric` (sinônimo de `decimal`) guarda o número em **base 10**, sem erro
de arredondamento binário. É o tipo correto para dinheiro. No staging:

```sql
purchase_revenue_brl,                                               -- original (double)
cast(purchase_revenue_brl as numeric(12, 2)) as purchase_revenue_brl -- exato p/ cálculo
```

A assinatura `numeric(precisão, escala)`:

- **precisão** = total de dígitos; **escala** = dígitos após a vírgula.
- `numeric(12, 2)` → até 12 dígitos, 2 decimais → ideal para R\$ de e-commerce.

### Duas escolhas de boas práticas (e qual eu usei, e por quê)

A indústria consolidou **dois** padrões para dinheiro na camada Silver/staging:

| Padrão | Quando usar | Trade-off |
| :--- | :--- | :--- |
| **`numeric(12,2)`** (o que usei) | receita final em R\$, já arredondada em centavos (e-commerce) | semântica clara ("é dinheiro em reais"), suficiente para o projeto |
| **`numeric(19,4)`** ("padrão ouro") | sistemas com câmbio, juros, frações de centavo | 4 casas evitam perda em cálculos intermediários; suporta até ~999 trilhões |
| **`bigint` em "minor unit"** (centavos/micros) | AdTech, HFT, escala extrema onde inteiro é mais rápido | o BI precisa saber onde pôr a vírgula no final da esteira |

Escolhi `numeric(12,2)` porque `purchase_revenue_brl` é **receita final em reais,
já em centavos** — não há câmbio nem juros a proteger, então 4 casas seriam
precisão sem propósito, e o nome fica mais honesto com a 2ª casa. Se este fosse
um sistema financeiro com conversão de moeda, eu iria de `numeric(19,4)`.

### O insight do meu próprio projeto: as duas filosofias lado a lado

Vale conectar com o aprendizado 7 (`cost_micros`). O meu pipeline tem, de
propósito, as **duas estratégias** de dinheiro convivendo nas fontes:

- **Google Ads** mandou o custo como **inteiro em micros** (`cost_micros`) — o
  jeito "defensivo" da API, que nunca passa `float` pela rede.
- **GA4** mandou a receita como **`float64`** (`purchase_revenue_brl`) — o jeito
  "perigoso", que já chega com o risco de arredondamento embutido.

Ou seja: nem toda fonte segue a boa prática. O **staging é o ponto de
uniformização** — é onde eu converto ambos para o mesmo tipo exato (`numeric`),
independentemente de como a fonte entregou. Essa é a função da camada: a partir
do `stg_`, nenhum modelo acima precisa saber se o dado nasceu micro, centavo ou
float.

### Cuidados específicos deste campo

- **Não use `not_null` em `purchase_revenue_brl`.** Pelo catálogo, ele é `NULL`
  em todo evento que não é `purchase` — isso é correto, não é sujeira. Um teste
  `not_null` falharia de propósito. O `cast` lida bem com nulo (`NULL` casteado
  continua `NULL`).
- **Em Python/pandas**, o análogo de `numeric` é o `decimal.Decimal`: cálculos
  exatos em base 10. A regra é bloquear o `float` nativo para dinheiro.
- **Em Parquet**, existe o *logical type* `DECIMAL(p,s)`: fisicamente guarda como
  inteiro (ganho de compactação), mas a engine de leitura (Spark, DuckDB) sabe
  onde pôr a vírgula. O melhor dos dois mundos.
- **Em SQL Server**, evitar o tipo nativo `MONEY`: ele arredonda de forma
  agressiva em divisões intermediárias e gera erro em grandes cálculos. Prefira
  `DECIMAL`/`NUMERIC` sempre.

> **Resumo da regra:** dinheiro nunca mora em `float`/`double`. Na bronze,
> preserve como a fonte mandou (inteiro em micros/centavos, ou o próprio float).
> Na staging em diante, faça o cast explícito para `numeric`/`decimal` — ponto
> fixo, exato, com o nome da coluna dizendo a unidade.

---

## 9. O CSV não tem tipo — o tipo é uma inferência de quem lê

Investigando de onde vinha o `double precision` do `purchase_revenue_brl`, caí
numa pergunta que parecia boba mas não é: *"qual o tipo da coluna no CSV original?"*
A resposta correta é: **o CSV não tem tipo nenhum.**

### CSV é texto puro

Um arquivo `.csv` é só caracteres separados por vírgula. Abrindo a linha crua do
`raw_ga4_events.csv`, o trecho da receita é literalmente:

```
...,12000,,,"{...json...}"
        └┬┘
   purchase_revenue_brl = nada entre duas vírgulas (vazio)
```

Não existe "coluna é `float`" ou "coluna é `int`" gravado no arquivo. O conceito
de tipo **não mora no CSV** — ele nasce no momento em que *algum programa lê* o
texto e decide, olhando o conteúdo, "isso aqui parece número, aquilo parece data".
Por isso a pergunta certa nunca é *"qual o tipo no CSV"*, e sim **"quem está
lendo, e como essa ferramenta infere o tipo?"**. A resposta muda conforme o leitor.

### No meu projeto, quem lê é o pandas → `float64`

O `src/seed.py` faz `pd.read_csv(...)` sem passar `dtype=`. Isso deixa o **pandas
adivinhar** o tipo de cada coluna. Rodando a leitura só dessa coluna numa amostra
de 50.000 linhas, o resultado foi:

```text
dtype inferido pelo pandas: float64
qtd de nulos (NaN):  49112
qtd preenchidos:       888
amostra preenchida: [158.47, 241.18, 226.8, 194.14, 186.93]
```

Depois, no `to_sql`, o pandas traduz `float64` → **`double precision`** no
Postgres. Esse é exatamente o tipo que eu via no banco — não é propriedade do
dado, é **consequência de duas inferências em cadeia** (pandas, depois Postgres).

### A pegadinha: o `float64` tem DUAS causas somadas

Repara nos números acima: de 50 mil linhas, **49.112 são `NaN`** (vazias) e só
888 preenchidas. Isso bate com o catálogo — a receita só existe em eventos
`purchase`. E são justamente esses vazios que forçam o tipo:

1. **Os decimais** (`158.47`, `226.8`) já pediriam `float`.
2. **Os nulos** forçam `float` **mesmo que não houvesse decimais**. O motivo:
   o `int64` do pandas/NumPy **não consegue representar `NaN`**. Para guardar o
   "vazio" como `NaN`, o pandas é obrigado a **promover a coluna inteira para
   `float64`** (porque `NaN` é tecnicamente um valor de ponto flutuante).

A lição que fica: **um campo de inteiros vira `float64` no pandas só por ter
células vazias.** É uma fonte clássica de confusão — você vê `.0` grudado em ids
ou contadores e pensa "por que isso é float?", e a resposta quase sempre é "tem
nulo na coluna".

### Por que isso fecha o raciocínio do pipeline

- A **fonte (CSV) não carrega tipo** — é texto. O `float64`/`double precision` é
  uma **inferência automática**, não um fato sobre o dado.
- Essa inferência **"erra" para o propósito de negócio**: receita deveria ser
  exata (`numeric`), mas o pandas entrega aproximada (`float64`), porque ele só
  olha a *aparência* dos valores + a *presença de nulos* — ele não sabe que
  aquilo é dinheiro.
- Logo, o cast para `numeric(12,2)` no staging (aprendizado 8) **não é capricho**:
  é corrigir, na camada certa, um tipo que nasceu de um palpite da ferramenta de
  ingestão — não de uma decisão consciente sobre a semântica do dado.

> **Regra de bolso:** tipo em arquivo de texto (CSV/JSON) é sempre inferido, nunca
> declarado. Se o tipo importa (dinheiro, id, data), não confie no palpite do
> leitor — declare explicitamente (`dtype=` na ingestão, ou `cast()` no staging).

---

## 10. Gerar a `dim_date` com `generate_series`

Ao construir a `dim_date` (a dimensão de calendário do star schema) esbarrei numa
pergunta prática: como gerar uma linha por dia de 01/09 a 30/09 **sem** digitar 30
datas na mão nem depender de uma tabela estática? Havia dois caminhos — a macro
`dbt_utils.date_spine` (pacote externo) ou SQL nativo com `generate_series`.
Escolhi o `generate_series`, e o raciocínio dessa escolha é o aprendizado.

### A solução que usei: `generate_series` (nativo do Postgres)

A intuição é a mais simples possível: *pega a primeira data e vai somando +1 dia
até fechar a janela*. Esse algoritmo tem um nome pronto no Postgres —
`generate_series(início, fim, passo)` — que devolve uma linha por período:

```sql
with calendario as (
    select
        generate_series(
            '2026-09-01'::date,   -- primeira data (início da janela)
            '2026-09-30'::date,   -- última data (fim da janela, INCLUSIVO)
            '1 day'::interval     -- o passo: "+1 dia" por linha
        )::date as date_day
)
select
    date_day,
    extract(year  from date_day)::int      as ano,
    extract(month from date_day)::int      as mes,
    extract(day   from date_day)::int      as dia,
    extract(dow   from date_day) in (0,6)  as is_weekend  -- dow: 0=dom .. 6=sáb
from calendario
```

Três argumentos: de onde parte, onde para, de quanto em quanto. O banco cospe os
30 dias. As colunas derivadas (`ano`, `mes`, `dia`, `is_weekend`) são `extract()`
puro em cima da série.

### Por que `generate_series` e não `dbt_utils.date_spine`

A macro `date_spine` faz a mesma coisa de forma portável entre bancos (ela
compila para o SQL nativo de cada adapter). Preferi o `generate_series` porque:

- **Zero dependência externa.** Não preciso instalar nem versionar o pacote
  `dbt_utils` só para gerar 30 datas num projeto que é 100% Postgres.
- **Legibilidade para quem lê o modelo.** `generate_series(início, fim, passo)`
  diz exatamente o que faz; a macro esconde isso atrás de uma camada de Jinja.
- **O trade-off assumido:** se um dia o warehouse mudasse (ex.: para BigQuery ou
  Snowflake), o `generate_series` precisaria ser reescrito, enquanto a macro
  seguiria funcionando. Para um projeto fixo em Postgres, portabilidade que eu
  não vou usar é complexidade sem retorno.

> **Regra de bolso:** usar o nativo quando o projeto é mono-banco e a query é
> simples; usar a macro quando há múltiplos adapters ou a lógica é complexa o
> bastante para valer a abstração.

---

## 11. Conectar o BI ao banco: o problema de dar ao Looker um `host:porta` alcançável

Com os marts prontos no Postgres do homelab (`localhost:5499`), faltava o último
elo: expor a camada `marts` para o **Looker Studio**, que é um serviço na nuvem
do Google. Aqui o aprendizado não é de SQL, é de **arquitetura de rede e
segurança** — e foi tão trabalhoso quanto qualquer transformação.

O problema = o Looker Studio roda nos servidores do Google e só sabe
abrir uma **conexão TCP direta** a um `host:porta` alcançável pela internet. O
meu banco está em `localhost` — invisível para fora. Então ou eu trago o Looker
até o banco (túnel/exposição), ou levo o banco para a nuvem (hospedar).

Avaliei três famílias e o porquê de cada escolha:

| Opção | Veredito | Motivo |
| :--- | :--- | :--- |
| **Port forward no roteador** | ❌ descartada | Abre a porta 5499.exemple para a internet inteira; bots varrem 5432/5430 o tempo todo. Superfície de ataque alta demais para o ganho. |
| **Túnel Cloudflare** (já uso para SSH) | ❌ não serve ao Looker | Detalhado no aprendizado 12. |
| **`ngrok tcp`** | ✅ para provar | Dá um `host:porta` TCP público direto — exatamente o que o conector do Looker espera. Rápido e descartável. |
| **Postgres gerenciado** (Neon/Supabase) | ✅ para o permanente | Endereço estável, TLS nativo, independe do homelab ligado. Melhor narrativa de produção. |

ngrok é uma ferramenta de túnel reverso: ele pega um serviço que roda na sua máquina (em localhost) e dá a ele um endereço público
alcançável pela internet, sem você precisar abrir portas no roteador nem ter IP fixo.

Como funciona: o agente do ngrok abre uma conexão de dentro pra fora até os servidores dele, e tudo que chega naquele
endereço público é encaminhado de volta pro seu localhost.

Finalidade: expor rápido e de forma temporária algo local pro mundo — pra testar, demonstrar ou integrar com um serviço externo que precisa
te alcançar.


A decisão prática: **`ngrok` para validar o dashboard agora**, e **migrar o
`marts` para um Postgres gerenciado** quando quiser o portfólio "sempre no ar".

---

## 12. Por que o túnel Cloudflare (que já uso para SSH) não serve ao Looker

Eu já acesso o homelab por SSH sobre um **túnel Cloudflare** (`cloudflared`),
via um hostname próprio. A tentação natural foi reusar o mesmo túnel para o
Postgres. Não funciona — e entender o porquê ensina como o túnel realmente opera.

O túnel Cloudflare **transporta TCP sim** (SSH é TCP, e funciona). O problema é o
**outro lado da conexão**: para alcançar um serviço TCP arbitrário pelo túnel, o
cliente precisa rodar o binário `cloudflared access` localmente, que abre um
`localhost:porta` autenticado na máquina do cliente. No meu SSH isso funciona
porque a ponta é a **minha máquina**, onde eu instalo o que quiser (um
`ProxyCommand` no `~/.ssh/config`).

Mas o **Looker Studio é um serviço gerenciado do Google**: não tenho shell nele,
não instalo `cloudflared`, não rodo cliente nenhum. Sem o cliente na ponta, a
rota TCP do Cloudflare não é alcançável pelo Looker.

> **A lição:** "o túnel transporta TCP" não basta — é preciso perguntar **quem
> roda o cliente do túnel na outra ponta**. Para ferramenta gerenciada (SaaS)
> que não me dá esse controle, o túnel Cloudflare serve de **acesso de operador**
> (eu → homelab), não de **caminho de dados** (SaaS → banco).

---

## 13. Nunca exponha o dono do banco: role somente-leitura restrito ao schema de consumo

Assim que decidi expor o banco (mesmo que temporariamente, via `ngrok`), a
primeira regra foi: **o BI nunca conecta com o usuário dono do banco** (`dono`).
Expor o dono num endereço público daria a quem o descobrisse poder de **ler tudo
e escrever/apagar**. Criei um role dedicado, somente leitura, restrito ao schema
`marts` (o `sql/grant_looker_ro.sql`):

```sql
CREATE ROLE looker_ro LOGIN PASSWORD 'senha-forte';
GRANT CONNECT ON DATABASE mkt_ads TO looker_ro;
GRANT USAGE ON SCHEMA marts TO looker_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA marts TO looker_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT TO looker_ro;
```

O raciocínio de cada peça:

- **Separação de privilégio (princípio do menor privilégio).** O role só faz
  `SELECT`, só no `marts`. Nunca vê `raw`/`staging`, nunca escreve. O pior caso
  caso o endereço vaze é alguém **ler** as tabelas de consumo — não há escrita,
  não há exposição das camadas cruas.
- **`GRANT SELECT ON ALL TABLES`** cobre as tabelas que existem **hoje**.
- **`ALTER DEFAULT PRIVILEGES`** é a peça sutil: sem ela, toda vez que o `dbt
  build` recriasse as tabelas do `marts`, o `looker_ro` **perderia o acesso**
  (tabela nova = sem grant). O default privileges aplica a regra a objetos
  **futuros** criados pelo mesmo dono — some com o problema de "o dashboard
  quebrou depois que rodei o dbt".

> **A lição:** permissão em warehouse não é só "quem pode ler" — é "quem pode ler
> **o quê** e **até quando**". Em pipeline com rebuild (dbt), o default
> privileges é o que mantém o acesso vivo entre recriações.

---

## 14. Por que o Looker dizia "não há tabelas" — schema de busca e Custom Query

Conexão feita, credencial certa, e mesmo assim o Looker mostrava **"Não há
tabelas disponíveis nesse banco de dados."** Não era erro de permissão nem de
rede: o conector PostgreSQL do Looker lista, por padrão, as tabelas do schema
**`public`** — e no meu banco o `public` está **vazio** (tudo vive em `marts`,
`raw`, `staging`).

A saída foi usar a opção **Custom Query** (consulta personalizada) e **qualificar
o schema** explicitamente:

```sql
SELECT * FROM marts.fct_ab_test_results
```

Isso destravou um aprendizado de modelagem sobre **como montar as fontes do BI**.
Cada fato do `marts` tem um **grão** diferente:

- `fct_performance_diaria` → `(dia, variante, device)`
- `fct_funil` → `(dia, variante, device, etapa_funil)`
- `fct_ad_gasto_diario` → `(dia, campanha, variante, device)`
- `fct_ab_test_results` → `(variante)`

Por isso modelei **uma fonte de dados por tema** (uma query por fato + suas
dimensões). As queries ficaram documentadas em `sql/looker_queries.sql`.

> **A lição:** o "schema de busca" padrão de um conector de BI (vazio ≠ sem dados). 

---

## 15. SSL no conector: por que deixei desligado (e quando ligar)

Ao marcar "Enable SSL" no conector, o Looker pediu três arquivos — **server
certificate**, **client certificate** e **client private key**. Eu não tinha
nenhum: meu Postgres local não foi configurado com SSL. Deixei **desligado**, e
a conexão funcionou. O ponto é entender por que isso é aceitável **neste
cenário** e quando deixaria de ser.

- **O transporte já é criptografado pelo `ngrok`.** O trecho que viaja pela
  internet pública (Looker → ngrok) vai dentro do TLS do próprio túnel. O último
  pedaço (ngrok → Postgres) é `localhost`, dentro da própria máquina — não passa
  pela rede. Não há trecho "em texto puro" exposto na internet.
- **O que o SSL do Postgres acrescentaria** é proteção contra confiar no próprio
  ngrok (que descriptografa por um instante para reencaminhar). Para um ambiente
  **temporário, de prova, com dados fictícios**, esse risco é irrelevante — não
  justifica configurar certificado no Postgres local.
- **Quando passa a ser obrigatório:** na versão permanente em Postgres gerenciado
  (Neon/Supabase), o **TLS é nativo e já configurado** — ali eu ligo SSL sem
  precisar gerar nem subir certificado nenhum.

> **A lição:** "SSL ligado" não é bom ou ruim em abstrato — depende de **onde o
> dado trafega e quem já cuida da criptografia naquele trecho**. Com o túnel
> cuidando do transporte público, o TLS do banco seria uma segunda camada
> redundante; num banco exposto direto, seria indispensável.


---

## 16. Por que usar o Z-Test de proporções — e por que ele é o que dá sentido ao A/B

A `fct_ab_test_results` poderia parar em "quem converteu mais": basta um
`GROUP BY variant_id` com `conversoes / sessoes`. O problema é que essa resposta
é **perigosamente incompleta** — e o Z-Test é exatamente o que deixa o resultado mais confiavel.

### O problema que o teste resolve

Suponha o resultado do experimento:

| Variante | Sessões | Conversões | Taxa (CR) |
| :--- | :---: | :---: | :---: |
| A (controle) | 500 | 50 | 10% |
| B (tratamento) | 500 | 60 | 12% |

A leitura ingênua é "B converteu 12% contra 10%, logo B venceu". **Não
necessariamente.** Essa diferença pode ser um efeito real da variante B **ou**
pode ser só o **acaso** de quais visitantes caíram em cada grupo naquele mês. Se
eu repetisse o teste, talvez A ganhasse. Decidir trocar a campanha com base numa
diferença que era ruído é o erro clássico — e caro — de quem lê A/B test só pela
métrica bruta.

### O que o Z-Test de proporções faz

Ele compara **duas proporções** (taxa de conversão = conversões ÷ sessões, onde
cada visitante é um "comprou / não comprou") e responde a pergunta certa:

> "Se A e B tivessem na verdade a **mesma** taxa de conversão (hipótese nula H₀),
> qual seria a chance de o acaso sozinho produzir uma diferença tão grande quanto
> a que eu observei?"

Dessa conta saem as duas colunas da tabela:

- **`z_stat`** — a distância da diferença observada até o "zero diferença",
  medida em desvios-padrão. Perto de 0 = taxas praticamente coladas; grande (em
  módulo, acima de ~1,96) = diferença expressiva em relação ao ruído esperado. O
  sinal indica a direção.
- **`p_valor`** — a tradução do `z_stat` em probabilidade: a chance de a diferença
  observada ser **puro acaso**. `p_valor = 0,03` → só 3% de chance de ser sorte
  (diferença provavelmente real); `p_valor = 0,40` → 40% de chance de ser ruído
  (não dá para confiar).

### A régua de decisão: significância

O corte de mercado é o nível de **5% (α = 0,05)**:

- **`p_valor < 0,05`** → diferença **estatisticamente significativa**: rejeito H₀
  e declaro uma vencedora.
- **`p_valor ≥ 0,05`** → **inconclusivo**: não há evidência de que B seja melhor;
  a diferença cabe dentro do acaso (em geral, sinal de que faltou amostra).

### Por que "de proporções" (e não outro teste)

A escolha do teste depende da **natureza da métrica**. Conversão é uma proporção
de eventos binários (comprou/não), então o teste certo é o **Z-Test de
proporções**. Se eu fosse comparar *ticket médio* em reais (variável contínua),
usaria um **t-test** — teste errado para a métrica dá conclusão errada.

### Por que isso importa no projeto

Sem o Z-Test, a evidencia não seria tão robusta. Com ele, a
`fct_ab_test_results` entrega não só "quem converteu mais", mas **"quem converteu
mais *e isso é confiável*"** — que é a única resposta que sustenta uma decisão de
negócio.

> **A ressalva honesta:** o p-valor diz se a diferença é **real**, não se ela é
> **grande o bastante para valer a pena**. Essa segunda pergunta (tamanho do
> efeito e retorno financeiro) se lê junto com CPA e ROAS. **Significância
> estatística ≠ relevância prática
