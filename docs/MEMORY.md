# MEMORY.md — Cleitin Bot Write-Back Memory

> **Fonte de verdade viva do projeto.** Este arquivo é lido obrigatoriamente pela IA no
> início de toda tarefa sistêmica e atualizado autonomamente via Write-Back Protocol
> definido em `AGENTS.md`.

---

## Contexto Ativo do Projeto

> O que estamos construindo / investigando nas últimas 48h.

- **[2026-08-29]** Frente C — Deduplicação de alertas de scraping por transição de incidente (`AlertThrottler`, `ScrapingFailureAlertJob`, `ScrapeYoutubeJob`).
  - Alerta por TRANSIÇÃO: notifica no 1º incidente, em alteração de causa (`error_type` ou `normalize_fingerprint(error_message)`), ou após recuperação com nova falha. Repetições diárias da mesma falha no mesmo perfil são descartadas.
  - Estado persistido em Solid Cache (`scraping_incident:#{scraper_name}:#{profile_id}`, TTL 30d) sem migrations no banco. Lock atômico com TTL 5min e double-checked locking para concorrência.
  - Rollback honesto de cota horária e liberação de lock em falha de envio ao Discord, canal admin não configurado ou quota horária esgotada.
  - Resolução de incidente (`AlertThrottler.resolve_incident`) no `ScrapeYoutubeJob` ao obter `collection_status: "success"`.
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
- **[2026-08-10]** Feature — Busca por assunto no X (`X.search`, `SearchFailed`, `SEARCH_BUDGET` 30/h, fronteira `@perfil`/assunto da tool `PlatformSearchTool`).
  - `Fetcher::Channels::X.search(query:, limit: 10)`: busca nativa no X com `f=live&src=typed_query`. Detecção do estado vazio legítimo via marcador `[data-testid="empty_state_header_text"]` (retorna `[]`); sem marcador, levanta `SearchFailed`. `SEARCH_BUDGET` e `TIMELINE_BUDGET` reduzidos para 30/h (4/min) mantendo teto da conta do dono em ~60/h. Mensagem de `RateLimited` inclui o escopo (`[timeline]` / `[search]`).
  - `PlatformSearchTool`: exige `@` explícito para perfis (ex: `@jack` -> `X.timeline`); termos sem `@` (frases ou palavras soltas ex: `bitcoin` ou `ruby rails`) acionam `X.search`.
  - Prompts do chatbot (`chatbot.yml`) e MCP tool (`platform_search.rb`) atualizados para refletir a busca por assunto no X.
- **[2026-08-10]** Tarefa F6-A — busca por assunto nos canais Hackernews, Github e Polymarket (`lib/fetcher/channels/`) + ajustes no `Research::Signals` e `Research::Scorer`.
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
| 2026-08-29 | Implementação da Frente C: deduplicação de alertas de scraping por transição de incidente (`AlertThrottler`, `ScrapingFailureAlertJob`, `ScrapeYoutubeJob`). | Contexto Ativo, Padrões Ratificados |
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

---

## Decisões arquiteturais — PR #32 (2026-08-09)

- **Headers extras no SafeHttpClient com regra de origem**: `get(url, headers:)` envia os headers apenas na origem original; redirect SAME-ORIGIN (scheme+host+porta normalizada) preserva, qualquer mudança de origem (cross-host, downgrade HTTPS→HTTP, origem inparseável) limpa — fail-closed. Motivo: `Authorization: Bearer` do canal GitHub não pode vazar para outro domínio, mas repo transferido (redirect 301 same-host) precisa manter a autenticação.
- **Teto externo por URL no ExtractService**: `TOTAL_PER_URL_TIMEOUT = CHANNEL_TIMEOUT` (40s) imposto por `Timeout.timeout` em volta de toda a extração em `ExtractService.call`. O caminho comum (estático 25s + browser 25s) roda SEQUENCIAL e gastaria 50s/URL; o teto externo torna a conta "2 ondas × 40s = 80s < 90s" do reader verdadeira. `Timeout::Error` vira failure no contrato, nunca 500.
- **Política de erro de canal**: erro de API (não-2xx nomeado) NÃO faz fallback para o caminho comum — vira `error` por URL. Exceção deliberada: GitHub 403/429/5xx devolve nil (escala para o HTML) porque a cota anônima de 60 req/h estouraria e derrubaria TODAS as issues; 404 continua erro nomeado (`IssueNotFound`).
- **Canais não cobram rate limit próprio no ExtractService**: `HostRateLimiter.exceeded?` no ExtractService (via `budget_for` com `MAX_PER_WINDOW` do canal) previne cobrança dupla. Exceção deliberada: `Fetcher::Channels::X` cobra orçamentos próprios logados (`TIMELINE_BUDGET` e `SEARCH_BUDGET`, 30 req/h cada, 4 req/min com escopo na mensagem de `RateLimited`) para proteger a conta pessoal do dono.
- **`/market/` do Polymarket não é canal**: a Gamma API de eventos só responde slug de evento; rotear `/market/` produziria `EventNotFound` duro. Market cai no caminho comum (nil).
