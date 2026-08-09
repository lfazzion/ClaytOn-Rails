#!/usr/bin/env python3
"""Scrape a page with Camoufox and emit JSON for the Ruby bridge."""

import json
import argparse
import sys

try:
    from camoufox.sync_api import Camoufox
except ImportError:
    print(json.dumps({"error": "camoufox not installed"}), file=sys.stderr)
    sys.exit(1)

ENGINE = "camoufox"

# Teto de segurança do HTML devolvido. O `server.py` corta o stdout em 8 MB
# (MAX_OUTPUT_BYTES) e stdout cortado no meio deixa de ser JSON — o lado Ruby
# recebe `data: null` sem saber por quê. Melhor cortar aqui, declarando o corte
# em campo, do que estourar o teto do transporte em silêncio.
MAX_HTML_CHARS = 2_000_000

# Medido no sidecar em 05/08/2026, 3 rodadas alternadas contra
# google.com/search?q=ruby+performance:
#   networkidle -> 2 de 3 pararam na URL ORIGINAL com document.body.innerText
#                  VAZIO (a casca "Loading ..." de 90 KB), ou seja: o bloqueio
#                  ficava invisível e o HTML de casca passava por sucesso.
#   domcontentloaded + evento `load` -> 3 de 3 terminaram em /sorry/index com
#                  332 chars de texto, e `final_url` denuncia o bloqueio.
# A causa é que o redirect do Google é por JS, 4,0s depois do DOMContentLoaded:
# no silêncio de rede desse intervalo o networkidle dispara ANTES do redirect.
# Páginas com telemetria contínua têm o problema oposto e nunca chegam a
# networkidle, gastando o timeout inteiro. `load` é limitado dos dois lados.
NAV_TIMEOUT_MS = 45_000

# 15s de folga sobre os 4,0s medidos do redirect do Google, e ainda bem abaixo
# do orçamento de 180s do `CamoufoxService`.
LOAD_WAIT_MS = 15_000


def scrape_page(url, proxy=None):
    browser_args = {}
    if proxy:
        browser_args["proxy"] = {"server": proxy}

    # Sem `headless`, o camoufox sobe o Firefox em modo gráfico e morre com
    # "Error: no DISPLAY environment variable specified" — o sidecar não tem
    # XServer. Medido em 05/08/2026: era o que impedia o script de rodar mesmo
    # depois de a libgtk-3 entrar na imagem.
    with Camoufox(headless=True, **browser_args) as browser:
        page = browser.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)

        # Espera curta e explícita: é aqui que o redirect por JS para a página
        # de bloqueio acontece. Estourar o prazo não é erro — é uma página lenta
        # e o que já renderizou vale mais que exceção; `final_url` continua
        # dizendo onde paramos.
        try:
            page.wait_for_load_state("load", timeout=LOAD_WAIT_MS)
        except Exception:
            pass

        content = page.content() or ""
        title = page.title()
        final_url = page.url

        truncated = len(content) > MAX_HTML_CHARS

        return {
            "url": url,
            # A URL pedida é a chave de pareamento e não muda; `final_url` é o
            # que denuncia redirecionamento para página de bloqueio (medido:
            # Google manda para /sorry/index, Startpage para /sp/captcha-block).
            "final_url": final_url,
            "title": title,
            "engine": ENGINE,
            # Tamanho REAL da página, antes do teto — quem lê precisa saber o
            # que deixou de receber.
            "content_length": len(content),
            "truncated": truncated,
            "html": content[:MAX_HTML_CHARS] if content else None
        }


def main():
    parser = argparse.ArgumentParser(description="Generic scraper via Camoufox")
    parser.add_argument("url", help="URL to scrape")
    parser.add_argument("--proxy", default=None)
    parser.add_argument("--output", default=None, help="Output JSON file path")

    args = parser.parse_args()

    try:
        result = scrape_page(args.url, args.proxy)

        output_json = json.dumps(result, ensure_ascii=False)

        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(output_json)
            print(json.dumps({"status": "ok", "output_file": args.output}))
        else:
            print(output_json)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
