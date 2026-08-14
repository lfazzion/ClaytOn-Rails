#!/usr/bin/env python3
# PageFetchTool Python fallback: busca URL arbitrária via nodriver (stealth).
# Invocado por `ScrapingServices::NodriverRunner.fetch_page` quando o host
# está em `config/hard_domains.yml`. Saída: JSON em stdout.

import asyncio
import json
import argparse
import sys
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


def _is_private_ip(ip):
    """Retorna True se o IP NAO e global/roteavel publicamente.

    O criterio e `addr.is_global is False`, que cobre TODAS as faixas
    nao-globais de uma vez — inclusive CGNAT (100.64.0.0/10, RFC6598), que o
    `ipaddress.is_private` NAO marca como privado mas que tambem nao e um IP
    publico valido. Tratar nao-global como bloqueado fecha o bypass SSRF em que
    uma sequencia 100.64.0.1 -> 1.2.3.4 sobrescrevia o IP bloqueado e a
    validacao Ruby (que confere so o final observado) deixava passar.
    """
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return not addr.is_global


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
            # Achado C: o cancelamento do chamador (asyncio.run propaga
            # CancelledError) NAO pode ser engolido aqui. Se o chamador
            # cancela, relancamos para honrar o cancelamento — caso
            # contrario o script terminaria como sucesso e romperia a
            # semantica de cancelamento do chamador.
            raise

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
            # Achado B: ignorar documentos de subframes/iframes. O evento
            # ResponseReceived traz o frame_id do emissor; so o DOCUMENT do
            # frame PRINCIPAL interessa ao cheque de rebinding — um iframe que
            # carrega de IP privado nao representa o documento que o Ruby va
            # validar, e captura-lo geraria bloqueio falso.
            frame_id = getattr(params, "frame_id", None)
            if frame_id is not None and main_frame_id is not None and frame_id != main_frame_id:
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

        # Rodada 3 (sol 13/08): Page.enable habilita as notificações do domínio
        # Page — sem ele, o Page.frameNavigated nunca é entregue e
        # main_frame_id fica None, desativando o filtro de subframe (o IP de um
        # iframe privado poderia ser atribuído ao documento principal).
        await page.send(uc.cdp.page.enable())

        # Captura o frame_id da navegacao principal para que o listener so
        # aceite documentos desse frame (ignora subframes/iframes — Achado B).
        main_frame_id = None

        def on_frame_navigated(params, *args, **kwargs):
            nonlocal main_frame_id
            # API real (nodriver 0.50.3): FrameNavigated.params.frame é um
            # objeto Frame com `id_` e `parent_id` (não campos no params —
            # verificado 13/08). Frame principal = parent_id nulo.
            frame = getattr(params, "frame", None)
            if frame is not None and getattr(frame, "parent_id", None) is None:
                main_frame_id = getattr(frame, "id_", None)

        page.add_handler(uc.cdp.page.FrameNavigated, on_frame_navigated)

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
            page.remove_handler(
                uc.cdp.page.FrameNavigated, on_frame_navigated
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
            browser.stop()
        except asyncio.CancelledError:
            # CancelledError ja foi relancado no polling; se chegou aqui durante
            # o teardown, deixamos propagar (nao engolimos cancelamento).
            raise
        except Exception as exc:
            # Achado G (rodada 2) + rodada 3 (sol 13/08): o `except Exception:
            # pass` anterior engolia QUALQUER erro de limpeza. Suprimir SÓ a
            # exceção operacional CONCRETA de encerramento que o nodriver/CDP
            # levanta quando o browser já foi fechado (TargetClosedError).
            # Nada de heurística por substring ("closed" na mensagem): um
            # RuntimeError("closed state invariant broken") é erro de
            # programação e deve propagar (falso positivo apontado pelo sol).
            if type(exc).__name__ == "TargetClosedError" or "cdp.target" in type(exc).__module__:
                pass
            else:
                raise


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
