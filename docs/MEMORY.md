# MEMORY.md — Cleitin Bot Write-Back Memory

> **Fonte de verdade viva do projeto.** Este arquivo é lido obrigatoriamente pela IA no
> início de toda tarefa sistêmica e atualizado autonomamente via Write-Back Protocol
> definido em `AGENTS.md`.

---

## Contexto Ativo do Projeto

> O que estamos construindo / investigando nas últimas 48h.

- **Override de fingerprint condicionado por host no fetcher**: o `Fetcher::BrowserSession#apply_reddit_user_agent!` (lib/fetcher/browser_session.rb) injeta `Network.setUserAgentOverride` com UA determinístico de Chrome/Windows SÓ para hosts que casam `REDDIT_HOSTS` (reddit.com e subdomínios) — nunca no UA global, para não mudar o comportamento medido do YouTube/X. Garante o timeout de navegação reduzido (15s) só no Reddit via `goto_limit`.

- **[2026-08-29]** Frente C — Deduplicação de alertas de scraping por transição de incidente (`AlertThrottler`, `ScrapingFailureAlertJob`, `ScrapeYoutubeJob`).
  - Alerta por TRANSIÇÃO: notifica no 1º incidente, em alteração de causa (`error_type` ou `normalize_fingerprint(error_message)`), ou após recuperação com nova falha. Repetições diárias da mesma falha no mesmo perfil são descartadas.
  - Estado persistido em Solid Cache (`scraping_incident:#{scraper_name}:#{profile_id}`, TTL 30d) sem migrations no banco. Lock atômico com TTL 5min e double-checked locking para concorrência.
  - Rollback honesto de cota horária e liberação de lock em falha de envio ao Discord, canal admin não configurado ou quota horária esgotada.
  - Resolução de incidente (`AlertThrottler.resolve_incident`) no `ScrapeYoutubeJob` ao obter `collection_status: "success"`.
- **[2026-09-25]** Leitura do X unificada — bot e agente Hermes usam o MESMO código.
  - `Fetcher::XLeitura` + `bin/rails x:buscar CONSULTAS=arquivo|-` (uma linha JSON por consulta) e
    `bin/rails x:conversa ID=<id|link>` (post raiz + comentários em texto, via `XConversation`).
    O Hermes chama esses comandos; os scripts paralelos dele (busca/captura) deixam de existir.
  - Parser da busca: o X passou a mandar o autor em `user_results.result.core.screen_name`; exigir o
    `legacy.screen_name` descartava todos os posts e a busca de produção devolvia `[]` sem erro (medido 24/09).
  - `XQueryIdResolver`: descoberta pede `x.com/home` com a sessão do jar (sem sessão, ~1 em 2 respostas é
    307 para o login); o PIN (id da SearchTimeline) nunca é entregue a outra operação — TweetDetail com ele
    dava HTTP 422; operação ausente nos bundles não grava valor inventado no cache.
- **[2026-08-31]** Feature — Busca X via GraphQL (`Fetcher::Channels::XGraphql`).
  - `SearchTimeline` guest não funciona (exige sessão do dono via CookieJar auth_token+ct0 + header x-client-transaction-id assinado; sem ele o X devolve 404 vazio anti-bot).
  - Busca por assunto (`X.search`) agora usa HTTP GraphQL direto com paginação por cursor (máx 3 páginas, dedupe por permalink).
  - Limite local via HostRateLimiter (scope `graphql_search` 4/min 30/h) e parse de rate limit remoto (headers `x-rate-limit-*`).
  - 429/403/401 tratados como erros nomeados sem dormir na tool.
  - Query ID do SearchTimeline rotaciona a cada deploy do X; resolvido via cache (SolidCache) + refresh recorrente a cada 6h (`RefreshXQueryIdsJob`) + PIN inicial `flaR-PUMshxFWZWPNpq4zA` (verificado 31/08).
  - ID do XActions (`hyPfJYJ_...`) está stale (404).
  - Timeline por perfil (`X.timeline`) permanece no Chrome/CDP com CookieJar — inalterada.
  - Rollback temporário: `X_SEARCH_TRANSPORT=browser` usa o caminho legado (browser); sem env (ou `=graphql`) usa GraphQL. Sem fallback automático.
  - Prazo de revisão da flag: 14 dias ou 2 rotações de bundle (o que for maior) — depois decidir remover ou manter com dono operacional.
- **[2026-08-10]** Feature — Pipeline de Análise de Sentimento (Fase 1 completa):
  - Migration `20260811000001_create_sentiment_pipeline.rb` com 4 tabelas (`sentiment_targets`, `sentiment_runs`, `sentiment_phrases`, `sentiment_labels`), `frozen_spec` JSON gravado antes do fetch e índice único em `(run_id, external_id)`.
  - Coleta multi-fonte Reddit E X (`lib/research/sentiment/sources/`): `Reddit.thread_comments(url:)` com timestamps `<time datetime>` do old.reddit; `X.search`/`timeline` com timestamps nativos; taxa de rate limit explícita em old.reddit (2/min).
  - Classificação 3-way (`Classifier`) em lotes de 100, `temperature: 0`, `response_format: { type: "json_object" }`, prompt em `config/prompts/system/sentiment_classify.yml` com timestamp congelado (`run.started_at` SP), snapshot fixo nos modelos free (`google/gemma-4-26b-a4b-it:free` e `nvidia/nemotron-3-nano-30b-a3b:free`) registrados em `ModelRegistry.custom_models`, 1 retry por lote, sem default neutral (unparsed).
  - Agregação por bucket (`Aggregator`): buckets com n < 30 marcados como `insufficient` (fora da curva e do ΔS); frases com `posted_at: nil` entram no saldo total mas fora da curva.
  - Relatório no Discord (`MessageBuilder`): sem anexo, chunk <= 1900 chars via `DiscordMessageChunker`, 5 números de honestidade (teto ~75%, TARa, unparsed, sem-data, buckets ignorados), 1 exemplo por classe com permalink, saldo por fonte e agregado.
  - Orchestração sob demanda via `SentimentAnalysisJob` e 3 tools owner-only (`CreateSentimentTargetTool`, `RunSentimentAnalysisTool`, `SentimentStatusTool`).
- **[2026-08-10]** Tarefa F6-A — busca por assunto nos canais Hackernews, Github e Polymarket (`lib/fetcher/channels/`) + ajustes no `Research::Signals` e `Research::Scorer`.
  - `Fetcher::Channels::X.search(query:, limit: 10)`: busca nativa no X com `f=live&src=typed_query`. Detecção do estado vazio legítimo via marcador `[data-testid="empty_state_header_text"]` (retorna `[]`); sem marcador, levanta `SearchFailed`. `SEARCH_BUDGET` e `TIMELINE_BUDGET` reduzidos para 30/h (4/min) mantendo teto da conta do dono em ~60/h. Mensagem de `RateLimited` inclui o escopo (`[timeline]` / `[search]`).
  - `PlatformSearchTool`: exige `@` explícito para perfis (ex: `@jack` -> `X.timeline`); termos sem `@` (frases ou palavras soltas ex: `bitcoin` ou `ruby rails`) acionam `X.search`.
  - Prompts do chatbot (`chatbot.yml`) e MCP tool (`platform_search.rb`) atualizados para refletir a busca por assunto no X.
  - `Hackernews.search(query:, limit: 10)`: busca em Algolia API com filtro `created_at_i>30d_epoch`, devendo `comments` (num_comments), `points`, `author`, `created_at` ISO e `external_url` separado.
  - `Github.search(query:, limit: 10)`: busca REST API `/search/issues` com `created:>=30d`, `sort=reactions`, achatamento de `reactions` (total_count Numeric) e fallback gracioso `[]` para 403/429/5xx.
  - `Polymarket.search(query:, limit: 10)`: busca em Gamma API `/events?search=<query>` devolvendo `volume`, `liquidity`, `created_at` e fallback `[]` em 4xx/mudança de schema.
  - `Research::Signals`: pesos de `github` (reactions 0.55 / comments 0.45), `VOTE_LOG_REFERENCE` para `github` (5.5) e `polymarket` (13.5) especulativos, e alias `comments` -> `num_comments`.
  - `Research::Scorer.sort`: desempate determinístico por `url` e `title` para scores brutos empatados.
  - 47 testes passando no Docker (`hackernews_test.rb`, `github_test.rb`, `polymarket_test.rb`, `signals_test.rb`, `scorer_test.rb`).
