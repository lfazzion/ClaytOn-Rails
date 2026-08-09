# AGENTS.md — Cleitin Bot (Router)

Headless Rails 8.1 app for influencer data mining, scraping, and Discord bot integration. Ruby ~> 4.0, SQLite3 (WAL), Solid Queue/Cache, Minitest. All commands run inside Docker.

## Folder Map

```
app/
  jobs/              — ActiveJob classes (Solid Queue)
  models/            — ActiveRecord models
  services/          — Business logic orchestrators
    discovery/       — Profile classification & graph analysis
  tools/             — LLM tool definitions
lib/
  llm/               — LLM clients (Gemini, Gemma, OpenRouter)
  scraping/          — Scraping services, Python bridge
  chrome_ws_connector.rb
config/
  prompts/           — YAML prompt templates (system/, partials/)
db/
  migrate/           — App migrations
  queue_migrate/     — Solid Queue migrations
  cache_migrate/     — Solid Cache migrations
docker/              — Dockerfile, docker-compose.yml
scripts/python/      — Python scraping scripts (nodriver, camoufox)
test/                — Mirrors app/ structure
  factories/         — FactoryBot factories
docs/                — Architecture docs, comparisons, strategies
```

## Routing Table

What are you doing? Go read the CONTEXT.md for that workspace.

| Tarefa | Ler | Pular | Notas |
|--------|-----|-------|-------|
| Novo model, schema, migration | `app/models/CONTEXT.md`, `db/CONTEXT.md` | `lib/`, `scripts/` | |
| Novo job, coleta de dados | `app/jobs/CONTEXT.md`, `lib/scraping/CONTEXT.md` | `config/prompts/` | Jobs devem ser idempotentes |
| Serviço de negócio, orquestração | `app/services/CONTEXT.md` | `lib/`, `scripts/` | |
| Tool LLM, tool call | `lib/llm/CONTEXT.md` | `lib/scraping/` | Regras no próprio AGENTS.md (seção futura) |
| Integração LLM, prompt | `lib/llm/CONTEXT.md`, `config/prompts/CONTEXT.md` | `lib/scraping/`, `app/jobs/` | |
| Scraper Ferrum, Chrome, Python | `lib/scraping/CONTEXT.md`, `scripts/python/CONTEXT.md` | `config/prompts/`, `app/tools/` | |
| Endpoint HTTP, fetch de URL externa | `docker/CONTEXT.md` | `app/tools/` | URL de fora passa por `Fetcher::SafeHttpClient`; nunca `Net::HTTP` direto |
| Escrever testes | `test/CONTEXT.md` | — | Sempre dockerizado |
| Configurar Docker | `docker/CONTEXT.md` | `app/`, `lib/` | |
| Consultar docs / estratégia | `docs/CONTEXT.md` | — | Apenas leitura |
| **Qualquer tarefa sistêmica** | **`docs/MEMORY.md`** | — | **Leitura obrigatória antes de iniciar** |

## Commands

All commands from project root, always dockerized:

```bash
# Docker
docker-compose -f docker/docker-compose.yml up -d
docker-compose -f docker/docker-compose.yml down
docker-compose -f docker/docker-compose.yml build

# Tests
docker-compose -f docker/docker-compose.yml run --rm test
docker-compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb
docker-compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb -n "/test_name_pattern/"

# DB & Console
docker-compose -f docker/docker-compose.yml exec app bin/rails db:migrate
docker-compose -f docker/docker-compose.yml exec app bin/rails console
```

## Cross-Cutting Rules

These apply everywhere. Domain-specific rules live in each CONTEXT.md.

1. `# frozen_string_literal: true` on every Ruby file
2. 2-space indentation, double quotes, ~120 char lines
3. Metrics (likes, views, followers): `nil` on failure, never `0`
4. Never retry scraping on 403/429/captcha — backoff 6-12 hours
5. Always close browser connections in `ensure` blocks
6. Log with `[ClassName]` prefix: `Rails.logger.error "[MyClass] message"`
7. Prompts in YAML (`config/prompts/`), never hardcoded strings
8. Inject timestamp in every prompt: `<current_datetime: <%= Time.current.in_time_zone("America/Sao_Paulo").to_s %>>`

## Definition of Done

A task is complete ONLY when ALL conditions are met:

| # | Condition | Verification |
|---|-----------|-------------|
| 1 | Tests pass (0 failures, 0 errors) | `docker-compose -f docker/docker-compose.yml run --rm test` |
| 2 | No syntax warnings on modified files | `ruby -cw <file>` for each changed `.rb` |
| 3 | Migration runs cleanly (if applicable) | `docker-compose -f docker/docker-compose.yml exec app bin/rails db:migrate:status` |
| 4 | New code has corresponding tests | Test file exists in `test/` mirroring `app/` or `lib/` |
| 5 | MEMORY.md updated (if architectural decision) | Entry added with `[YYYY-MM-DD]` format |
| 6 | No hardcoded secrets or credentials | Manual review of changed files |

**Never declare a task complete without running condition #1.**

## Escalation Rules

When stuck, follow this order. NEVER skip steps.

