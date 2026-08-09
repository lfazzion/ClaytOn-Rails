# Contexto: scripts/python

Scripts Python para scraping alternativo quando Ferrum/Chrome falha ou é bloqueado.

**Estes scripts rodam DENTRO do container `python-scraper`, não no do Rails.** As
libs (nodriver, camoufox, curl_cffi, playwright) só existem na imagem
`docker/Dockerfile.python`; `python3` no container do app tem só o yt-dlp.

## Scripts Existentes

| Script | Engine | Uso |
|--------|--------|-----|
| `server.py` | stdlib | API HTTP do sidecar: `GET /health`, `POST /run` (allowlist de scripts) |
| `browser_binary.py` | — | Resolve o Chrome do playwright + `no_sandbox` para o nodriver |
| `nodriver_fetch.py` | nodriver | Fetch de URL arbitrária (fallback do `PageFetcher` em hard domains) |
| `nodriver_twitter.py` | nodriver | Scraping de Twitter/X |
| `nodriver_instagram.py` | nodriver | Scraping de Instagram |
| `camoufox_scrape.py` | camoufox | Scraping com fingerprint realista (Firefox instrumentado) |
| `curl_impersonate.py` | curl_cffi | Requisições HTTP com fingerprint TLS de browser |

## Contrato do `POST /run`

```json
{"script": "nodriver_fetch.py", "args": ["https://..."], "timeout": 180}
→ {"exit_code": 0, "timed_out": false, "stdout": "...", "stderr": "...", "data": {...}}
```

`script` é validado contra uma allowlist fixa — o corpo da requisição nunca vira
caminho de execução. O timeout autoritativo é do lado Ruby; o do sidecar é teto.

## Camoufox (`camoufox_scrape.py`)

O camoufox é um **Firefox de verdade**, não um Chromium. Isso muda três coisas, e
todas as três já quebraram este script (consertado em 05/08/2026 — antes disso ele
nunca tinha subido neste projeto):

1. **Precisa do runtime GTK.** `libmozgtk.so` linka `libgtk-3.so.0` e
   `libgdk-3.so.0`, que `playwright install --with-deps` não traz (chromium
   headless não usa GTK). Sem elas o launch morre em `XPCOMGlueLoad error ...
   Couldn't load XPCOM`. `libgtk-3-0` está no `Dockerfile.python` e é **a única**
   biblioteca externa que faltava — medido com `ldd` sobre o binário e todos os
   `.so` do browser. `libasound2`/`libdbus-glib-1-2` foram testadas e não são
   necessárias.
2. **`headless=True` é obrigatório no código.** O default do camoufox é gráfico e
   o sidecar não tem XServer: `Error: no DISPLAY environment variable specified`.
3. **O binário do Firefox não vem no `pip install`.** É baixado na primeira
   execução, e o progresso do download sai em **stdout**, quebrando o
   `JSON.parse(stdout.strip)` do `CamoufoxService`. Por isso o `Dockerfile.python`
   roda `python3 -m camoufox fetch` no build.

`Sandbox: CanCreateUserNamespace() clone() failure: EPERM` aparece no log de
launch e é **ruído, não falha**: o seccomp padrão do Docker bloqueia user
namespace não-privilegiado e o Firefox degrada para um nível de sandbox mais
fraco. Medido: com a mensagem presente, o browser sobe e navega normalmente. Não
se afrouxa o seccomp do container por causa dela — é justamente o container que
roda contra sites hostis.

