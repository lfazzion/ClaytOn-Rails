# Contexto: docker/

Infraestrutura de containers do projeto.

## Arquivos

| Arquivo | Descrição |
|---|---|
| `Dockerfile` | Build multi-stage da imagem Rails (build + runtime) |
| `Dockerfile.python` | Imagem do sidecar `python-scraper`: serviço HTTP de scraping com auth Bearer (`PYTHON_SCRAPER_TOKEN`) na 8080 |
| `docker-compose.yml` | Orquestração dos 3 serviços: `app`, `jobs`, `chrome` |

## Como Usar

**Rodar a partir da raiz do projeto (obrigatório):**

```bash
docker-compose -f docker/docker-compose.yml up -d
docker-compose -f docker/docker-compose.yml logs -f
docker-compose -f docker/docker-compose.yml down
```

## Arquitetura dos Serviços

```
┌─────────────┐    ┌─────────────┐    ┌──────────────────────────┐
│     app     │    │    jobs     │    │          chrome          │
│  Puma :3000 │    │ Solid Queue │    │ headless-shell:stable    │
│             │    │             │    │ :9222 (WebSocket CDP)    │
└──────┬──────┘    └──────┬──────┘    └────────┬─────────────────┘
       │                  │                     │
       └──────────────────┴──── network:internal ─────────────────┘
                          │
                   ../storage/ (bind mount)
                   └── production.sqlite3 (único arquivo, 3 conexões)
```

## Regras Críticas para IA

1. **Paths relativos à raiz**: SEMPRE rodar docker-compose da raiz com `-f docker/docker-compose.yml`
2. **Chrome Host Header Bypass**: O `FerrumConfig` injeta `Host: localhost` no GET `/json/version` para contornar Chrome 120+
3. **Shared Memory**: `shm_size: '2gb'` obrigatório no serviço `chrome` (vazamento de memória sem ele)
4. **SQLite bind mount**: `storage/` montado em `/rails/storage`. NUNCA usar Docker volume nomeado
 5. **Entrypoints**: `bin/entrypoint` (app: migrations→Puma), `bin/entrypoint-jobs` (Solid Queue supervisor)
 6. **Imagem base**: `ruby:3.4-slim`. Sem Node.js (headless zero HTML)

## Cross-References

- Scraping: `lib/scraping/CONTEXT.md` — como o Ferrum conecta ao container Chrome
- Scripts: `scripts/python/CONTEXT.md` — imagem Python separada para scraping alternativo
- DB: `db/CONTEXT.md` — SQLite no bind mount de storage/