| Step | Action | When |
|------|--------|------|
| 1 | Re-read the relevant `CONTEXT.md` and retry | First failure |
| 2 | Check `docs/MEMORY.md` for "Lições Aprendidas" | Second failure |
| 3 | Search `docs/memory/` for historical context | Third failure |
| 4 | Document the problem in "Decisões Pendentes" and **STOP** | After 3 failures |

**NEVER do these when stuck:**
- Delete existing code to "fix" an error you don't understand
- Modify tests to make them pass without understanding the root cause
- Remove validations or error handling to bypass a problem
- Retry scraping on 403/429/captcha (rule #4 above)

## Naming Conventions

| Tipo | Convenção | Exemplo |
|------|-----------|---------|
| Class | PascalCase | `TwitterCollectJob` |
| Job file | `snake_case_job.rb` | `scrape_twitter_job.rb` |
| Service file | `snake_case_service.rb` | `ai_router.rb` |
| Model file | `snake_case.rb` | `social_profile.rb` |
| Test file | `*_test.rb` mirroring app | `test/models/social_profile_test.rb` |
| Migration | `TIMESTAMP_description.rb` | `20260314000001_create_social_profiles.rb` |
| Prompt | `snake_case.yml` | `config/prompts/system/analysis.yml` |
| Python script | `snake_case.py` | `scripts/python/nodriver_twitter.py` |

## Key Design Decisions

- Headless Rails: no ActionView, no Sprockets, JSON API only
- SQLite WAL, 3 connections (primary, queue, cache) in single file
- Solid Queue replaces Redis/Sidekiq; Solid Cache replaces Redis cache
- Idempotent collection jobs — safe to re-run without duplicates
- Snapshot dedup window: 2 hours

## Memory Protocol

> `docs/MEMORY.md` é a **fonte de verdade viva** do projeto. Trate-o como autoritativo.

1. **Leitura obrigatória:** NO INÍCIO de toda tarefa sistêmica (nova feature, debug, refactor, migration), você DEVE ler `docs/MEMORY.md` antes de escrever qualquer código.
2. **Consulta antes de decidir:** Antes de propor uma decisão de arquitetura, verifique se ela já está ratificada em "Padrões Sistêmicos Ratificados".
3. **Consulta antes de debugar:** Antes de investigar um bug, verifique se ele já está documentado em "Lições Aprendidas de Bugs Recorrentes".
4. **Nunca contradizer:** Se uma decisão ratificada existir no MEMORY.md, nunca proponha o contrário sem antes informar o conflito ao usuário.

## Write-Back Protocol

> Protocolo de atualização autônoma do `docs/MEMORY.md`. O agente DEVE executar write-backs nos cenários abaixo.

### Gatilhos de Escrita

| # | Gatilho | Seção Alvo | Quando |
|---|---------|------------|--------|
| 1 | Bug resolvido após > 3 tentativas ou descoberta não-trivial | Lições Aprendidas de Bugs Recorrentes | Gate: rascunhar na sessão atual, sugerir na próxima para aprovação do usuário |
| 2 | Decisão de arquitetura ratificada (com aprovação do usuário) | Padrões Sistêmicos Ratificados | Após confirmação do usuário |
| 3 | Mudança de foco / novo sprint / nova fase de trabalho | Contexto Ativo do Projeto | Ao iniciar a nova fase |
| 4 | Nova questão em aberto identificada | Decisões de Arquitetura Pendentes | Ao identificar a questão |

### Formato do Write-Back

Toda entrada DEVE incluir:
- `[YYYY-MM-DD]` — data da entrada
- Descrição concisa do quê foi decidido/descoberto
- Referência ao arquivo/classe afetada
- **Motivo** — o porquê da decisão ou o problema que ela resolve (ex: "evita quebra de build ao rodar lint antes do commit")

Toda atualização DEVE ser registrada no "Log de Mudanças na Memória" ao final do arquivo.

### Regras Anti-Poisoning

1. **NUNCA** modificar ou remover entradas sem registrar a alteração no "Log de Mudanças na Memória".
2. Para corrigir imprecisões, editar a entrada existente e anotar `[CORRIGIDO em YYYY-MM-DD]`.
3. Entradas obsoletas devem ser **deletadas** do MEMORY.md e registradas no Log com formato: `[YYYY-MM-DD] REMOVIDO: <descrição> — <motivo>`.
4. O Log de Mudanças é o único local que preserva histórico de entradas removidas — nunca manter conteúdo obsoleto no MEMORY.md.

### Manutenção

- Revisar o MEMORY.md **mensalmente**: remover entradas obsoletas, consolidar duplicatas, registrar remoções no Log.
- Limite prático: manter o MEMORY.md com no máximo **200 linhas**. Acima disso, mover detalhes para topic files separados referenciados por link.
- Entradas removidas do MEMORY.md devem ser arquivadas em `docs/memory/` (decisions/, resolved_bugs/, archived/) antes de deletar.

### Cold Tier

`docs/memory/` armazena conhecimento arquivado que NÃO deve ser carregado automaticamente. Consultar via `grep`/`rg` apenas no passo 3 das Escalation Rules. Ver `docs/memory/CONTEXT.md` para formato e regras.