- **[2026-08-10]** Tarefa F3 — Análise automática de desempenho de vídeos implementada (`Analytics::PostScorer`, `ScorePostsJob`, `WeeklyDigestJob` reescrito, `post_snapshots` na coleta do YouTube com fuso SP e poda de 180d, shorts detectados em `YoutubeScraperService` como `post_type: "short"`).
  - `PostScorer`: z-score robusto log1p + MAD com fallback para IQR/1.349 e tabela de correção para n pequeno; baseline 7..45d e n>=10. Vídeos <7d marcados como `maturing` sem `views_at_scoring`. Re-score idempotente se views inalteradas.
  - `WeeklyDigestJob`: digest semanal reescrito com delta de seguidores por perfil, top 3 / bottom 3 desempenhos apurados por `scored_at >= 7.days.ago`, alertas >48h e chunking em mensagens <= 1900 chars via `DiscordApiClient.send_message`.
  - Agendamentos atualizados em `config/recurring.yml`: `score_posts_job` e `weekly_digest_job` às 12pm (UTC).


- **[2026-08-10]** Tarefa F4 — Tools de escrita de monitoramento de perfis (`app/tools/profile_management_tools.rb`) implementadas com autorização fail-closed por allowlist (`DISCORD_OWNER_IDS`).
  - Novas classes de tool: `AddProfileTool`, `SetProfileMonitoringTool`, `RemoveProfileTool`, `PromoteProspectTool`, herdando da base comum `ManagementToolBase < ToolBase`.
  - `ManagementToolBase` prove validação `owner?` contra `Thread.current[:cleitin_actor][:user_id]` e `ENV["DISCORD_OWNER_IDS"]`, sanitização/normalização de handles (`normalize_handle`) extraindo de URLs por host e aplicando `HANDLE_RULES` por plataforma, desambiguação (`find_profile`) e `format_profile` enriquecido com status.
  - `RemoveProfileTool` opera em duas etapas usando `Rails.cache` com TTL 2min e `confirm_token` (SecureRandom hex 16), realizando soft-delete (`archived_at`, `monitoring_status: paused`) e preservando posts.
  - 19 novos testes em `test/tools/profile_management_tools_test.rb` (0 failures, 0 errors).
- **[2026-08-10]** Fase 3 — fusão RRF + clustering implementada (`lib/research/fusion.rb`, `lib/research/cluster.rb`) e revisada.
  - Porta Ruby do pipeline de fusão (Weighted Reciprocal Rank Fusion) e do
    cluster greedy + MMR da referência Python. Tokens mantidos em pt-BR:
    `RRF_K = 60`, `MAX_ITEMS_PER_AUTHOR = 3`, `DIVERSITY_RELEVANCE_THRESHOLD = 0.25`,
    thresholds do greedy 0.42 (breaking_news) / 0.48 (demais), MMR lambda 0.75
    com limite 3, `THIN_EVIDENCE_FLOOR = 0.55`.
  - **Escala do score (decisão de design)**: o `rrf_score` do Fusion vale no
    máximo ~0,0164 por stream e NUNCA 0-100 como o `final_score` da referência.
    Por isso o Cluster usa `local_relevance` (0-1, emitido pelo Scorer via
    `relevance_score`) como score de TRABALHO — líder, ordenação do grupo,
    MMR e thin-evidence — e mantém `rrf_score` apenas para ordenação do pool
    (feita no Fusion) e como desempate. Ver `cluster.rb#score_of` e
    `fusion.rb#extract_local_relevance`.
  - **Fase 4 (adiado)**: o segundo pass do cluster (`_merge_entity_clusters`
    da referência, que funde clusters pequenos com entidades compartilhadas)
    depende de `entity_extract`, ainda não portado. Marcado em
    `cluster.rb#build_clusters` como TODO e decidido com o delegado para a
    Fase 4 — mantém o ponto onde o plug-in entra sem inflar o escopo da Fase 3.
  - **Diversidade por fonte**: o bucket de `diversify_pool` usa o campo
    escalar `source` do candidato (atualizado quando o item vence o
    `primary_score` no merge), espelhando a referência que usa `c.source`
    ATUALIZADO — e não o primeiro item de `sources` (congelado no build).
  - **idempotência do sort**: `sort_by` do Ruby não é estável; empate de
    `rrf_score` é o caso comum (todo rank-1 de 1 stream dá 1/61). Adicionada
    chave de desempate por `key` em fusion.rb (sort_key) e cluster.rb
    (group + final cluster sort).
  - **Correções S (suspeitas confirmadas)**: `normalize_url` agora
    percent-encode a entrada antes do parse (URLs com acento/CJK não
    caem no rescue silencioso), descarta params com valor vazio no
    decode_www_form (paridade com `parse_qs` Python) e alargou o rescue
    para `URI::Error, ArgumentError`. `split_stream_key` sem `":"` agora
    devolve `["", stream_key]` (a chave é a fonte) em vez de gravar
    source "" no provenance.
  - 37 testes (19 fusion + 17 cluster + 1 integração) passando no harness
    isolado do worker; veredito oficial fica com o orquestrador no docker.
- **[2026-08-09]** Correção de documentação (PR3, revisão): a afirmação da
  entrada de 2026-03-23 de que as sessões vivem "em memória com TTL 30min via
  `ChatSessionManager`" ficou FALSA quando as conversas passaram a viver no
  SQLite: o TTL de 30min só despeja o objeto quente do cache; a conversa
  persiste no banco e a fronteira entre conversas é o comando `/new`.
- **[2026-03-30]** Deploy hardening (Propostas 1-3: `chore/deploy-hardening`).
  - `set -Eeuo pipefail` em deploy.sh e recover-failure.sh (ERR trap propaga para rollback)
  - Healthcheck nativo docker-compose: `curl /up` (app) + `curl /json/version` (chrome)
  - `depends_on` app→chrome mudou de `service_started` para `service_healthy` (determinístico)
  - Image tagging: `cleitin-bot:${IMAGE_TAG:-latest}` em app/jobs/discord-bot; `IMAGE_TAG` = 12 chars do commit hash
  - Deploy usa `--wait --wait-timeout 90` em vez de loop manual de health check (12 linhas → 1 flag)
  - Rollback restaura imagem tagged anterior (sem rebuild) — `IMAGE_TAG="${LOCAL:0:12}" compose up`
  - Builder cache prune (`docker builder prune -f --filter "until=24h"`) no deploy
  - FASE 10.5 em oracle-cloud-setup.sh: systemd timer semanal de cleanup de imagens (`prune -a --filter until=168h`)
  - Self-hosted runner (Proposta 4) adiado para PR separado após ≥1 semana em produção
