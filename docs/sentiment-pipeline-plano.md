
# Pipeline de Análise de Sentimento (Cleitin) — Plano

**Goal:** alvo configurável → coleta de frases → classificação 3-way com LLM free (snapshot fixo) → curva por período → relatório no Discord, a R$0, com honestidade estatística embutida.

## 1. ARQUITETURA

### 1.1 Arquivos

```
db/migrate/20260811000001_create_sentiment_pipeline.rb    — 4 tabelas
app/models/  sentiment_target.rb  sentiment_run.rb  sentiment_phrase.rb  sentiment_label.rb
lib/research/sentiment/
  collector.rb        — orquestra a coleta a partir do frozen_spec
  sources/reddit.rb   — threads + comentários COM timestamp
  classifier.rb       — lotes de 100, JSON enum, temp 0, 1 retry, nunca default
  llm_route.rb        — escada de rotas free + cota diária
  aggregator.rb       — buckets, saldo proporcional, min 30, ΔS
  stability.rb        — TARa (3x o mesmo lote)
  agreement.rb        — kappa de Cohen (humano × modelo)
app/services/sentiment/message_builder.rb   — texto Discord (sem anexo)
app/jobs/  sentiment_analysis_job.rb   sentiment_digest_job.rb
app/tools/sentiment_tools.rb  — SentimentTargetTool / SentimentRunTool / SentimentReportTool
config/prompts/system/  sentiment_classify.yml   sentiment_subtype.yml
```

`lib/research/**` é autoloadado (`config/application.rb:18` só ignora `assets tasks scraping llm`) → **sem `require_relative`** nos arquivos novos. Em testes de `app/tools/`, `require_relative` explícito continua obrigatório (MEMORY.md 2026-03-23).

### 1.2 Tabelas (1 migration)

| Tabela | Colunas-chave | Por quê |
|---|---|---|
| `sentiment_targets` | `name` (uniq), `query`, `sources` (csv; fase 1 `"reddit"`), `window_days` (30), `bucket` (`day`\|`week`), `max_phrases` (600), `active` | Alvo é dado, não código. Máx. 5 ativos (mesmo padrão de `Topic`). |
| `sentiment_runs` | `target_id`, `status`, **`frozen_spec` (JSON)**, `window_start/end`, `model_id`, `prompt_version`, `snapshot_pinned`, `collected/rejected/classified/unparsed_count`, `tara`, `started_at`, `finished_at`, `error` | `frozen_spec` gravado **antes do primeiro fetch** = o anti-viés do SOTA virado linha de banco. O Aggregator lê dele, não do target. |
| `sentiment_phrases` | `run_id`, `source`, `external_id`, `permalink`, `author`, `text`, `posted_at` (nullable), `collected_at`; uniq `(run_id, external_id)` | Idempotência da coleta. `posted_at` nulo é visível, não silencioso. |
| `sentiment_labels` | `phrase_id`, `run_id`, `pass` (1\|2), `attempt` (1..3), `label`, `confidence`, `model_id`, `prompt_version`, `batch_index`; uniq `(phrase_id, pass, attempt)` | A mesma frase é rotulada 3× no TARa e 2× nas duas passadas. |

Enums: pass 1 `positive|negative|neutral`; pass 2 `reclamacao|emocao|sarcasmo|indefinido`.

### 1.3 Configuração do alvo

**Recomendo DB + tool no chat, owner-only** (`ManagementToolBase`, allowlist `DISCORD_OWNER_IDS` — padrão já ratificado em `profile_management_tools.rb`). YAML exigiria deploy para trocar de alvo; e o `frozen_spec` copia o target no disparo, então editar o alvo depois não contamina run antigo. Alternativa é decisão do dono (§5.3).

### 1.4 Entrega

Canal de digest via `DigestChannel#ensure_digest_channel` + `DiscordMessageChunker`, igual aos outros jobs. **Sem anexo.** Curva como sparkline de blocos em bloco de código, números ao lado.

## 2. PIPELINE

### (a) Coleta — Fase 1 é Reddit, e só

| Fonte | O que entrega hoje no repo | Fase 1 |
|---|---|---|
| Reddit | `search` → permalinks; `from_page` → até 120 comentários (depth ≤3). 5 threads ≈ 400–600 frases com **1 busca + 5 leituras** | **SIM** |
| X | `search(f=live)` → 20 posts com `created_at` nativo, mas gasta a **conta pessoal do dono** (`SEARCH_BUDGET` 30/h) | Fase 3 |
| YouTube | `Youtube.call` devolve **transcrição** (`kind: "transcript"`) = fala do criador, não da audiência. Não há scraper de comentários | Fase 6, e só com scraper novo |
| HN/GitHub/Polymarket | `search` devolve **contagem** de comentários, não o texto | fora de escopo |

