#!/usr/bin/env python3
"""API HTTP mínima do sidecar python-scraper.

Substitui o `http.server` de diretório vazio que rodava como CMD. O Rails
(app/jobs) não tem nodriver/camoufox/curl_cffi instalados — só este container
tem. As pontes Ruby em lib/scraping/python_bridge/ falam HTTP com este processo
em vez de rodar `Open3.capture3` localmente (onde os módulos não existem).

Contrato preservado do Open3:
  stdout JSON  -> campo `data` (já parseado) e `stdout` (cru)
  stderr       -> campo `stderr`
  exit code    -> campo `exit_code`
O timeout autoritativo é do lado Ruby; o daqui é só um teto de segurança.

Rotas:
  GET  /health -> {"status": "ok", "scripts": [...]}
  POST /run    -> {"script": "<allowlist>", "args": [...], "timeout": <s>}

Stdlib apenas — sem framework, sem dependência nova na imagem.
"""

import hmac
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPTS_DIR = os.environ.get("SCRAPER_SCRIPTS_DIR", "/app/scripts")
TOKEN = os.environ.get("PYTHON_SCRAPER_TOKEN", "").strip()

# Allowlist fixa: /run nunca executa um caminho vindo do corpo da requisição.
ALLOWED_SCRIPTS = frozenset(
    [
        "nodriver_fetch.py",
        "nodriver_instagram.py",
        "nodriver_twitter.py",
        "camoufox_scrape.py",
        "curl_impersonate.py",
    ]
)

MAX_BODY_BYTES = 256 * 1024
MAX_ARGS = 32
MAX_ARG_LENGTH = 4096
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT = 180
MAX_TIMEOUT = 300
MAX_CONCURRENCY = int(os.environ.get("SCRAPER_MAX_CONCURRENCY", "2"))
ACQUIRE_TIMEOUT = 30

_slots = threading.BoundedSemaphore(MAX_CONCURRENCY)


class BadRequest(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


def authorized(header_value):
    # Fail-closed: sem token não existe requisição autorizada. O processo nem
    # sobe nesse estado (ver require_token_or_die), mas a função não depende
    # disso — degradar para "aceita tudo" é justamente o modo de falha a evitar.
    if not TOKEN:
        return False
    prefix = "Bearer "
    if not header_value or not header_value.startswith(prefix):
        return False
    return hmac.compare_digest(header_value[len(prefix):], TOKEN)


def parse_run_payload(raw):
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise BadRequest("corpo não é JSON válido: %s" % exc)

    if not isinstance(payload, dict):
        raise BadRequest("corpo deve ser um objeto JSON")

    script = payload.get("script")
    if script not in ALLOWED_SCRIPTS:
        raise BadRequest("script não permitido: %r" % (script,))

    args = payload.get("args", [])
    if not isinstance(args, list):
        raise BadRequest("args deve ser uma lista")
    if len(args) > MAX_ARGS:
        raise BadRequest("máximo de %d args (recebidos %d)" % (MAX_ARGS, len(args)))
    for arg in args:
        if not isinstance(arg, str):
            raise BadRequest("todo arg deve ser string")
        if len(arg) > MAX_ARG_LENGTH:
            raise BadRequest("arg excede %d chars" % MAX_ARG_LENGTH)

    timeout = payload.get("timeout", DEFAULT_TIMEOUT)
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool):
        raise BadRequest("timeout deve ser numérico")
    timeout = max(1, min(int(timeout), MAX_TIMEOUT))

    return script, args, timeout


def run_script(script, args, timeout):
    path = os.path.join(SCRIPTS_DIR, script)
    if not os.path.isfile(path):
        raise BadRequest("script ausente no sidecar: %s" % script, status=500)

    command = [sys.executable, "-u", path] + args

    if not _slots.acquire(timeout=ACQUIRE_TIMEOUT):
        raise BadRequest("sidecar saturado (%d execuções simultâneas)" % MAX_CONCURRENCY, status=503)
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            timeout=timeout,
            cwd=SCRIPTS_DIR,
        )
    except subprocess.TimeoutExpired:
        return {
            "exit_code": None,
            "timed_out": True,
            "stdout": "",
            "stderr": "timeout de %ds no sidecar executando %s" % (timeout, script),
            "data": None,
        }
    finally:
        _slots.release()

    stdout = clip(completed.stdout)
    stderr = clip(completed.stderr)

    return {
        "exit_code": completed.returncode,
        "timed_out": False,
        "stdout": stdout,
        "stderr": stderr,
        "data": try_parse(stdout),
    }


def clip(raw_bytes):
    text = (raw_bytes or b"")[:MAX_OUTPUT_BYTES]
    return text.decode("utf-8", errors="replace")


def try_parse(stdout):
    stripped = stdout.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except ValueError:
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "cleitin-scraper/1.0"
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.split("?")[0] != "/health":
            return self.send_json(404, {"error": "rota inexistente"})
        self.send_json(200, {"status": "ok", "scripts": sorted(ALLOWED_SCRIPTS)})

    def do_POST(self):
        if self.path.split("?")[0] != "/run":
            return self.send_json(404, {"error": "rota inexistente"})

        if not authorized(self.headers.get("Authorization")):
            return self.send_json(401, {"error": "token inválido"})

        try:
            raw = self.read_body()
            script, args, timeout = parse_run_payload(raw)
            result = run_script(script, args, timeout)
        except BadRequest as exc:
            return self.send_json(exc.status, {"error": exc.message})
        except Exception as exc:  # noqa: BLE001 — nunca derrubar o servidor por um request
            self.log_error("erro inesperado: %s: %s", type(exc).__name__, exc)
            return self.send_json(500, {"error": "%s: %s" % (type(exc).__name__, exc)})

        self.send_json(200, result)

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise BadRequest("Content-Length inválido")
        if length <= 0:
            raise BadRequest("corpo vazio")
        if length > MAX_BODY_BYTES:
            raise BadRequest("corpo excede %d bytes" % MAX_BODY_BYTES, status=413)
        return self.rfile.read(length)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *fmt_args):
        sys.stderr.write("[scraper-api] %s\n" % (fmt % fmt_args))


def require_token_or_die():
    """Recusa subir sem token, em vez de degradar permissivo em runtime.

    Um env_file esquecido, um typo no nome da variável ou um deploy parcial não
    podem virar "autenticação desligada em silêncio": este container roda
    engines de evasão contra sites hostis e fica na mesma rede que o chrome
    (CDP sem senha) e o searxng. Falha barulhenta no deploy > auth ausente.
    """
    if TOKEN:
        return

    sys.stderr.write(
        "[scraper-api] FATAL: PYTHON_SCRAPER_TOKEN ausente ou vazio.\n"
        "[scraper-api] O sidecar não sobe sem autenticação. Defina a variável em\n"
        "[scraper-api] docker/.env.sidecar (mesmo valor de PYTHON_SCRAPER_TOKEN\n"
        "[scraper-api] no ../.env, que o lado Rails usa) e suba de novo.\n"
    )
    sys.exit(1)


def main():
    require_token_or_die()

    host = os.environ.get("SCRAPER_BIND", "0.0.0.0")
    port = int(os.environ.get("SCRAPER_PORT", "8080"))
    server = ThreadingHTTPServer((host, port), Handler)
    sys.stderr.write(
        "[scraper-api] escutando em %s:%d (auth on, concorrência %d)\n"
        % (host, port, MAX_CONCURRENCY)
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
