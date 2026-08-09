# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Mandatory Pre-Task Reading

Before starting any systemic task (new feature, debug, refactor, migration), read `docs/MEMORY.md`. It is the living source of truth for architectural decisions and known bugs. This is non-negotiable.

Use the routing table in `AGENTS.md` to find the relevant `CONTEXT.md` for the area you're working in.

---

## Commands

All commands run from the project root and are always Dockerized.

```bash
# Start all services
docker compose -f docker/docker-compose.yml up -d

# Build images
docker compose -f docker/docker-compose.yml build

# Run all tests
docker compose -f docker/docker-compose.yml run --rm test

# Run a single test file
docker compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb

# Run a single test by name (Minitest converte o nome para underscore: "faz algo" → faz_algo)
docker compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb -n "/test_name_pattern/"

# Rails console
docker compose -f docker/docker-compose.yml exec app bin/rails console

# Run migrations
docker compose -f docker/docker-compose.yml exec app bin/rails db:migrate

# Check migration status
docker compose -f docker/docker-compose.yml exec app bin/rails db:migrate:status

# Verify Ruby syntax (run for each modified .rb file) — não há Ruby no host, roda no container
docker compose -f docker/docker-compose.yml run --rm --entrypoint ruby test -cw <file>

# Health checks
curl http://localhost:3000/health
curl http://localhost:3000/up
```

---

## Architecture

Headless Rails 8.1 API (no ActionView/Sprockets). A multi-container influencer data mining system where:

- **`app` (Puma)** — REST API, health checks only, orchestrates job enqueuing
- **`jobs` (Solid Queue)** — Background job processor (8+ recurring jobs via `config/recurring.yml`)
- **`discord-bot`** — Standalone Discord bot running `DiscordBotService.start`; handles natural-language queries via LLM tool calling (16+ tools in `app/tools/`)
- **`chrome`** — Headless Chromium on DevTools Protocol port 9222; Ferrum (`lib/scraping/`) connects to it
- **`python-scraper`** — Sidecar for hardened sites; Nodriver/Camoufox with Safari fingerprinting (`scripts/python/`)

**Data flow**: Discord message → `DiscordBotService` → `ChatSessionManager` → RubyLLM (Gemini Flash) → Tool calling → `app/tools/` → ActiveRecord → response

**Scraping flow**: Job → `lib/scraping/` (Ferrum) → Chrome CDP → target site; fallback to Python scraper sidecar for WAF-hardened sites

**Discovery flow**: `DiscoveryJob` → `app/services/discovery/` (graph analysis + classification) → `DiscoveredProfile`

### Key Directories

```
app/
  jobs/         — ActiveJob classes (Solid Queue); all idempotent
  models/       — ActiveRecord models
  services/
    discovery/  — Profile classification & graph analysis
  tools/        — LLM tool definitions (multiple classes per file)
lib/
  llm/          — LLM clients (Gemini, Gemma, OpenRouter, Imagen 3)
  scraping/     — Ferrum scrapers + Python bridge
config/
  prompts/      — YAML prompt templates; partials must use _ prefix (_name.yml)
  recurring.yml — Scheduled jobs (8 tasks)
db/
  migrate/      — App migrations; queue_migrate/ and cache_migrate/ are auto-managed
docs/
  MEMORY.md     — Living architectural memory; read before any systemic task
```

---

## Cross-Cutting Rules

1. `# frozen_string_literal: true` on every Ruby file
2. 2-space indentation, double quotes, ~120 char lines
3. Metrics (likes, views, followers): `nil` on failure, **never `0`** — zero means genuinely zero interactions
4. Never retry scraping on 403/429/captcha — back off 6–12 hours
5. Always close browser connections in `ensure` blocks
6. Log with class prefix: `Rails.logger.error "[MyClass] message"`
7. Prompts in YAML (`config/prompts/`), never hardcoded strings
8. Inject timestamp in every prompt: `<current_datetime: <%= Time.current.in_time_zone("America/Sao_Paulo").to_s %>>`
9. Jobs must be idempotent — use `find_or_initialize_by`; snapshot dedup window is 2 hours
10. Tools use silent clamps to prevent dangerous AI-triggered queries: `[[x, 1].max, 50].min`

---

## Ruby 4.0 Gotchas (Ratified Patterns)

| Issue | Resolution |
|-------|-----------|
| `OpenStruct` removed from stdlib | Use plain classes with `attr_reader` or Mocha mock objects |
| `TimeWithZone#to_s(:format)` raises `ArgumentError` | Use `strftime("%Y-%m-%d %H:%M:%S")` |
| `$CHILD_STATUS` is nil when `system` is stubbed | Use `$CHILD_STATUS&.exitstatus` (safe navigation) |
| Mocha stubs on `ActiveRecord::Base.connection` leak between tests | Use `mock('connection')` objects instead; call `Mocha::Mockery.instance.teardown` in teardown |
| `NameError: uninitialized constant` in tool tests | Rails autoload doesn't resolve multiple classes per file — add explicit `require_relative` in each test file |
| Prompt partial not loading | PromptLoader expects `_` prefix: `config/prompts/partials/_name.yml` |

---

## Definition of Done

A task is complete only when ALL are true:

1. `docker compose -f docker/docker-compose.yml run --rm test` → 0 failures, 0 errors
2. `docker compose -f docker/docker-compose.yml run --rm --entrypoint ruby test -cw <file>` passes for each modified `.rb` file
3. Migrations run cleanly (if applicable)
4. New code has a corresponding test mirroring the `app/` or `lib/` structure
5. `docs/MEMORY.md` updated if an architectural decision was made

---

## Escalation When Stuck

1. Re-read the relevant `CONTEXT.md` and retry
2. Check `docs/MEMORY.md` "Lições Aprendidas" section
3. Document the problem in "Decisões Pendentes" and **stop**

Never delete existing code, modify tests to force them to pass, or remove validations as a workaround.

---

## Database

SQLite3 WAL mode. Three connection pools (primary, queue, cache) all pointing to the same `storage/production.sqlite3` file. Never delete SQLite files. Use `SqliteBackupJob` / `bin/backup` for backups.

`db/queue_migrate/` and `db/cache_migrate/` are auto-managed by Solid Queue/Cache — do not edit manually.
