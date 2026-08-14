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
  GET  /health -> {"status": "ok", "scripts": [...]}  (200) ou
                  {"status": "unavailable", "unavailable_scripts": [...], "unavailable_imports": [...]} (503)
  POST /run    -> {"script": "<allowlist>", "args": [...], "timeout": <s>}
"""

import hmac
import importlib
import json
import os
import signal
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

# Imports essenciais validados uma única vez na inicialização. Cada entry
# mapeia o nome canônico do módulo Python para a allowlist de scripts que o
# consomem — usado para relacionar "import ausente" ao script impactado no
# healthcheck. Não inicia navegadores: só verifica disponibilidade do módulo.
REQUIRED_IMPORTS = {
    "nodriver": ("nodriver_fetch.py", "nodriver_instagram.py", "nodriver_twitter.py"),
    "camoufox": ("camoufox_scrape.py",),
    "curl_cffi": ("curl_impersonate.py",),
    "pypdf": (),
}

MAX_BODY_BYTES = 256 * 1024
MAX_PDF_BYTES = 10 * 1024 * 1024
MAX_PDF_PAGES = 200
MAX_PDF_CHARS = 60000
MAX_ARGS = 32
MAX_ARG_LENGTH = 4096
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT = 180
MAX_TIMEOUT = 300
MAX_CONCURRENCY = int(os.environ.get("SCRAPER_MAX_CONCURRENCY", "2"))
ACQUIRE_TIMEOUT = 30

# B2 (revisão Opus): o parse de PDF hostil tem semáforo PRÓPRIO e roda em
# subprocesso matável (run_pdf_extractor). O motivo é o mesmo que levou o /run
# a despachar scripts hostis como processo: um PDF-bomba não pode segurar um
# slot do scraping (nem a thread HTTP) sem timeout. PDF_PARSE_TIMEOUT curto —
# extração de texto de PDF nativo é rápida; o que demora é indicativo de bomba.
PDF_PARSE_TIMEOUT = int(os.environ.get("SCRAPER_PDF_TIMEOUT", "25"))
PDF_CONCURRENCY = int(os.environ.get("SCRAPER_PDF_CONCURRENCY", "1"))
_pdf_slots = threading.BoundedSemaphore(PDF_CONCURRENCY)

# Slots do SCRAPING (/run): não confundir com _pdf_slots. B2 separou os dois.
_slots = threading.BoundedSemaphore(MAX_CONCURRENCY)


class BadRequest(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


def check_startup_health():
    """Valida uma única vez na inicialização a presença dos scripts permitidos
    e dos imports essenciais (nodriver, camoufox, curl_cffi, pypdf).

    Não inicia navegadores — só verifica disponibilidade do módulo via
    importlib.util.find_spec, que não executa código do package.
    """
    import importlib.util

    unavailable_scripts = []
    for script in sorted(ALLOWED_SCRIPTS):
        path = os.path.join(SCRIPTS_DIR, script)
        if not os.path.isfile(path):
            unavailable_scripts.append(script)

    unavailable_imports = []
    for module_name, _scripts in REQUIRED_IMPORTS.items():
        if importlib.util.find_spec(module_name) is None:
            unavailable_imports.append(module_name)

    return unavailable_scripts, unavailable_imports


# Resultado da validação de startup, calculado uma única vez. O /health não
# repete a checagem em cada request — falha de import é um erro de imagem,
# constante durante o ciclo de vida do container.
_UNAVAILABLE_SCRIPTS, _UNAVAILABLE_IMPORTS = check_startup_health()


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
        # Popen + start_new_session: o timeout do subprocess.run mata só o filho
        # direto e o navegador (Firefox/Chromium) sobrevive reparentado. Com uma
        # sessão própria, o TimeoutExpired derruba o grupo inteiro via killpg.
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=SCRIPTS_DIR,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                pass
            proc.communicate()  # reap do grupo morto (evita zombie)
            return {
                "exit_code": None,
                "timed_out": True,
                "stdout": "",
                "stderr": "timeout de %ds no sidecar executando %s" % (timeout, script),
                "data": None,
            }
    finally:
        _slots.release()

    out_text = clip(stdout)
    err_text = clip(stderr)

    return {
        "exit_code": proc.returncode,
        "timed_out": False,
        "stdout": out_text,
        "stderr": err_text,
        "data": try_parse(out_text),
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


def run_pdf_extractor(tmp_path):
    """Roda extract_pdf.py como subprocesso matável (timeout + killpg).

    B2 (revisão Opus): o mesmo padrão do run_script para /run — nunca parsear
    entrada hostil na thread do ThreadingHTTPServer sem timeout. O
    server.py executa este script e aplica timeout/killpg nele.
    """
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract_pdf.py")
    if not os.path.isfile(script):
        return {"error_kind": "unavailable", "error": "extract_pdf.py ausente no sidecar"}

    command = [sys.executable, "-u", script, tmp_path, str(MAX_PDF_PAGES), str(MAX_PDF_CHARS)]
    proc = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=PDF_PARSE_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()  # reap do grupo morto (evita zombie)
        return {"error_kind": "unavailable", "error": "timeout de %ds no parse do PDF" % PDF_PARSE_TIMEOUT}

    data = clip(stdout)
    data = try_parse(data)
    if proc.returncode != 0 or not isinstance(data, dict):
        detail = clip(stderr).strip() or ("exit %s" % proc.returncode)
        # Falha de execução do script é problema de infra/parse, não do documento:
        # o consumidor decide como nomear (parse mantém "deste PDF" como defeito
        # do documento apenas quando o PRÓPRPIO script reporta error_kind parse).
        kind = "parse" if isinstance(data, dict) and data.get("error_kind") in ("parse", "invalid") else "unavailable"
        return {"error_kind": kind, "error": "erro ao ler PDF: %s" % detail}
    return data


def extract_pdf_from_bytes(raw_bytes):
    if not raw_bytes.startswith(b"%PDF-"):
        return {"error_kind": "invalid", "error": "arquivo não é um PDF válido"}

    import tempfile

    tmp_path = None
    if not _pdf_slots.acquire(timeout=ACQUIRE_TIMEOUT):
        raise BadRequest("parse de PDF saturado (%d simultâneos)" % PDF_CONCURRENCY, status=503)
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".pdf") as f:
            f.write(raw_bytes)
            tmp_path = f.name
        return run_pdf_extractor(tmp_path)
    finally:
        _pdf_slots.release()
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


class Handler(BaseHTTPRequestHandler):
    server_version = "cleitin-scraper/1.0"
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.split("?")[0] != "/health":
            self.discard_unread_body()
            return self.send_json(404, {"error": "rota inexistente"})

        # Healthcheck: responde 503 listando dependências indisponíveis quando
        # algum script permitido ou import essencial estiver ausente. A checagem
        # é feita uma única vez na importação do módulo (check_startup_health);
        # aqui apenas lê os resultados já calculados — sem I/O de disco nem
        # importação de navegador em cada request.
        if _UNAVAILABLE_SCRIPTS or _UNAVAILABLE_IMPORTS:
            self.send_json(503, {
                "status": "unavailable",
                "unavailable_scripts": _UNAVAILABLE_SCRIPTS,
                "unavailable_imports": _UNAVAILABLE_IMPORTS,
            })
        else:
            self.send_json(200, {"status": "ok", "scripts": sorted(ALLOWED_SCRIPTS)})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path not in ("/run", "/extract-pdf"):
            self.discard_unread_body()
            return self.send_json(404, {"error": "rota inexistente"})

        if not authorized(self.headers.get("Authorization")):
            self.discard_unread_body()
            return self.send_json(401, {"error": "token inválido"})

        if path == "/run":
            try:
                raw = self.read_body()
                script, args, timeout = parse_run_payload(raw)
                result = run_script(script, args, timeout)
            except BadRequest as exc:
                return self.send_json(exc.status, {"error": exc.message})
            except Exception as exc:  # noqa: BLE001 — nunca derrubar o servidor por um request
                self.log_error("erro inesperado: %s: %s", type(exc).__name__, exc)
                # Estado da conexão desconhecido (a leitura do corpo pode ter
                # falhado no meio): não reusar o keep-alive.
                self.close_connection = True
                return self.send_json(500, {"error": "%s: %s" % (type(exc).__name__, exc)})
            return self.send_json(200, result)

        if path == "/extract-pdf":
            try:
                raw = self.read_pdf_body()
                result = extract_pdf_from_bytes(raw)
            except BadRequest as exc:
                return self.send_json(exc.status, {"error": exc.message})
            except Exception as exc:  # noqa: BLE001 — nunca derrubar o servidor por um request
                self.log_error("erro inesperado em extract-pdf: %s: %s", type(exc).__name__, exc)
                self.close_connection = True
                return self.send_json(500, {"error": "%s: %s" % (type(exc).__name__, exc)})
            return self.send_json(200, result)

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            raise BadRequest("Content-Length inválido")
        if length <= 0:
            raise BadRequest("corpo vazio")
        if length > MAX_BODY_BYTES:
            self.close_connection = True
            raise BadRequest("corpo excede %d bytes" % MAX_BODY_BYTES, status=413)
        return self.rfile.read(length)

    def read_pdf_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            raise BadRequest("Content-Length inválido")
        if length <= 0:
            raise BadRequest("corpo vazio")
        if length > MAX_PDF_BYTES:
            self.close_connection = True
            raise BadRequest("corpo excede %d bytes" % MAX_PDF_BYTES, status=413)
        return self.rfile.read(length)

    def discard_unread_body(self):
        """Consome o corpo antes de um erro precoce (401/404).

        Com HTTP/1.1 keep-alive, o que sobra no socket é lido como a
        request-line da PRÓXIMA requisição (medido: 501 com o JSON do corpo na
        linha). Drena quando o tamanho é conhecido e comportável; corpo grande
        demais ou Content-Length inválido fecha a conexão.
        """
        raw = self.headers.get("Content-Length")
        if not raw:
            return
        try:
            size = int(raw)
        except ValueError:
            self.close_connection = True
            return
        if size > MAX_BODY_BYTES:
            self.close_connection = True
            return
        if size > 0:
            self.rfile.read(size)

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

    Um env_file esquecado, um typo no nome da variável ou um deploy parcial não
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


def report_startup_health():
    """Loga o resultado da validação de startup (scripts e imports)."""
    if _UNAVAILABLE_SCRIPTS or _UNAVAILABLE_IMPORTS:
        sys.stderr.write(
            "[scraper-api] WARN: dependências indisponíveis — "
            "unavailable_scripts=%s unavailable_imports=%s\n"
            % (_UNAVAILABLE_SCRIPTS, _UNAVAILABLE_IMPORTS)
        )
    else:
        sys.stderr.write("[scraper-api] startup health OK: todos os scripts e imports presentes\n")


def main():
    require_token_or_die()
    report_startup_health()

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