**Buraco que precisa de tarefa própria:** `Fetcher::Channels::Reddit::EXTRACT_JS` coleta `author/score/depth/body` e **nenhuma data por comentário**. Sem data não há curva. Tarefa 3 adiciona `created` (do `<time datetime>` da tagline do old.reddit) e um acessor estruturado `Reddit.thread_comments(url:)` — `call` devolve markdown renderizado e perde a estrutura. **O seletor é NÃO-VERIFICADO ao vivo** (mesma ressalva que o `SEARCH_JS` já carrega); vira prova ao vivo na Fase 1.

Tetos: `max_phrases` 600, `MAX_THREADS = 5`, descarta `body` < 3 palavras ou > 500 chars (conta em `rejected_count`). `old.reddit.com` é 2 req/min e **`Reddit.call` não cobra o `HostRateLimiter` sozinho** (quem cobra é o `ExtractService`) → o Collector cobra explicitamente e espaça as leituras.

### (b) Triagem VADER — recomendo NÃO usar na Fase 1

Discordo do `sent_b` neste caso, por dois motivos concretos: **idioma** (VADER é léxico inglês; o alvo é pt-BR — seria ruído com cara de medição) e **volume** (a economia que ele compra é cota de LLM: 600 frases = 6 requisições num teto de 200/dia; não há o que economizar). Entra na Fase 6 **como segunda opinião, não como portão**: frase onde VADER/LeIA e LLM discordam vira candidata prioritária da amostra humana.

### (c) Classificação LLM

- Primário `google/gemma-4-26b-a4b-it:free`; secundário `nvidia/nemotron-3-nano-30b-a3b:free`.
- **Snapshot fixo, não roteador.** O elo OpenRouter de hoje é `openrouter/free`, que **sorteia** entre gratuitos (`ModelChain#openrouter_link`) — cada lote poderia cair num modelo diferente e a curva viraria artefato de roteamento. Tarefa 5 registra os dois ids em `Llm::ModelRegistry.custom_models`; se o Classifier precisar cair no roteador, grava `snapshot_pinned: false` e o relatório **diz isso em voz alta**.
- Lote de 100 frases com `id` = índice; saída array JSON `{id, sentiment}`.
- `temperature: 0` + `response_format: {type: "json_object"}` via `with_params` (mesmo mecanismo do `chat_template_kwargs` da Poolside — a gem faz deep_merge).
- **Enum validado no Ruby** (free tier não garante strict schema) + **1 retry** do lote. Persistindo: frases ficam **sem label** e entram em `unparsed_count`. Nunca virar `neutral` — seria inventar dado (é a regra 3 da casa aplicada a rótulo).
- Few-shot de 3 exemplos (1 por classe); não nomear benchmark nem chamar o modelo de "anotador".
- **Conflito de regra resolvido (vai para MEMORY.md):** a regra 8 manda injetar `Time.current` em todo prompt; num classificador isso quebra o "prompt idêntico" e envenena o TARa. Resolução: injetar `run.started_at` em `America/Sao_Paulo`, **congelado por run** — cumpre a regra sem quebrar reprodutibilidade.

### (d) 2ª passada
Só `pass 1 = negative` (≈20–35%, 1–2 requisições). Prompt separado, mesmo lote/enum. Duas passadas em vez de um JSON de 4 campos porque é auditável: dá para reprovar a passada 2 sem invalidar a curva.

### (e) Agregação