- **[2026-03-28]** Correções críticas de infra (PR #9: `fix/deploy-infrastructure`).
  - Deploy rollback simplificado: `git reset --hard` + `docker compose build` (remove snapshot_images() quebrado)
  - Migration falha agora chama rollback e para deploy (era WARNING que continuava)
  - Docker GPG key fingerprint verification no setup (proteção MITM)
  - Detecção dinâmica de SUDO_USER em vez de hardcoded "ubuntu"
  - `.env.example` com variáveis de ambiente documentadas
  - Auditoria de segurança: 16 findings em docs/audit_deploy_setup.md
  - 407 testes passando (0 failures, 0 errors)
- **[2026-03-29]** Correções de segurança pós-audit deploy.sh + oracle-cloud-setup.sh.
  - deploy.sh: SSH accept-new, git diff ORIG_HEAD, rollback sem || true com anti-loop, health check HTTP /up, migrate log em log/
  - oracle-cloud-setup.sh: fallocate dd fallback, disk check pré-alocação, Docker MTU 1400, chrony OCI NTP, DOCKER_DEFAULT_PLATFORM, userns-remap opt-in
- **[2026-03-28]** Infraestrutura Oracle Cloud + Deploy CI/CD.
  - Deploy automatizado via GitHub Actions (`.github/workflows/deploy.yml` + `.github/scripts/deploy.sh`)
  - SSH deploy com detecção de mudanças Docker/Gemfile para rebuild inteligente
  - Setup script Oracle Cloud VM (`scripts/oracle-cloud-setup.sh`) — 10 fases (OS, SSH, iptables, Fail2Ban, swap, NTP/Chrony, Docker, kernel, deploy dir)
  - Documentação: Oracle Cloud Free Tier (24GB RAM, 4 OCPUs Ampere A1) + Guia de setup VM
  - Decisão: Oracle Cloud Always Free como hospedagem (sobra 85% de RAM para workload)
- **[2026-03-26]** Fase 6 implementada: Lapidação e Operação Segura.
  - Health check enriquecido (`/health`) com DB check
  - Alertas automáticos de falha de scraping via Discord (`ScrapingFailureAlertJob`)
  - Geração de imagens via Gemini Imagen 3 (`ImageGenerationService`, opt-in `ENABLE_IMAGE_GENERATION`)
  - Backup automático do SQLite com proteção WAL (`SqliteBackupJob` + `bin/backup`)
  - Throttle de alertas via Solid Cache (`AlertThrottler`, max 10/hora por tipo)
  - `AdminAlertChannel` concern reutilizável (padrão `DigestChannel`)
  - `sqlite3` CLI adicionado ao Dockerfile runtime stage
  - `ruby_llm` atualizado para `~> 1.14` (suporte Imagen)
  - 394 testes passando (0 failures, 0 errors)
- **[2026-03-23]** Fase 5 implementada: UI Autônoma e Chatbot Tool Caller.
  - 16 tools em `app/tools/` (herdam de `RubyLLM::Tool` via `ToolBase`)
  - Discord Bot como serviço dedicado no compose (`discord-bot`)
  - Sessões com TTL 30min via `ChatSessionManager` (corrigido em 2026-08-09: o
    TTL só despeja o objeto quente; a conversa vive no SQLite e a fronteira
    entre conversas é o `/new`, não o TTL)
  - Digest semanal e de sexta via `WeeklyDigestJob` e `FridayIdeationJob`
  - Canal de digest criado automaticamente se não existir
  - 371 testes passando (0 failures, 0 errors)
- **[2026-03-22]** Setup inicial do repositório: Headless Rails 8.1 + SQLite WAL +
  Solid Queue/Cache. Estrutura de pastas, AGENTS.md com routing table, e docs de
  estratégia (comparativo IA, scraping gratuito, Docker Chrome) já criados.

---

## Padrões Sistêmicos Ratificados

> Decisões de tecnologia **finais e imutáveis** (salvo re-ratificação explícita do usuário).

| Data | Padrão | Contexto |
|------|--------|----------|
| 2026-08-29 | Deduplicação de alertas de scraping por transição em Solid Cache | Em vez de alertar a cada execução/hora (spam diário às 9h UTC em fallbacks estruturais), o alerta só dispara na transição de estado (`reserve_incident`). Cota horária de 10/h por tipo preservada como salvaguarda anti-tempestade. |
| 2026-08-09 | Split Gemini background/interactive + cadeia nous → poolside → openrouter | Substitui o cliente único Gemma 4 31B (`gemma_client.rb`, removido) por dois clientes Gemini por tier — `gemini_background_client.rb` (gemini-3.1-flash-lite, background) e `gemini_interactive_client.rb` (gemini-3.5-flash-lite, interactive) — e pela `ModelChain` (nous → poolside → openrouter). A `ModelChain` ainda não é consumida pelo chat: o `ChatSessionManager` passará a usá-la após o merge do PR de sessões (dependência de ordem). |
| 2026-03-30 | Swap via zRAM (ALGO=zstd, 50%) em vez de disco físico | Poupa limite agressivo de IOPS (3000) do boot volume da OCI. Melhoria pragmática nativa via `zram-tools`. |
| 2026-03-26 | ruby_llm ~> 1.14 (não 1.12) | Suporte a Imagen via `RubyLLM.paint` — API mudou em 1.14 |
| 2026-03-26 | OpenStruct removido da stdlib em Ruby 4.0 | Usar classes plain ou Mocha mocks em testes em vez de `require 'ostruct'` |
| 2026-03-26 | `$CHILD_STATUS&.exitstatus` com safe navigation | `$CHILD_STATUS` é nil quando `system` é stubbed em testes |
| 2026-03-26 | Mock objects para `ActiveRecord::Base.connection` em integration tests | Stubs no connection object persistem entre tests devido ao connection pool |
| 2026-03-23 | discordrb ~> 3.7 (3.7.2) — não existe ~> 3.8 | Versão mais recente compatível com Ruby 4.0 |
| 2026-03-23 | Tools em arquivos únicos (múltiplas classes por arquivo) + requires explícitos em testes | Rails autoload não resolve classes de arquivos com nome diferente da classe |
| 2026-03-23 | Partials de prompt devem ter prefixo `_` | PromptLoader procura `_nome.yml` em `partials/` |
| 2026-03-23 | Discord Bot como serviço dedicado no compose | Isolamento total do Puma/Solid Queue, restart independente |
| 2026-03-14 | Solid Queue em vez de Sidekiq/Redis | Reduz dependências; SQLite single-file |
| 2026-03-14 | Solid Cache em vez de Redis Cache | Mesma razão acima |
| 2026-03-14 | SQLite WAL mode, 3 databases (primary, queue, cache) | Performance + simplicidade operacional |
| 2026-03-14 | Headless Rails (sem ActionView/Sprockets) | API-only, sem frontend server-rendered |
| 2026-03-14 | Jobs idempotentes com dedup window de 2h | Safe to re-run sem duplicatas |
| 2026-03-13 | Gemini Flash como modelo primário de análise | Custo-benefício vs. capacidade — pesquisa em `docs/comparativo_IA_gemini_gemma.md` |
| 2026-08-09 | Execução Python via sidecar HTTP autenticado (8080) | Scraping evasivo (nodriver/camoufox/curl_cffi) migrado de `Open3` in-process para `POST /run` no container `python-scraper`, com auth Bearer `PYTHON_SCRAPER_TOKEN`. |
| 2026-08-10 | RRF K=60 + Cluster usa `local_relevance` (0-1) como score de TRABALHO | `rrf_score` do Fusion é ~0.016-0.05; usar como score do Cluster degenera (thin-evidence sempre, MMR pune 10× mais que score). `local_relevance` vem do `relevance_score` do Scorer (0-1). Ver `lib/research/cluster.rb#score_of` e `fusion.rb#extract_local_relevance`. |

---

## Lições Aprendidas de Bugs Recorrentes

> Memória episódica: anti-padrões e erros clássicos que **nunca** devem ser repetidos.
> Cada entrada deve ter data, descrição do problema, causa raiz, e resolução.

| Data | Bug / Anti-padrão | Causa Raiz | Resolução |
|------|-------------------|------------|-----------|
| 2026-03-23 | `NameError: uninitialized constant` em tests de tools | Rails autoload não resolve classes de arquivos com múltiplas classes (ex: `social_profile_tools.rb` contém 4 classes) | Adicionar `require_relative` explícito em cada arquivo de teste |
| 2026-03-23 | Partial `discord_format.yml` não carregada pelo PromptLoader | PromptLoader espera prefixo `_` no nome do arquivo (`_discord_format.yml`) | Renomear arquivo para `_discord_format.yml` |
| 2026-03-26 | `OpenStruct` não disponível em Ruby 4.0 (`LoadError: cannot load such file -- ostruct`) | `ostruct` removido da default gems no Ruby 4.0 | Usar classes plain com `attr_reader` ou Mocha mocks em testes |
| 2026-03-26 | `TimeWithZone#to_s(:db)` raises `ArgumentError: wrong number of arguments` em Ruby 4.0 | `to_s` não aceita argumentos de formato em Ruby 4.0 | Usar `strftime("%Y-%m-%d %H:%M:%S")` |
| 2026-03-26 | Stubs Mocha em `ActiveRecord::Base.connection` vazam entre integration tests | Connection pool reutiliza o mesmo objeto connection entre tests | Usar mock objects (`mock('connection')`) em vez de stubs diretos + `Mocha::Mockery.instance.teardown` no teardown |
| 2026-03-26 | `require_relative` errado em test de concern (`test/jobs/concerns/`) | Arquivo em subdiretório requer `../../../` em vez de `../../` para sair do concern | Verificar path relativo considerando profundidade do diretório |
| 2026-03-28 | Deploy rollback com snapshot_images() era ineficaz | Snapshot tirado DEPOIS do `git pull` capturava imagens do novo código quebrado, não do código anterior funcional. Rollback marcava imagens atuais com `-rollback` em vez de restaurar as anteriores | Simplificar: `git reset --hard` + `docker compose build` para rebuild do código anterior |
| 2026-03-28 | Migration falha não parava deploy | deploy.sh usava `WARNING` + `cat` sem `exit 1`, continuava deploy com banco incompatível | Adicionar `rollback` + `exit 1` no bloco de falha de migration |
| 2026-08-09 | Limiar inerte no initializer de LLM: falha silenciosa que mascara bug nosso | `require 'ruby_llm'` e os `require` locais de `lib/llm/` dividiam o mesmo `rescue LoadError`; require errado ou registro incompleto subia a app "de pé", logando "Gem não disponível" enganoso, sem provedor nem modelo novo | `require 'ruby_llm'` é o único ponto coberto pelo rescue; `require` locais ficam FORA dele, então erro ali estoura o boot (regra 3/CLAUDE.md). Citações: `config/initializers/ruby_llm.rb` e `test/lib/llm/model_chain_test.rb` |
| 2026-08-10 | Score de TRABALHO do Cluster tem que ser `local_relevance`, NÃO `rrf_score` | Porta Ruby do Fusion emite `rrf_score = 1/(60+rank)` (≈0.016-0.05) por stream, nunca 0-100 como o `final_score` Python. Sem ler `relevance_score` no `extract_local_relevance`, o Cluster via todo candidato com `local_relevance = 0.0`, disparava `thin-evidence` para todos os clusters multi-fonte (regra `max_score < 0.55`) e o MMR tinha `0.75*0.05 - 0.25*0.5` na fórmula — diversidade pesando ~10× mais que score. | Ler `relevance_score` (campo do Scorer) em `fusion.rb#extract_local_relevance` e usar `local_relevance` como score de TRABALHO em `cluster.rb#score_of` (fallback para `rrf_score`, nunca o inverso). Citações: `lib/research/fusion.rb:128-` e `lib/research/cluster.rb#score_of`. |
| 2026-09-25 | Cliente do Chrome falava com o DevTools pelo **nome do container** no handshake WebSocket (`ws://chrome:9222/...`) — funcionava no 147 por sorte de versão e morre no 151 com `Ferrum::DeadBrowserError` | O DevTools só aceita `Host` = IP ou `localhost`. No caminho HTTP (`/json/version`) o 147 e o 151 já rejeitavam nome (500) — por isso existe o `Host: localhost` injetado; no handshake WS o 147 aceitava nome (101) e o 151 passou a rejeitar (500). `--remote-allow-origins=*` não relaxa (trata `Origin`, não `Host`). Medido em réplica isolada: RELATORIO-CHROME-151.md (t_317d900a) e revisão t_a7a8cad2 | O `ws_url` sai com o **IPv4** resolvido do serviço, pedido com `AF_INET` (o `getaddrinfo` sem família pode devolver IPv6 primeiro), e a porta é fixada (o Chrome devolve `ws://localhost/...` sem porta). Sem IPv4 → erro, nunca volta ao nome. Os DOIS clientes: `FerumConfig.discover_stealth_ws_url`/`chrome_ipv4` (`config/initializers/ferrum.rb`) e `ChromeWsConnector.replace_host`/`chrome_ipv4` (`lib/chrome_ws_connector.rb`). Compose inalterado (via "só código"). Testes com DNS falso v6-primeiro: `test/support/fake_chrome_dns.rb` |
| 2026-09-26 | Thread de `Thread.new` sem referência em caminho de cache: o refresh em background de `resolve` vazava para o teste SEGUINTE e inflava o contador de outro teste (flake "esperado 1, veio 2" no CI `36203673307`) | `resolve` (cache stale) fazia `Thread.new { discover! }` sem guardar a referência. A thread sobrevivia ao teste que a criou e fazia o `GET https://x.com/home` dentro do teste seguinte; como o **WebMock indexa por URL, não por teste**, o `stub_request` do teste do lock respondia a ela e o fetch alheio entrava no contador. Medido: `delta=1` thread viva após o teste stale; reproduzido em 1/20 rodadas sob carga, com a mensagem idêntica à do CI | Guardar a thread e poder ESPERÁ-la (`spawn_background_refresh` + `wait_for_background_refresh`, com teto de tempo) e drenar no `teardown` da suíte. Citações: `lib/fetcher/x_query_id_resolver.rb` e `test/lib/fetcher/x_query_id_resolver_test.rb`. **Regra geral: um `Thread.new` fire-and-forget em código de produção precisa ser alcançável por join, senão ele atravessa a fronteira do chamador — em teste isso vira flake, em produção vira trabalho fora de hora.** |
| 2026-09-26 | Lock com `read` seguido de `write` no cache compartilhado NÃO é lock: janela entre as duas operações deixa dois compradores | `discover!` fazia `@cache.read(lock_key)` e depois `@cache.write(lock_key, true)` como **duas operações separadas**. Em produção o store é o `solid_cache_store` (`config/environments/production.rb:14`), onde cada operação é uma transação — existia uma janela em que o lock ainda não estava no cache. O `@mutex` é **por instância**, então nunca serializou outro processo (o job roda em `jobs`, o scraper em `app`): dois fetches de descoberta contra o X ao mesmo tempo | Aquisição atômica: `@cache.write(lock_key, token, unless_exist: true, expires_in: lock_ttl)`, no padrão já usado em `lib/scraping/fetch_pacer.rb:23` e `app/jobs/sentiment_analysis_job.rb:144`. **Não apagar o lock ao terminar**: liberar faz cada thread da fila adquirir em seguida e buscar de novo (medido: 5 threads → 5 fetches); o TTL curto é a janela de exclusão, e o `@fetching` por instância barra o paralelismo dentro da instância. Citações: `lib/fetcher/x_query_id_resolver.rb#discover!`. |
| 2026-09-26 | Retorno cru apaga o desfecho: `force: true` que perde a corrida do lock logava "refresh concluído" sem ter descoberto nada (ressalva R2 do #203) | O conserto da aquisição atômica tornou `unless_exist` capaz de devolver `false` — quem não compra o lock sai com o valor **em cache**, idêntico ao valor de quem descobriu e gravou. `resolve` devolvia só a String, então `RefreshXQueryIdsJob` não tinha como distinguir os dois e logava sucesso nos dois. Um refresh que não descobriu nada sumia do log como sucesso | `resolve_with_outcome` devolve um `Discovery` com `reason` (`:discovered`, `:not_found`, `:lock_busy`, `:fetching_in_progress`, `:fresh_cache`, `:stale_cache`, `:failed`) e `discovered?`. O job mapeia cada `reason` para nível e texto próprios: `info` **só** quando descobriu de verdade, `warn` para todo o resto (inclusive `reason` não mapeado). `resolve` continua existindo e devolve a String — quem não precisa do motivo não paga por ele. Citações: `lib/fetcher/x_query_id_resolver.rb#resolve_with_outcome`, `app/jobs/refresh_x_query_ids_job.rb#report`, `test/jobs/refresh_x_query_ids_job_test.rb`. **Regra geral: quem devolve só valor não pode dizer o que aconteceu; se o desfecho muda o nível do log, o desfecho tem de atravessar a fronteira da chamada.** |
| 2026-09-26 | TTL de lock sem timeout no cliente HTTP é garantia FALSA: o pior caso da descoberta era 3x o TTL (ressalvas R1/R3 do #203) | `discover!` grava o lock com `expires_in: LOCK_TTL` e não o renova nem o apaga — a exclusão é literalmente "a descoberta cabe no TTL". Mas `Faraday.new(url:).get` não tinha timeout: o faraday-net_http deixa o Net::HTTP no padrão de **60s de open e 60s de read por requisição** (medido). Uma descoberta faz `bundles + 1` requisições (3 no fixture real), logo o pior caso era de **180s contra TTL de 60s**. Medido com o store real: TTL de 1s + fetch de 1.4s → o lock expira com o dono vivo e um segundo processo busca. Mesma classe do bug que o #203 fechou, no eixo tempo | `HTTP_OPEN_TIMEOUT`/`HTTP_READ_TIMEOUT` = 3s. Pior caso cai para **9s**: 6,7x de folga no TTL e cabe no join de 10s. `http_client` centraliza o cliente — o detalhe é que em Faraday é `request.options.timeout` que vira `read_timeout` do Net::HTTP (`faraday-net_http-3.4.4/lib/faraday/adapter/net_http.rb:153-163`); setar só `connection.options` dá um cliente que PARECE ter timeout e continua com 60s. Dois testes travam a aritmética (pior caso ≤ join e ≤ TTL). Citações: `lib/fetcher/x_query_id_resolver.rb`, `test/lib/fetcher/x_query_id_lock_ttl_test.rb`, `test/lib/fetcher/x_query_id_resolver_timeout_test.rb`. **Regra geral: TTL de lock só é garantia se o trabalho sob ele tem teto — e o teto tem de ser medido, não afirmado.** |
| 2026-09-26 | Check-then-act inerte: 4 releases de lock com `read(token)` → `delete` só são seguros porque o store de produção é SolidCache | `lib/scraping/fetch_pacer.rb:78`, `app/jobs/sentiment_analysis_job.rb:160`, `app/jobs/concerns/digest_channel.rb:118` e `app/services/alert_throttler.rb:202` fazem o par leitura-antes-de-escrita no caminho genérico. Em produção o SolidCache tem o atômico antes dele (`SolidCache::Entry.lock_and_write`), então a janela não existe — "inerte porque o store é o de hoje" é **dependência implícita**: trocar `config.cache_store` reintroduz a janela sem aviso no boot, no deploy ou no log | Escolha (b): **documentar**, com `Fetcher.release_lock_atomically` (`lib/fetcher/lock_release.rb`) como ponto único que **devolve o desfecho** — `:released` (CAS), `:released_non_atomic` (caminho genérico, com janela), `:not_owner`. O sufixo é o contrato: um `:released` mudo no caminho genérico seria a mesma classe de bug. A dependência fica em texto legível por máquina (`Fetcher.lock_release_dependency_note`) e `test/lib/fetcher/lock_release_dependency_test.rb` mede a janela com um store que troca o token entre o read e o delete. **Os quatro call sites NÃO foram migrados** — o comportamento de produção é o de sempre; a migração é PR próprio, com o teste de cada um. **Regra geral: check-then-act inerte por acidente do store é dependência implícita — ou o código nomeia a dependência, ou ela vira bug sem ninguém avisado.** |
| 2026-09-26 | **[CORRIGIDO em 26/09/2026 — ver a entrada do card t_cbfa9f27 abaixo]** Aritmética de teto que soma só UM dos dois relógios subestima o pior caso: `open_timeout` e `read_timeout` são DOIS RELÓGIOS INDEPENDENTES POR FASE (ressalva Important do #204, card t_35bcd11f) | No Net::HTTP uma requisição faz connect (open) → escrever → ler a resposta (read) em SEQUÊNCIA, e o pior caso de UMA requisição é a MAIOR dos relógios que a fase impuser — a soma vem da SEQUENCIALIDADE das fases (connect → escrever → ler), não de orçamentos que se acumulam no mesmo relógio. `Faraday` confirma no código (`faraday/adapter.rb:97` resolve `options[key] \|\| options[:timeout]` com chaves distintas; `faraday/adapter/net_http.rb:140-145` tem dois `if` independentes), mas a prova que fecha é de **relógio de parede com controle**, e ela foi REESCRITA no card t_cbfa9f27 (`scripts/proofs/http_timeout_fases_independentes_proof.rb`): o proxy da prova original aceitava a conexão na hora e só dormia depois, então o atraso caía dentro da janela de `read` (medido: 1,21s sem proxy, 2,21s com proxy — mesmo atraso, o controle não controlava nada). A nova retém o SYN de verdade: open=1,5/read=10,0 → `Net::OpenTimeout` em 1,50s, open=10,0/read=1,0 → `Net::ReadTimeout` em 3,03s, e as duas fases folgadas → HTTP 200 em 3,23s. A aritmética de `x_query_id_resolver_timeout_test.rb` somava só o open: pior caso de 9s contra join de 10s e TTL de 60s — mas o real é 3 × (3+3) = 18s, que estourava o join de 10s por 8s | Travar a aritmética **completa** e provar por **par de mutação** (mesma mutação: verde com o teste antigo, vermelho com o novo — `scripts/proofs/timeout_arithmetic_mutation_pair.sh <commit-base>`; o commit-base é OBRIGATORIO e o script julga o próprio veredito, porque `HEAD~1` é degenerado e o script antigo saía com 0 mesmo com o par falso; o filtro `/pior_caso/` é o que torna o par honesto, porque os testes de configuração pegam qualquer mudança no read). `BACKGROUND_JOIN_TIMEOUT` subiu para 25,0s (acima dos 18s medidos, folga de 1,4x, abaixo do TTL de 60s) — o `HTTP_OPEN_TIMEOUT`/`HTTP_READ_TIMEOUT` de 3s NÃO foram mexidos, porque reduzir o timeout do cliente para fechar a conta reabriria o defeito que o #204 mediu. **Segunda lição, do furo que a própria correção abriu: `nil` de timeout ausente não pode ser `compact`ado na soma** — com o read removido do cliente a conta imprimia "3s open + 3s read = 3s" e ficava verde; o `nil` tem que valer o que o Net::HTTP usa de verdade (60s) e o teste afirmar sobre o que o cliente DECLARA, não sobre a soma. **Regra geral: teto é o MAIOR dos relógios que a operação realmente consome, mais o teto TOTAL que envolve a requisição inteira — e cada relógio ausente tem que fazer a conta estourar, não sumir.** |

| 2026-09-26 | **[CORRIGIDO em 26/09/2026 — card t_ab1dd082, revisão A do #205: os 31 são PISO, e o "pior caso real" era uma GARANTIA FALSA]** Pior caso de teto herdado do FIXTURE: `CORE_CHUNK_PATTERNS` tem 30 padrões e o pior caso da descoberta NÃO cabe no TTL (ressalva Important do #205, item 3, card t_cbfa9f27) | O pior caso de uma descoberta vinha de `allowed.size + 1` com `allowed` lido do FIXTURE (3 bundles), e o teste afirmava que isso cabia no `LOCK_TTL` de 60s. Mas `filter_allowed_bundle_urls` aceita o que casar com QUALQUER um dos 30 padrões de `CORE_CHUNK_PATTERNS` (30, medido no array em `lib/fetcher/x_query_id_resolver.rb` linhas 15-46), e o `home` que o X serve traz um `<link rel="preload">` por bundle. Com o teto total por requisição de 8s, o pior caso REAL (estático) é 31 requisições x 8s = **248s**, contra TTL de 60s — não fecha. A medição de `test/lib/fetcher/x_query_id_resolver_timeout_test.rb` registra os dois números: o pior caso do fixture (3 x 8s = 24s, que cabe no join de 25,0s) e o pior caso de código (31 x 8s = 248s, que NÃO cabe no TTL) — **[CORRIGIDO] os dois números estavam certos, mas o SEGUNDO estava Rotulado como teto, e não é: a contagem de padrões é PISO, não teto** | Número **estático**, não medição ao vivo: quanto o X serve hoje não é sabível daqui, e a garantia precisa valer no pior caso que o CÓDIGO permite. A garantia do lock foi renomeada no código para o que ela é: a exclusão serializa quem descobre, e o TTL é a janela de reabertura — um segundo processo entrando durante uma descoberta longa é comportamento ACEITO (devolve `:lock_busy` e o valor em cache, não busca em paralelo). **[CORRIGIDO no card t_ab1dd082] O "segundo teto estático, o número de bundles" NÃO EXISTE**: `filter_allowed_bundle_urls` é um `select` por NOME de arquivo, então ele aceita N bundles com o mesmo padrão — MEDIDO por execução do método real: 50 URLs `main.<hash>.js` distintas, todas casando com UM ÚNICO padrão, dão `allowed.size = 50` (51 requisições, 408s), e 200 URLs em 2 padrões dão 200. Não há constante de limite de bundles, porque um limite aqui seria escolha de produto (e o #205 não pediu um); o que o código faz é nomear a ausência de teto.** **Regra geral: teto de garantia validado contra o FIXTURE é teto de caso feliz — e uma CONTAGEM de itens permitidos NÃO é teto de nada, porque a lista de permitidos cresce com o que o servidor serve. O teto de verdade é o que o CLIENTE respeita por operação (aqui `HTTP_TOTAL_TIMEOUT`, 8s), e o total de operações é um PISO a ser medido e nomeado, nunca um teto a ser afirmado.** |
| 2026-09-26 | Resposta CORTADA pelo teto vira PIN cacheado por 25h: timeout reportado como "o X não tem o id" (achado 3 da revisão A do #205, card t_ab1dd082) | `discover_with_outcome!` tratava `Faraday::TimeoutError` no laço de bundles com `rescue StandardError; next` — o mesmo `next` de um 404. O laço terminava, `query_id` ficava nil, e o desfecho `:not_found` GRAVAVA O PIN por 25h (`expires_in: 25 * 3600`). Um bundle lento do X (ou um drip que sobrevive ao `read_timeout`, medido em 37,01s) virava um id de última instância cacheado por um dia, e o `RefreshXQueryIdsJob` logava "nao encontrada nos bundles apos a busca" — quando a busca nem terminou. É a mesma classe do bug que o #203 fechou: um desfecho nomeado apontando para a causa errada, agora com 25h de valor em cima do erro | `respostas_truncadas` conta as requisições mortas no teto (`:discovery_truncated` desfecho novo, `Discovery` documentado, log do job mapeado com texto próprio). Houve corte? A busca é INCOMPLETA: o PIN **não** entra no cache e o desfecho diz que foi cortada, porque "não deu pra saber" e "não existe" são coisas diferentes. Sem nenhum corte, a ausência é ausência de verdade e o PIN continua honesto. O comportamento de produção só muda no caminho do timeout (o caminho de 404 e de ausência real fica como estava). Teste end-to-end em `test/lib/fetcher/x_query_id_resolver_test.rb`: drip de 1 byte a cada 50ms, `BUNDLE_BASE_URL` apontado para o servidor local, corte medido em 8,00s, desfecho `:discovery_truncated` e cache vazio. **Regra geral: `rescue` que engole erro e devolve o MESMO desfecho do "não achei" transforma falha de transporte em ausência de dado — e se esse desfecho grava um valor de último recurso por 25h, o transporte virou a fonte do valor.** |
<!-- Template para novas entradas:
| YYYY-MM-DD | Descrição concisa do bug | O que causou | Como foi resolvido (`arquivo.rb`, classe, método) |
-->

---

- Sidecar Python autenticado: o `PYTHON_SCRAPER_TOKEN` chega via `docker/.env.sidecar` (env_file do compose — PR #20 deps/infra; exemplo em `docker/.env.sidecar.example`). Sem o arquivo o `server.py` recusa subir (fail-closed, intencional).
## Decisões de Arquitetura Pendentes

> Questões abertas aguardando validação do usuário ou mais investigação.

- [ ] Estratégia de rate-limiting para scraping multi-plataforma (Twitter vs. Instagram)
- [ ] Escolha final de browser headless para Docker: Ferrum vs. Nodriver (Python)
- [ ] **DÍVIDA**: busca no X pode conter post promovido (anúncio entra como `article[data-testid="tweet"]`); sem marcador confiável medido — reavaliar com medição ao vivo.

---

## Cold Tier Protocol

> Conhecimento arquivado fora do MEMORY.md ativo. **NÃO carregar automaticamente** — buscar via `grep`/`rg` apenas sob demanda.

### Quando arquivar

| O que | Para onde | Gatilho |
|-------|-----------|---------|
| Decisão ratificada substituída | `decisions/` | Nova decisão sobrescreve a anterior |
| Bug resolvido e consolidado | `resolved_bugs/` | Consolidação mensal do MEMORY.md |
| Contexto de fase/sprint finalizado | `archived/` | Início de nova fase de trabalho |

### Formato do arquivo arquivado

`YYYY-MM-DD_descricao_curta.md` com:
- Data original da entrada
- Descrição do quê foi decidido/descoberto
- Referência ao arquivo/classe afetado
- Motivo da decisão ou resolução

### Consulta

Quando o agente está no passo 2 das Escalation Rules (segunda falha), consultar a seção "Lições Aprendidas" em `docs/MEMORY.md`:
```bash
rg "<palavra-chave do problema>" docs/MEMORY.md
```

---

## Log de Mudanças na Memória

> Registro cronológico de cada write-back realizado neste arquivo.

| Data | Ação | Seção Afetada |
|------|------|---------------|
| 2026-09-26 | Quatro bloqueantes da revisão A do #205 fechados (card t_ab1dd082) — detalhado na seção de Lições Aprendidas. |
| 2026-09-26 | [CORRIGIDO em 26/09/2026, card t_ab1dd082] A entrada do item 3 do #205 afirmava, na coluna "resolvido", um "segundo teto estático, o número de bundles" (`CORE_CHUNK_PATTERNS.size + 1`) que **NÃO EXISTE no código** — o filtro é um `select` por nome, e o número de bundles não é limitado (medido: 50 URLs de um padrão passam todas, 408s). A coluna do "o que causou" mantinha "pior caso REAL (estático) é 31 requisições x 8s = 248s", que é um PISO vendido como teto; e a regra geral não dizia que contagem de permitidos não é teto. As três foram corrigidas no texto, com o resultado da medição, e a entrada do item 3 foi marcada `[CORRIGIDO em 26/09/2026]`. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | [CORRIGIDO em 26/09/2026, card t_cbfa9f27] Três redações que ainda afirmavam o que o #205 derrubou, na entrada do #204: (a) la "Regra geral" mandava **somar** os relógios (virou: o MAIOR dos relógios mais o teto TOTAL que envolve a requisição); (b) a prova citada era `http_timeout_cumulativo_proof.rb`, arquivo **deletado** neste card — trocada pela `http_timeout_fases_independentes_proof.rb`, com os números medidos nela; (c) a entrada do item 3 citava uma constante `MAX_DISCOVERY_REQUESTS` que **não existe no código** — o pior caso é lido do array real (`CORE_CHUNK_PATTERNS.size + 1`), sem constante duplicada que divergiria do código. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-25 | Lição: cliente do Chrome fala com o DevTools por IPv4 (Host por nome quebra o handshake WS no 151); conserto em `ferrum.rb` e `chrome_ws_connector.rb`. | Lições Aprendidas |
| 2026-08-29 | Implementação da Frente C: deduplicação de alertas de scraping por transição de incidente (`AlertThrottler`, `ScrapingFailureAlertJob`, `ScrapeYoutubeJob`). | Contexto Ativo, Padrões Ratificados |
| 2026-08-10 | Implementação da Fase 1 do Pipeline de Análise de Sentimento (migration 4 tabelas, Reddit+X sources, Classifier 3-way com snapshot fixo free, Aggregator por bucket, MessageBuilder com 5 números e 1 exemplo/classe, SentimentAnalysisJob e 3 tools owner-only). | Contexto Ativo |
| 2026-08-10 | Implementação da Tarefa F6-A (`Hackernews.search`, `Github.search`, `Polymarket.search`, pesos/aliases em `Signals`, desempate em `Scorer`). | Contexto Ativo |
| 2026-08-10 | Implementação do pipeline F6-C (`Last30DaysTopicJob`, `Last30DaysDigestJob`, `Last30Days::MessageBuilder`, dedupe `TopicDelivery`). | Contexto Ativo |
| 2026-08-10 | Implementação da Tarefa F3 (PostScorer, ScorePostsJob, WeeklyDigestJob reescrito com chunking, shorts em YoutubeScraperService, post_snapshots na coleta com fuso SP e poda 180d). | Contexto Ativo |
| 2026-08-10 | Implementação das 4 tools de escrita de monitoramento (`AddProfileTool`, `SetProfileMonitoringTool`, `RemoveProfileTool`, `PromoteProspectTool`) com autorização fail-closed por allowlist e `RemoveProfileTool` em 2 etapas. | Contexto Ativo |
| 2026-08-09 | Decisão de modelo único Gemma 4 31B (`gemma_client.rb`) substituída: split Gemini background/interactive + cadeia nous → poolside → openrouter. | Padrões Ratificados |
| 2026-08-09 | Correção de documentação: o TTL 30min do `ChatSessionManager` só despeja o objeto quente — conversas vivem no SQLite e a fronteira entre conversas é o `/new` (entrada de 2026-03-23 corrigida). | Contexto Ativo |
| 2026-03-30 | Atualização de arquitetura OCI Free Tier: Substituído o `/swapfile` (disco físico) por gerador de memória comprimida `zRAM`, minimizando o esgotamento de IOPS no boot volume. Ajustado swappiness de 10 para 100. Adição de parâmetros de cifra (Ciphers/MACS) estritos ao hardening SSH. | Contexto Ativo, Padrões Ratificados |
| 2026-03-28 | Correções deploy.sh: rollback com git reset --hard (em vez de git checkout), snapshot de Docker image IDs pré-deploy para possibility de rollback completo de containers. | Contexto Ativo |
| 2026-03-28 | Correções review PR #10: oracle-cloud-setup.sh — propagar $DOCKER_USER para limits.d (Phase 8) e chown (Phase 9), sshd -t antes de restart SSH, iptables idempotente com -C check, fstab append com grep -qF. ERROS.md checklist atualizada. | Contexto Ativo, Lições Aprendidas |
| 2026-03-28 | Infraestrutura Oracle Cloud + Deploy CI/CD: workflow GitHub Actions, deploy script SSH, setup script VM (9 fases), docs Free Tier + setup guide. Decisão: Oracle Always Free como hospedagem. | Contexto Ativo |
| 2026-03-26 | Fase 6 implementada: health check, scraping alerts, image gen, SQLite backup. Padrões ratificados: ruby_llm 1.14, sem OpenStruct em Ruby 4.0, safe navigation para $CHILD_STATUS, mocks para DB em integration tests. Lições: to_s(:db) não funciona em Ruby 4.0, stubs Mocha vazam em connection pool. | Contexto Ativo, Padrões Ratificados, Lições Aprendidas |
| 2026-03-23 | Fase 5 implementada: Discord Bot + 16 tools + digest jobs. Padrões ratificados: discordrb 3.7, requires explícitos em tests, partials com prefixo `_`. | Contexto Ativo, Padrões Ratificados |
| 2026-03-22 | Criação inicial do MEMORY.md com padrões ratificados extraídos do AGENTS.md e docs/ | Todas |
| 2026-03-22 | Adicionadas Definition of Done e Escalation Rules ao AGENTS.md | AGENTS.md |
| 2026-03-22 | Criado Cold Tier protocol em MEMORY.md + estrutura `docs/memory/` | Cold Tier Protocol |
| 2026-03-29 | Correções pós-audit: deploy.sh (A1-A7) + oracle-cloud-setup.sh (B7,B9,B11-B14) | Contexto Ativo |
| 2026-03-30 | Deploy hardening (Propostas 1-3): set -Eeuo pipefail, healthcheck nativo docker-compose, image tagging com IMAGE_TAG, --wait em vez de health check loop, rollback sem rebuild, FASE 10.5 systemd timer cleanup. | Contexto Ativo |
| 2026-03-30 | Correções script↔guia: KexAlgorithms pós-quântico (sntrup761x25519) no SSH, tabela de fases 9→10 com NTP/Chrony (FASE 7), Fail2Ban dual jail, troubleshooting zRAM. | Contexto Ativo |
| 2026-08-09 | Decisão arquitetural registrada: execução Python via sidecar HTTP autenticado (8080, `PYTHON_SCRAPER_TOKEN`) em vez de `Open3` in-process. | Padrões Ratificados |
| 2026-08-10 | Fase 3 implementada e revisada: fusão RRF + clustering (`lib/research/fusion.rb`, `lib/research/cluster.rb`). Decisão de escala registrada (local_relevance como score de trabalho, rrf para ordenação). Entity-cluster da Fase 4 adiado (depende de entity_extract). | Contexto Ativo, Padrões Ratificados, Lições Aprendidas |
| 2026-08-10 | Atualização da busca por assunto no X: X.search com marcador de estado vazio `empty_state_header_text`, SEARCH_BUDGET/TIMELINE_BUDGET (30/h), scope em RateLimited e fronteira @perfil/assunto em PlatformSearchTool. | Contexto Ativo, Padrões Ratificados |
| 2026-08-31 | Implementação da busca X via GraphQL (`XGraphql`, `RefreshXQueryIdsJob`, HostRateLimiter scope graphql_search). | Contexto Ativo, Padrões Ratificados |
| 2026-09-25 | Leitura do X unificada (`Fetcher::XLeitura`, `x:buscar`, `x:conversa`), autor da busca em `core`, resolver com sessão e sem PIN cruzado. | Contexto Ativo |
| 2026-08-10 | 2ª rodada de correções na Fase 1 do pipeline de sentimento: montagem completa de janelas no frozen_spec do Job/Collector com descarte em rejected_count, escada de modelos LLM por lote com AllModelsFailed + cota diária (150 req/dia), pacing do Reddit 35s sem pré-incremento do HostRateLimiter, interleave entre fontes, validação estrita de IDs e status delivery_failed se canal digest for nulo. | Contexto Ativo, Padrões Ratificados |
| 2026-08-10 | 3ª rodada de correções na Fase 1 do pipeline de sentimento: remoção incondicional da ramificação allow_paid (AllModelsFailed sempre que a escada free esgota), janela efetiva iniciada com started_at + 1.minute e filtro estrito p_time > w_end, cota diária atômica via SentimentDailyQuota com row lock, pacing do Reddit por leituras efetivas e suite completa de testes de regressão (1 fonte, 6º alvo via tool, job integrado com Collector real). | Contexto Ativo, Padrões Ratificados |
| 2026-08-10 | 4ª rodada de correções na Fase 1 do pipeline de sentimento: substituição da transação com row lock em SentimentDailyQuota por UPDATE condicional atômico (insert_all idempotente ON CONFLICT DO NOTHING + update_all count < limit) e teste concorrente de 8 threads com barreira, PRAGMA busy_timeout = 10000 e validação de cota estrita sem erros de banco. | Contexto Ativo, Padrões Ratificados |
| 2026-09-26 | Quatro ressalvas do PR #203 fechadas (card t_83c93e21): (1) retorno cru apaga o desfecho — `force: true` que perdeva a corrida do lock logava "refresh concluído" sem ter descoberto nada; agora `resolve_with_outcome` devolve a CAUSA e o job dá nível e texto próprios (`info` só quando descobriu de verdade); (2) o TTL de 60s era garantia FALSA — sem timeout no cliente HTTP, o pior caso era 180s (3 requisições x 60s do Net::HTTP) contra TTL de 60s; medido com o SolidCache real que o lock expira com o dono vivo e um segundo processo busca; com timeout de 3s o pior caso cai para 9s (6,7x de folga) e cabe no join de 10s; (3) teto do join de 10s era drenagem-com-prazo e o Faraday era sem timeout — os dois foram fechados pelo timeout explícito e pelos testes que travam a aritmética; (4) os 4 check-then-act inertes da liberação de lock: escolha (b), documentar a dependência no código com `Fetcher.release_lock_atomically` (devolve `:released`/`:released_non_atomic`/`:not_owner`) e um teste que mede a janela no caminho genérico — os 4 call sites ficaram para o PR seguinte. |
| 2026-09-26 | Três lições do #203 fechadas (card t_83c93e21): desfecho nomeado atravessa a chamada; TTL de lock só é garantia se o trabalho sob ele tem TETO medido (não afirmado); check-then-act inerte por acidente do store é dependência implícita que precisa de nome, senão vira bug sem ninguém avisado. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | Duas lições do flake do lock do `XQueryIdResolver` (PR #203, card t_f9a9f47e): (1) `Thread.new` fire-and-forget em refresh de cache atravessa a fronteira do chamador e, porque o WebMock indexa por URL, o fetch vazado entra no contador do teste SEGUINTE — a thread precisa ser guardada e alcançável por join; (2) lock por `read`+`write` em cache compartilhado não é lock (janela entre as duas operações) — a aquisição tem que ser `write(..., unless_exist: true)`, e o lock NÃO pode ser apagado ao fim (a fila inteira buscaria de novo: medido 5 threads → 5 fetches). | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | Quatro bloqueantes da revisão A do #205 fechados (card t_ab1dd082): (1) **os 31 são PISO, não TETO** — `filter_allowed_bundle_urls` é `select` por nome, então 50 URLs de UM padrão passam todas (medido: 408s) e 200 URLs em 2 padrões dão 200; o "pior caso real" de 248s era garantia FALSA e saiu do código, do teste e do MEMORY.md, substituído pelo teto POR REQUISIÇÃO, que é o único que o cliente respeita; (2) o comentário de `LOCK_TTL` afirmava a garantia antiga e a negava seis linhas abaixo — agora é UMA fonte, e um teste novo amarra a prosa ao código lendo o bloco do disco (com o texto normalizado: sem acento e sem o `#` de cada linha, senão o regex não casa com o que o comentário diz); (3) resposta CORTADA pelo teto virava PIN de 25h com `reason: :not_found` — agora `:discovery_truncated`, sem cache, com log no job; (4) a garantia do join era 1,04x do fixture, e o teste passa a afirmar as DUAS metades: o join cobre o fixture, e 4 bundles permitidos já o estouram. Comportamento de produção muda só no caminho do timeout. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | Duas lições das ressalvas do #204 (card t_35bcd11f): (1) `open_timeout` e `read_timeout` são relógios INDEPENDENTES POR FASE **[CORRIGIDO em 26/09/2026 pelo card t_cbfa9f27: a semântica é SEQUENCIALIDADE, não cumulatividade]** — a aritmética de teto que soma só o open subestima o pior caso (9s medidos contra 18s reais, que estouram o join de 10s), e a prova que fecha é de relógio de parede COM CONTROLE, não de citação de código; (2) um `nil` de timeout ausente não pode ser `compact`ado na soma — com o read removido do cliente a conta ficava verde. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | [CÓDIGO] Entrada do `lock_release.rb` completada: a doc não promete mais `:no_store_support` (desfecho que o método nunca produzia) e registra que a escolha foi (b) tirar da documentação, com o porquê — o store sem CAS não é caso sem saída, recebe `:released_non_atomic` e um `:no_store_support` seria MENOS informativo. Teste novo amarra a doc ao código (`test_a_doc_nao_promete_desfecho_que_o_codigo_nao_emite`). Comportamento de produção inalterado. | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | Rodada final do #205 (card t_286ae8bb, revisão r2): três correções, todas por RED→GREEN medido. **(1) O `nil` do `:discovery_truncated` era REGRESSÃO DE PRODUÇÃO, não conserto** — a rodada anterior trocou o silêncio do cache (o defeito real) por `value=nil`, e o chamador de produção (`x_graphql.rb:90` e `:379`, que usa `resolve` e recebe só a String) montava `https://x.com/i/api/graphql//SearchTimeline`, com id VAZIO no path, sem nenhum log: um `nil` que ninguém consegue ver é tão mudo quanto um `:not_found` que se. Agora o `value` VOLTA (o id real visto na busca, ou o PIN de última instância quando não houve nenhum), o `return` do truncado saiu de ANTES do `if query_id.nil?` (um id real visto num bundle posterior era descartado) e o corte vira `warn` ALTO que nomeia a URL de cada bundle cortado e diz que o valor servido veio de resposta truncada. O PIN servido em busca truncada continua sem ir para o cache — 25h de um id que nenhuma requisição completa viu era o defeito original. **A lição: corrigir o silêncio pelo `nil` é trocar um silêncio por outro; o conserto de um `nil` que o chamador consome em silêncio tem de ser o valor de volta mais o log ALTO — e o teste tem de ser no NÍVEL DO CHAMADOR, porque o teste que só olha o cache passa com a URL quebrada (foi assim que a regressão entrou).** (2) O guard do `LOCK_TTL` tinha os 2 furos da r2, e fecha-los exigiu SEMÂNTICA, não regex: o refute é sobre AFIRMAR a promessa, não sobre ela OCORRER (o bloco honesto cita a garantia velha para descartá-la). A regra é por ORAÇÃO (até o ponto final; a quebra de linha é irrelevante) com duas metades — a ADVERSATIVA (", não …"), que vale a qualquer distância porque se liga ao que veio antes, e o verbo de negação COLADO (até 20 caracteres). Três tentativas falharam antes e as três estão medidas no teste: janela solta (o "não" de cima validava a de baixo), janela ancorada (a citação honesta do 248s era accusada), frase-inteira (a frase seguinte absolvia a anterior). Medido por mutação no arquivo: promessa em prosa → pega; "31 vezes 8 segundos = 248 segundos" → pega. **(3) `x_query_id_lock_ttl_test.rb` era a segunda fonte da garantia velha** (achado Minor da r2): o cabeçalho afirmava que o TTL É a garantia, e a aritmética do terceiro teste provava que ela era falsa supondo "nenhuma requisição tem timeout" (60s do Net::HTTP) — suposição morta desde o `HTTP_TOTAL_TIMEOUT` de 8s. A conta nova mede o motivo certo: o fixture (3 req × 8s = 24s) CABE no TTL de 60s, e 50 bundles de UM padrão passam o filtro (`select` por nome não é contador) → 51 req × 8s = 408s, que estoura. **(4) `http_timeout_fases_independentes_proof.rb` saía 0 quando NÃO confirmava** — o exit é `exit(ok ? 0 : 1)`, o mesmo do outro proof da casa; medido forçando o veredicto a falso numa cópia: exit 1. **Regra geral: um guard de prosa é um teste de mutação, não um regex — e um `nil` que o chamador consome tem de ser medido no chamador.** | Lições Aprendidas de Bugs Recorrentes |
| 2026-09-26 | Ressalvas do #205 fechadas (card t_cbfa9f27): (1) a semântica de `open`/`read` é **SEQUENCIALIDADE**, não cumulatividade — são DOIS relógios independentes por fase, e a prova agora retém o SYN de verdade (fila de accept cheia, sem `accept()`): open=1,5/read=10,0 dá `Net::OpenTimeout` em 1,50s, o que a semântica cumulativa daria como PASS; (2) `read_timeout` é teto **POR LEITURA** (medido: 21,02s e 37,01s com teto de 1,0s), então a descoberta ganhou `HTTP_TOTAL_TIMEOUT` de 8s por requisição — o mesmo drip morre em 8,00s; (3) o pior caso real é **31 requisições** (30 padrões de `CORE_CHUNK_PATTERNS` + home), não 3: 248s contra TTL de 60s, e a garantia do lock foi renomeada para o que ela é; (4) o guard do script do par por mutação lia o arquivo inteiro em vez da asserção, e a mutação do read passou de 3→8 para 3→20 porque o `max` da aritmética nova só muda com o read acima do teto total. **(5) MEDIDO nesta rodada: o script do par não validava o próprio veredito** — imprimia a palavra "ESPERADO" ao lado do número e saía com `exit 0` sempre, então um par FALSO passava por prova; e o default `COMMIT_ANTES=HEAD~1` é degenerado por construção (depois do commit da aritmética nova, `HEAD~1` já é a nova: o passo 1 deu 2 failures). O script agora julga os três passos (`registrar`), sai com 1 se algum sair fora do esperado, e o commit-base virou parâmetro obrigatório (exit 2 sem ele) — medido: `971308d` dá par CONFIRMADO (exit 0), `HEAD~1` dá NÃO CONFIRMADO (exit 1). | Lições Aprendidas de Bugs Recorrentes |

---

## Decisões arquiteturais — PR #32 (2026-08-09)

- **Headers extras no SafeHttpClient com regra de origem**: `get(url, headers:)` envia os headers apenas na origem original; redirect SAME-ORIGIN (scheme+host+porta normalizada) preserva, qualquer mudança de origem (cross-host, downgrade HTTPS→HTTP, origem inparseável) limpa — fail-closed. Motivo: `Authorization: Bearer` do canal GitHub não pode vazar para outro domínio, mas repo transferido (redirect 301 same-host) precisa manter a autenticação.
- **Teto externo por URL no ExtractService**: `TOTAL_PER_URL_TIMEOUT = CHANNEL_TIMEOUT` (40s) imposto por `Timeout.timeout` em volta de toda a extração em `ExtractService.call`. O caminho comum (estático 25s + browser 25s) roda SEQUENCIAL e gastaria 50s/URL; o teto externo torna a conta "2 ondas × 40s = 80s < 90s" do reader verdadeira. `Timeout::Error` vira failure no contrato, nunca 500.
- **Política de erro de canal**: erro de API (não-2xx nomeado) NÃO faz fallback para o caminho comum — vira `error` por URL. Exceção deliberada: GitHub 403/429/5xx devolve nil (escala para o HTML) porque a cota anônima de 60 req/h estouraria e derrubaria TODAS as issues; 404 continua erro nomeado (`IssueNotFound`).
- **Canais não cobram rate limit próprio no ExtractService**: `HostRateLimiter.exceeded?` no ExtractService (via `budget_for` com `MAX_PER_WINDOW` do canal) previne cobrança dupla. Exceção deliberada: `Fetcher::Channels::X` cobra orçamentos próprios logados (`TIMELINE_BUDGET` e `SEARCH_BUDGET`, 30 req/h cada, 4 req/min com escopo na mensagem de `RateLimited`) para proteger a conta pessoal do dono.
- **`/market/` do Polymarket não é canal**: a Gamma API de eventos só responde slug de evento; rotear `/market/` produziria `EventNotFound` duro. Market cai no caminho comum (nil).
