#!/usr/bin/env python3
# PageFetchTool Python fallback: busca URL arbitrária via nodriver (stealth).
# Invocado por `ScrapingServices::NodriverRunner.fetch_page` quando o host
# está em `config/hard_domains.yml`. Saída: JSON em stdout.

import asyncio
import json
import argparse
import sys
import time
import os
import ipaddress

try:
    import nodriver as uc
except ImportError:
    print(json.dumps({"error": "nodriver not installed"}), file=sys.stderr)
    sys.exit(1)

import browser_binary

# Timeout e polling para a espera adaptativa de conteúdo.
READY_TIMEOUT = 15.0
READY_POLL = 0.2
# Estabilização do tamanho do body.innerText: exige pelo menos esta
# duração de inércia antes de considerar o conteúdo pronto.
STABILITY_WINDOW = 0.6
STABILITY_POLL = 0.15


def _is_private_ip(ip):
    """Retorna True se o IP é privado/reservado (RFC1918, loopback, link-local)."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_reserved
        or addr.is_multicast
    )


async def wait_for_content_ready(page, timeout=READY_TIMEOUT):
    """
    Espera o documento ficar pronto (readyState 'interactive'/'complete') e
    depois exige estabilização curta do tamanho de `document.body.innerText`.

    Polling pequeno; timeout explícito. Ao expirar, retorna o conteúdo
    disponível sem levantar exceção.
    """
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    last_len = None
    last_change = loop.time()
    last_ready = None

    while True:
        now = loop.time()
        if now >= deadline:
            break

        try:
            ready = await page.evaluate("document.readyState")
        except Exception:
            ready = None
        try:
            body_len = await page.evaluate(
                "document.body ? document.body.innerText.length : 0"
            )
            if not isinstance(body_len, (int, float)):
                body_len = len(str(body_len))
        except Exception:
            body_len = 0

        last_ready = ready
        if body_len != last_len:
            last_len = body_len
            last_change = now
        # readyState 'complete' ou 'interactive' + inércia: sai antes do timeout.
        if ready in ("complete", "interactive") and (now - last_change) >= STABILITY_WINDOW and body_len > 0:
            break

        try:
            await asyncio.sleep(READY_POLL)
        except asyncio.CancelledError:
            break

    return last_ready, last_len


async def fetch(url, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    document_ip = None
    try:
        # Registra o listener de Network.responseReceived ANTES da navegação
        # no tab principal. Assim capturamos o remoteIPAddress do documento
        # principal durante a navegação inicial — sem precisar de reload
        # (que duplicaria a requisição HTTP e resetaria o DOM). Isso reproduz
        # a estratégia de RebindingGuard.capture_document_remote_ip em Ruby:
        # assinar antes de navegar para não perder o evento do documento.
        ip_holder = {"value": None}
        captured = asyncio.Event()

        def on_response_received(params, *args, **kwargs):
            if params is None:
                return
            if params.type_ == uc.cdp.network.ResourceType.DOCUMENT:
                ip = params.response.remote_ip_address
                if not ip:
                    return
                # Contrato (laguna-fix): "IP bloqueado observado não pode ser
                # perdido". Um IP privado já capturado NÃO pode ser sobrescrito
                # por um documento público posterior — caso contrário o IP
                # bloqueado deixa de ser detectado e a validação Ruby falha em
                # fail-open. Só atualizamos se ainda não tivermos um IP, ou se o
                # novo também for privado (mantém o mais recente entre privados).
                existing = ip_holder["value"]
                if existing is None:
                    ip_holder["value"] = ip
                    captured.set()
                elif _is_private_ip(existing) and not _is_private_ip(ip):
                    # Preserva o IP privado/bloqueado já observado.
                    pass
                else:
                    ip_holder["value"] = ip
                    captured.set()

        page = browser.main_tab
        # ACHADO 1 (P1 do sol): sem Network.enable o CDP não garante a entrega
        # dos eventos ResponseReceived. Habilitamos a rede ANTES de navegar.
        await page.send(uc.cdp.network.enable())
        page.add_handler(uc.cdp.network.ResponseReceived, on_response_received)

        try:
            # browser.get navega o primeiro tab usando cdp.page.navigate;
            # o listener já está ativo e captura o evento do documento.
            page = await browser.get(url)
            await wait_for_content_ready(page)

            # Se o evento já chegou, document_ip está em ip_holder["value"].
            # Se não chegou em 2s extras, desistimos (fail-open no Ruby).
            try:
                await asyncio.wait_for(captured.wait(), timeout=2)
            except asyncio.TimeoutError:
                pass
            document_ip = ip_holder["value"]
        finally:
            page.remove_handler(
                uc.cdp.network.ResponseReceived, on_response_received
            )

        html = await page.get_content()
        title = await page.evaluate("document.title")
        body_text = await page.evaluate(
            "document.body ? document.body.innerText.substring(0, 20000) : ''"
        )
        current_url = await page.evaluate("window.location.href")

        return {
            "title": title or "",
            "url": current_url or url,
            "content": body_text or "",
            "html_bytes": len(html.encode("utf-8")) if html else 0,
            "document_ip": document_ip or "",
        }
    finally:
        try:
            await browser.stop()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--proxy", default=None)
    args = parser.parse_args()

    try:
        result = asyncio.run(fetch(args.url, proxy=args.proxy))
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