```
saldo(T) = (n_pos - n_neg) / (n_pos + n_neg + n_neu)   # -1..+1, normalizado por volume
ΔS(T)    = saldo(T) - saldo(T-1)                       # só entre buckets VÁLIDOS
anomalia = ΔS < μ(ΔS) - 1.5·σ(ΔS)                      # α=1.5 é escolha nossa, declarada
```
Bucket com `n < 30` → `status: "insufficient"`, fora da curva e do ΔS, **listado** no relatório. Volume vai sempre ao lado do saldo (armadilha #2: volume ≠ sentimento). Frase sem `posted_at` entra no saldo do período, não na curva, e é contada no rodapé.

### (f) Relatório

```
**Sentimento — <alvo>** (12/07 a 10/08, bucket diário)
fonte: reddit · 5 threads · 412 frases (38 descartadas) · google/gemma-4-26b-a4b-it:free · temp 0

saldo do período: -0.18   (pos 96 · neu 180 · neg 136)
curva (saldo por dia):
  12/07 ▅ -0.02  n=41
  14/07 ▂ -0.39  n=55
maior variação: 14/07 → 15/07, ΔS = -0.34  ← evento
sem sinal (n<30): 16/07, 17/07, 21/07
negativas por tipo: reclamação 78 · emoção 41 · sarcasmo 17        [fase 4]
exemplos (1 por classe, texto cru + permalink)

confiança: 3-way sentiment tem teto medido de ~75% em frases curtas (benchmark en);
isto é estimativa, não oráculo. estabilidade nesta rodada: TARa 97% (3x o mesmo lote).
4 frases sem classificação (JSON inválido após retry). 12 sem data (fora da curva).
```

## 3. VALIDAÇÃO

1. **Estabilidade (TARa).** `Research::Sentiment::Stability` reclassifica **um lote de 100 frases 3×** (attempt 1..3, prompt byte-idêntico, temp 0) e calcula a fração de frases com os 3 rótulos iguais. `< 95%` → o relatório abre com aviso de instabilidade e o dono decide se confia. Custo: 3 requisições. Roda a cada run (Fase 2).
2. **Amostra humana.** `SentimentReviewTool` entrega 10 frases por vez (amostra aleatória estratificada de 50–100, semente gravada no run), o dono responde `1p 2n 3o ...`; grava em `sentiment_labels` com `pass: 1, attempt: 0` (humano). `Research::Sentiment::Agreement` calcula **kappa de Cohen humano × modelo** + acurácia por classe.
   **Ressalva honesta:** o SOTA pede Krippendorff α > 0.6 com **2+ anotadores**. Com um anotador só, α não é calculável; o que dá é kappa humano-vs-modelo, que mede concordância, não confiabilidade da anotação. Reporto como kappa e **não** chamo de α. Se o dono topar um 2º anotador, α nominal entra na Fase 5.
3. **Como a confiança é reportada.** Toda mensagem carrega: teto ~75% (benchmark **en** — em pt-BR é otimista, e o texto diz isso), TARa da rodada, nº de não-classificadas, nº sem data, e buckets ignorados por volume. Sem esses cinco números o relatório não sai.

## 4. CUSTO

**R$0.** Por run de 600 frases: 6 requisições (pass 1) + ~2 (pass 2) + 3 (TARa) ≈ **11–12 de 200/dia** no free tier do OpenRouter (20 req/min é folgado com lote de 100). Contabilidade reaproveita o padrão de `Llm::BaseClient` (cota diária em `Rails.cache`).

**Escada de fallback se o catálogo free mudar** (ele muda toda semana — Llama, Qwen e hy3 saíram em jul/ago):
1. modelo secundário free → 2. `openrouter/free` (roteador) **com `snapshot_pinned: false` e aviso no relatório** → 3. rota Nous (`tencent/hy3:free`, que é outra via e continua de pé) → 4. **para e alerta o dono** (`AdminAlertChannel`), em vez de gastar.
Pago (`~US$0,01/10k frases`) só existe atrás de `SENTIMENT_ALLOW_PAID=true`, default off. Rake `sentiment:models:check` usa o `ModelRegistry.live_rows` que já existe para conferir os ids antes de cada run.

## 5. FASES, RISCOS, DECISÕES DO DONO

### 5.1 Fases
| # | Entrega | Tarefas |
|---|---|---|
| **1** | Menor caminho útil: alvo único + Reddit + 3-way + relatório, disparado à mão | migration+models; `Reddit.thread_comments` com timestamp; Collector; registro dos modelos; Classifier; Aggregator; MessageBuilder; `SentimentAnalysisJob`; tools de alvo/disparo |
| **2** | Autonomia + honestidade | `SentimentDigestJob` + `recurring.yml`; TARa a cada run; rodapé de confiança completo |
| **3** | X como 2ª fonte | `Sources::X` (timestamp nativo), fusão de fontes, saldo por fonte |
| **4** | 2ª passada | `sentiment_subtype.yml` + linha "negativas por tipo" |
| **5** | Validação humana | `SentimentReviewTool` + `Agreement` (kappa) |
| **6** | Opcionais | VADER/LeIA no sidecar como segunda opinião; scraper de comentários do YouTube |

### 5.2 Riscos
- **Seletor de timestamp do Reddit não verificado** → prova ao vivo obrigatória antes de fechar a Fase 1; sem data por comentário, o fallback é bucket pela data da THREAD (curva mais grossa, e o relatório precisa dizer).
- **Busca do Reddit devolve resultado fora de contexto** (o próprio `chatbot.yml` avisa) → filtro por `Research::Relevance`/`Scorer` antes de ler a thread, com `rejected_count` visível.
- **2 req/min no old.reddit** → run de 5 threads leva ~3 min de relógio; é job de fundo, tudo bem, mas não dá para "rodar 10 alvos agora".
- **Instabilidade ~10% mesmo com temp 0** → é o motivo do TARa; não some, só fica medida.
- **Autosseleção da amostra** (quem reclama posta mais) → volume reportado como covariável, e o relatório nunca lê "queda de saldo" como "queda de aprovação".
- **Teto ~75% é de benchmark em inglês** → em pt-BR é otimista; o texto do relatório assume isso.
- **Catálogo free some** → escada do §4.

### 5.3 Decisões que são DO DONO
1. Onde mora a config do alvo: **DB+tool no chat** (recomendo) ou YAML.
2. Fonte da Fase 1: **Reddit** (recomendo) ou X.
3. Cortar o VADER da Fase 1 (recomendo) ou exigi-lo.
4. Cadência: sob demanda na Fase 1; **semanal** a partir da Fase 2 — qual dia/hora.
5. Validação humana: 1 anotador (kappa) ou 2 (α de Krippendorff de verdade).
6. Fallback pago (US$0,01/10k): manter proibido (recomendo) ou liberar.
7. Tamanho do relatório: quantos exemplos de frase e se a curva vai diária ou semanal por padrão.

## 6. TESTES

**O que a suíte tem de provar (TDD, teste antes da implementação):**
- `frozen_spec` é gravado **antes** do primeiro fetch e o Aggregator lê dele — teste que muda o `target` no meio e prova que o resultado não muda.
- Coleta é idempotente: rodar 2× o mesmo run não duplica frase (uniq `(run_id, external_id)`).
- Comentário sem data vira `posted_at: nil` e **não** entra em bucket; entra no saldo do período.
- Classificador: lote de 100 vira 1 requisição; JSON com rótulo fora do enum → 1 retry → frases sem label e `unparsed_count` incrementado; **nunca** `neutral` por default.
- Prompt idêntico entre lotes e entre as 3 tentativas (asserção sobre a string, com `started_at` congelado).
- Aggregator: bucket com n=29 é `insufficient` e não entra no ΔS; saldo é (pos−neg)/total; ΔS só entre buckets válidos.
- MessageBuilder: os 5 números de honestidade sempre presentes; sem anexo; chunk ≤ limite.
- Tools: escrita só para `DISCORD_OWNER_IDS` (fail-closed), clamp silencioso nos limites.

**Como testar sem gastar cota:** `RubyLLM.stubs(:chat).returns(fake_chat)` com um dublê de classe plain (`FakeChat`, com `with_instructions/with_temperature/with_params` devolvendo `self` e `ask` devolvendo objeto com `content`) — **sem `OpenStruct`** (Ruby 4.0). Fixtures de frases em `test/fixtures/sentiment/` com um lote de 100 e respostas canônicas (válida, com rótulo inválido, com JSON truncado). Coleta testada por `from_page`/`from_search_page` com página dublê, do jeito que os testes de canal já fazem — sem Chrome.

**Fica para prova ao vivo (com o dono):** seletor `<time datetime>` do old.reddit; existência real dos dois ids `:free` no catálogo; primeiro alvo real fim-a-fim.

---

## VEREDITO

**Precisa de 2 verificações antes de virar código — as duas de 10 minutos, nenhuma bloqueia o desenho.**

1. **Confirmar os ids `:free` ao vivo** (`Llm::ModelRegistry.free` já faz isso no container). Os dois nomes vêm do relatório, que se declara NÃO-CONFIRMADO, e o catálogo mudou duas vezes em agosto. Sem isso, fixar snapshot é fixar um id que pode não existir.
2. **Confirmar o timestamp por comentário no old.reddit.** É o único ponto onde o desenho depende de algo que não está no repo hoje; se o seletor não existir, a curva cai para granularidade de thread e o relatório muda de forma.

Fora isso o plano está pronto para implementar: a Fase 1 não inventa infraestrutura nenhuma — reusa canal Reddit, RubyLLM/OpenRouter, Solid Queue, `DigestChannel`, `DiscordMessageChunker` e o padrão de tool owner-only que já estão de pé.

Quer que eu persista isso em `docs/superpowers/plans/2026-08-10-sentiment-pipeline.md`? Precisa liberar escrita nesse caminho — ou eu escrevo em outro lugar que você já permita.
opus plano exit=0
