# Contexto: docker/

Infraestrutura de containers do projeto.

## Arquivos

| Arquivo | Descrição |
|---|---|
| `Dockerfile` | Build multi-stage da imagem Rails (build + runtime) |
| `Dockerfile.python` | Imagem do sidecar `python-scraper`; CMD roda `scripts/python/server.py` (API HTTP — o `server.py` e o CMD novo chegam junto do PR de scraping) |
| `docker-compose.yml` | Orquestração de `app`, `jobs`, `discord-bot`, `chrome`, `python-scraper`, `searxng` |

### `Dockerfile.python`: dois passos que existem só pelo camoufox

O camoufox é Firefox, não Chromium — `playwright install chromium --with-deps`
não cobre as duas necessidades abaixo, e sem elas o engine nunca sobe.
(As duas linhas abaixo descrevem o `Dockerfile.python` que chega junto do PR de scraping; o arquivo atual ainda não as tem.)

- **`libgtk-3-0` no `apt-get`** — `libmozgtk.so` linka `libgtk-3.so.0` e
  `libgdk-3.so.0`; sem elas, `Couldn't load XPCOM`. Medido com `ldd` em
  05/08/2026: são as **únicas** externas ausentes na imagem.
- **`RUN python3 -m camoufox fetch`** — o `pip install camoufox` traz só a
  biblioteca. Sem o fetch no build, a primeira chamada de cada container novo
  falha (`official/stable is not installed`) e o progresso do download vai para
  **stdout**, quebrando o JSON que o `CamoufoxService` parseia.
  Custo medido: **1,2 GB** de cache (imagem em 4,84 GB), 932 MB só de pacotes de
  fonte de macOS/Windows. Essas fontes são o que faz a medição de fonte e o
  canvas baterem com o SO spoofado — podá-las troca peso por fingerprint
  inconsistente.

Detalhes e o contrato de saída do script: `scripts/python/CONTEXT.md`.

## Publicação de Portas

`app` publica em `127.0.0.1:3000` — `/internal/extract` (rota que chega junto
do PR de fetcher/mcp) recebe URLs de conteúdo não-confiável e não pode ficar em
`0.0.0.0` com o firewall do host como única camada. `searxng` idem (`127.0.0.1:8888`). O sidecar `python-scraper` não publica
porta nenhuma: só é alcançável pela rede `internal`.

**`chrome` NÃO publica porta nenhuma**, e isto é verificado, não prometido:
`docker_compose_test.rb` afirma `assert_nil chrome["ports"]` e exige
`networks == ["browser"]`. O CDP não tem autenticação e o Chromium marcou o
problema como WontFix — quem alcança a 9222 dirige o navegador e lê os cookies,
o que com perfil persistente e logado vale uma conta inteira. Por isso o serviço
vive numa rede própria, alcançável só por quem o dirige; nem o `python-scraper`
resolve o nome `chrome`.

> Este parágrafo dizia o contrário até 05/08/2026 — descrevia como "dívida
> conhecida" uma porta aberta em `0.0.0.0` e afirmava que o teste isentava o
> serviço. As duas metades eram falsas: o isolamento foi feito em 04/08 e o teste
> sempre reprovou porta publicada. Documento que inventa uma vulnerabilidade custa
> tão caro quanto o que esconde uma — manda auditar o que está certo e ensina a
> desconfiar do teste que está te protegendo.

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
