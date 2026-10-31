# Insights de Negócio & Data Storytelling — Experimento A/B (`EXP_2026_Q3_01`)

Este documento consolida as conclusões analíticas, as perguntas de negócio respondidas pela camada **Gold (`marts`)** e a narrativa de dados  extraída do experimento **`EXP_2026_Q3_01`** (*Teste A/B de Proposta de Valor em Landing Page*, realizado de `01/09/2026` a `30/09/2026`).

---

## Oportunidades de Análise e Perguntas de Negócio

###
A exploração estatística dos dados do projeto revela **5 grandes descobertas de negócio** que guiam a narrativa visual do dashboard:

1. **Veredito Inequívoco do Experimento:**
   A **Variante B (Frete Grátis + Entrega 24h)** vence em todas as frentes: eleva a conversão real de **2,76% para 3,68%** (**+33,0% de uplift**, superando a hipótese inicial de +20%), reduz o CPA de **R$ 94,98 para R$ 68,51 (-27,9%)**, eleva o ROAS de **2,26x para 3,28x (+45,1%)** e gera **R$ 79.494,85** a mais em receita bruta com apenas **R$ 4.459,15** a mais de investimento em mídia (`p < 0,0001`).

2. **Onde a Variante B Ganha o Jogo no Funil:**
   A superioridade da Variante B não ocorre apenas no topo — ela melhora a retenção em todas as transições até o checkout:
   * `page_view → view_item`: **51,8% (B)** vs. **48,2% (A)**
   * `view_item → add_to_cart`: **34,0% (B)** vs. **29,9% (A)**
   * `add_to_cart → begin_checkout`: **51,2% (B)** vs. **44,8% (A)** — *maior redução de fricção: o argumento de Frete Grátis elimina o abandono típico de carrinho no momento de calcular o frete!*
   * `begin_checkout → purchase`: **40,6% (B)** vs. **42,8% (A)**.

3. **O Efeito Dispositivo (Desktop vs. Mobile):**
   No **Desktop**, a Variante A apresentava um desempenho crítico (`ROAS 1,80x`, `CPA R$ 118,91`, `CR 2,73%`). A Variante B transformou o Desktop no canal de maior taxa de conversão (`CR 4,22%`, `ROAS 3,14x`, `CPA R$ 70,77`), enquanto no **Mobile** (que concentra ~68% das sessões) o ROAS saltou de `2,47x` para `3,35x`.

4. **Anomalia Temporal (Spike de Leilão em 19–20/09):**
   Nos dias **19 e 20 de setembro** (fim de semana), o CPC médio subiu de **R$ 2,35 para R$ 2,71–2,81 (+19%)**, comprimindo o ROAS global daquele fim de semana para `2,45x`. Já nos outros 3 fins de semana do mês, o CPC manteve-se estável em **R$ 2,35**, com ROAS superior ao dos dias úteis (`2,99x` vs. `2,77x`).

5. **Tráfego Não-Atribuído (Orgânico/Direto):**
   Há **4.997 sessões** (`5.005` eventos `page_view` vindos de `google/organic`, `direct/none` e `instagram/organic` concentrados em SP) com `variant_id IS NULL` e **zero conversões**, demonstrando que 100% das compras do período vieram das campanhas de busca paga do experimento.

---

## Resumo Comparativo das Variantes (Camada Gold)

| Indicador | Variante A (Controle — 15% OFF) | Variante B (Tratamento — Frete Grátis + 24h) | Variação / Uplift (B vs. A) | Leitura de Negócio |
| :--- | :---: | :---: | :---: | :--- |
| **Sessões Reais (`page_view`)** | `24.240` | `27.039` | `+11,5%` | Maior atratividade dos criativos de Frete Grátis |
| **Conversões (`purchase`)** | `670` | `994` | `+48,4%` | Ganho expressivo de volume de pedidos |
| **Taxa de Conversão (`CR`)** | `2,76%` | `3,68%` | **`+33,0%`** | Supera com folga a meta de `+20%` da hipótese |
| **Investimento em Mídia (`Custo`)** | `R$ 63.635,30` | `R$ 68.094,45` | `+7,0%` | Orçamento equilibrado entre as duas campanhas |
| **Receita Total (`Receita`)** | `R$ 143.594,76` | `R$ 223.089,61` | **`+55,4%`** | `+R$ 79.494,85` gerados pela Variante B |
| **Custo por Aquisição (`CPA`)** | `R$ 94,98` | `R$ 68,51` | **`-27,9%`** | Economia de `R$ 26,47` por cliente adquirido |
| **Retorno sobre Mídia (`ROAS`)** | `2,26x` | `3,28x` | **`+45,1%`** | Alta eficiência financeira do tratamento |
| **Ticket Médio (`AOV`)** | `R$ 214,32` | `R$ 224,44` | `+4,7%` | Sem canibalização de margem pelo desconto de 15% |
| **Significância (`Z-Test`)** | — | `p < 0,0001` | **Significativo (99,9%)** | Rejeita $H_0$; recomendação de rollout de 100% para B |

