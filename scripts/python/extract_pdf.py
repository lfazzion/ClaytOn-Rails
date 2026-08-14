#!/usr/bin/env python3
"""Extrai texto de um PDF via pypdf, como subprocesso do server.py.

Por que isto existe (B2, revisão Opus): o parse de PDF hostil NÃO pode rodar
na thread do ThreadingHTTPServer sem timeout — o mesmo motivo pelo qual o /run
despacha scripts hostis como processo (Popen + start_new_session + killpg). O
server.py executa este script e aplica timeout/killpg nele.

Uso: extract_pdf.py <caminho_do_pdf> <max_pages> <max_chars>

Saída: um único JSON no stdout:
  {"text": "...", "chars": N, "pages": N, "truncated": bool}
ou em erro: {"error_kind": "parse"|"invalid", "error": "..."}
Status: 0 mesmo com {"error_kind": ...} (erro de documento não é falha de
execução do script); != 0 só para uso inválido dos args.
"""

import json
import logging
import resource
import sys

PDF_HEADER = b"%PDF-"

# Logger para stderr: erros inesperados do parser em PDFs não confiáveis
# precisam de traceback completo para diagnosticar defeitos e regressões do
# pypdf. O stdout só carrega o JSON sanitizado (contrato com server.py), mas o
# traceback vai para stderr para não quebrar o parser de saída JSON.
_log = logging.getLogger("extract_pdf")
_log.setLevel(logging.DEBUG)
if not _log.handlers:
    _handler = logging.StreamHandler(sys.stderr)
    _handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s [%(process)d] %(message)s"))
    _log.addHandler(_handler)

# B2-memória (2ª rodada de revisão): teto de memória do processo de parse. Um
# PDF-bomba (stream comprimido que expande para GBs dentro de extract_text)
# não pode derrubar o container por OOM — o processo morre com MemoryError,
# que o except Exception abaixo converte em JSON de erro.
_RLIMIT_AS_BYTES = 512 * 1024 * 1024  # 512MB
try:
    resource.setrlimit(resource.RLIMIT_AS, (_RLIMIT_AS_BYTES, _RLIMIT_AS_BYTES))
except (ValueError, OSError):
    pass  # plataforma sem RLIMIT_AS (não é o caso do Linux do sidecar)

HINT = (
    "uso: extract_pdf.py <pdf> <max_pages> <max_chars>"
)


def _err_doc(message):
    print(json.dumps({"error_kind": "parse", "error": message}))


def main():
    if len(sys.argv) != 4:
        _err_doc(HINT)
        return 1

    _path, max_pages_s, max_chars_s = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        max_pages = max(1, int(max_pages_s))
        max_chars = max(1, int(max_chars_s))
    except (TypeError, ValueError):
        _err_doc("max_pages/max_chars inválidos")
        return 1

    try:
        with open(sys.argv[1], "rb") as handle:
            head = handle.read(len(PDF_HEADER))
        if not head.startswith(PDF_HEADER):
            print(json.dumps({"error_kind": "invalid", "error": "arquivo não é um PDF válido"}))
            return 0
    except OSError as exc:
        _err_doc("erro ao ler PDF: %s" % exc)
        return 1

    try:
        import pypdf

        reader = pypdf.PdfReader(sys.argv[1])
        total_pages = len(reader.pages)
        pages_to_read = min(total_pages, max_pages)
        chunks = []
        total_chars = 0
        truncated = False

        for i in range(pages_to_read):
            page_text = reader.pages[i].extract_text() or ""
            chunks.append(page_text)
            total_chars += len(page_text)
            if total_chars >= max_chars:
                truncated = True
                break

        text = "\n".join(chunks)
        if len(text) > max_chars:
            text = text[:max_chars]
            truncated = True

        # B3 (revisão Opus): cortar por páginas TAMBÉM é truncamento — o
        # consumidor precisa saber que o documento foi lido pela metade, senão
        # o bot responde com confiança sobre um documento que viu parcialmente.
        total_pages_truncated = total_pages > max_pages
        print(json.dumps({
            "text": text,
            "chars": len(text),
            "pages": total_pages,
            "truncated": truncated or total_pages_truncated,
        }))
        return 0
    except Exception as exc:  # noqa: BLE001 — erro vira JSON, nunca derruba o script
        # O traceback completo vai para stderr (logger.exception) para
        # diagnosticar defeitos e regressões do pypdf em PDFs não confiáveis.
        # O stdout recebe apenas o JSON sanitizado — o server.py lê stdout como
        # contrato e stderr cai no log do sidecar via clip(stderr).
        _log.exception("erro inesperado ao parsear PDF")
        _err_doc("erro ao ler PDF: %s" % exc)
        return 0


if __name__ == "__main__":
    sys.exit(main())