**O braço com `--proxy` está incompleto, e o próprio camoufox avisa.** Medido em
05/08/2026 em container descartável: com `--proxy`, o launch imprime
`LeakWarning: When using a proxy, it is heavily recommended that you pass
geoip=True`. Sem `geoip`, fuso horário, idioma e coordenadas do fingerprint
continuam os do datacenter enquanto o IP é o do proxy — a inconsistência que o
engine existe para não ter (é o mesmo argumento que mantém os 932 MB de fontes na
imagem). E `geoip=True` **não funciona nesta imagem**: levanta
`NotInstalledGeoIPExtra: Please install the geoip extra ... pip install
camoufox[geoip]`. Enquanto a extra não entrar no `Dockerfile.python`, usar proxy
aqui é fingerprint inconsistente por construção. Hoje é dívida, não incidente:
`CamoufoxService.scrape_url` ainda não tem chamador de produção.

### Navegação: nunca `networkidle`

`wait_until="networkidle"` **esconde bloqueio**. Medido em 3 rodadas alternadas
contra `google.com/search`: o networkidle parou 2 de 3 vezes na URL original com
`document.body.innerText` vazio — 90 KB de casca `Loading ...` passando por
sucesso —, porque o redirect do Google é por JS 4,0s depois do DOMContentLoaded e
o networkidle dispara no silêncio de rede desse intervalo. Em páginas com
telemetria contínua o problema é o oposto: nunca chega a idle e gasta o timeout
inteiro. O padrão é `domcontentloaded` + `wait_for_load_state("load")` limitado,
que caiu em `/sorry/index` nas 3 rodadas.

### Contrato de saída

```json
{"url": "<pedida, chave de pareamento>", "final_url": "<page.url>",
 "title": "...", "engine": "camoufox",
 "content_length": <tamanho REAL>, "truncated": false, "html": "<HTML íntegro>"}
```

`final_url` é o campo que **declara a degradação** (padrão `engine`/`rendered` do
MEMORY.md): é ele que denuncia o redirect para página de bloqueio — Google
`/sorry/index`, Startpage `/sp/captcha-block`. `title` não serve para isso: na
página de bloqueio do Google ele vem com a URL original dentro. O `html` vai
inteiro (teto de 2 M chars, abaixo dos 8 MB que o `server.py` corta), e o corte,
se houver, é **declarado** em `truncated` com `content_length` sempre real.

## Ambiente e Autenticação

O container carrega `docker/.env.sidecar`, **nunca** o `../.env`: ele roda engines
de evasão contra sites hostis e não pode guardar `SECRET_KEY_BASE`,
`DISCORD_BOT_TOKEN` nem as chaves de LLM. `PYTHON_SCRAPER_TOKEN` tem que ser o
mesmo valor dos dois lados — **sem ele o `server.py` recusa subir** (exit 1 com
log `FATAL`). Fail-closed é intencional: auth desligada em silêncio é pior que
deploy que quebra.

Provas: `scripts/proofs/sidecar_env_proof.sh` (isolamento de segredo, recusa de
boot sem token, e 401/400 no `/run`).

## Regras Críticas para IA

0. **Nunca `Open3`/`system` a partir do Rails**: os módulos não estão no container
   do app. Todo script novo entra na `ALLOWED_SCRIPTS` de `server.py` e é chamado
   via `ScrapingServices::SidecarClient`.
1. **Execução via Ruby bridge**: Nunca chamar `python` diretamente. Usar `PythonBridge::NodriverRunner` ou `PythonBridge::CamoufoxService` em `lib/scraping/python_bridge/`
2. **Saída JSON**: Todo script deve retornar JSON no stdout (parseável pelo Ruby)
3. **Erros em stderr**: Logs de erro vão para stderr, nunca misturar com JSON de saída
4. **Variáveis de ambiente**: URLs e configs vêm via env vars (não hardcoded)
5. **Requirements**: `requirements.txt` na raiz do projeto. Instalar com `pip install -r requirements.txt` no container Python
 6. **Timeout**: Scripts devem ter timeout implícito (o Ruby bridge mata o processo após timeout)

## Cross-References

- Scraping: `lib/scraping/CONTEXT.md` — Ruby bridge que executa estes scripts
- Docker: `docker/CONTEXT.md` — `Dockerfile.python` que instala as dependências
