# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# Exercita `scripts/python/camoufox_scrape.py` DE VERDADE, com um módulo
# `camoufox` falso no PYTHONPATH.
#
# Por que isto existe: `test/scraping/camoufox_service_test.rb` dubla o
# `SidecarClient` e por isso passa igualzinho com o script quebrado — foi assim
# que o engine ficou meses sem subir (sem `headless`, com `networkidle`, e
# devolvendo `html_preview` de 5000 chars) sem nenhum teste ficar vermelho.
# Aqui o script roda como processo, e o dublê grava o que o script pediu ao
# navegador: dá para reprovar cada uma das correções de 05/08/2026 sozinha.
class CamoufoxScrapeScriptTest < ActiveSupport::TestCase
  # O override existe para reprovar esta suíte contra a versão ANTIGA do script
  # (`git show HEAD:scripts/python/camoufox_scrape.py > tmp/old.py`) sem tocar no
  # arquivo que o container do sidecar monta em produção.
  SCRIPT_PATH = ENV.fetch("CAMOUFOX_SCRIPT_PATH", Rails.root.join("scripts/python/camoufox_scrape.py").to_s)

  REQUESTED_URL = "https://www.google.com/search?q=ruby+performance"
  # Diferente da pedida de propósito: é o único jeito de provar que `final_url`
  # vem de `page.url` (o redirect para a página de bloqueio) e não de um eco da
  # URL pedida.
  FINAL_URL = "https://www.google.com/sorry/index?continue=https://www.google.com/search"

  # Dublê do `camoufox.sync_api`. Grava launch/goto/wait_for_load_state num JSON
  # lateral e devolve conteúdo de tamanho controlado.
  FAKE_SYNC_API = <<~PYTHON
    import json
    import os

    CALLS_PATH = os.environ["FAKE_CAMOUFOX_CALLS"]
    CONTENT_LEN = int(os.environ.get("FAKE_CONTENT_LEN", "6000"))
    FINAL_URL = os.environ.get("FAKE_FINAL_URL", "https://final.example/")
    LOAD_RAISES = os.environ.get("FAKE_LOAD_RAISES") == "1"
    LOAD_RAISES_RUNTIME = os.environ.get("FAKE_LOAD_RAISES_RUNTIME") == "1"

    _calls = {"launch": None, "goto": None, "load_state": None}


    def _dump():
        with open(CALLS_PATH, "w", encoding="utf-8") as handle:
            json.dump(_calls, handle)


    class _Page:
        url = FINAL_URL

        def goto(self, url, **kwargs):
            _calls["goto"] = {"url": url, "kwargs": {k: str(v) for k, v in kwargs.items()}}
            _dump()

        def wait_for_load_state(self, state="load", **kwargs):
            _calls["load_state"] = {"state": state, "kwargs": {k: str(v) for k, v in kwargs.items()}}
            _dump()
            if LOAD_RAISES_RUNTIME:
                raise RuntimeError("algo quebrou durante o scrape")
            if LOAD_RAISES:
                try:
                    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
                    raise PlaywrightTimeoutError("Timeout 15000ms exceeded waiting for load")
                except ImportError:
                    raise TimeoutError("Timeout 15000ms exceeded waiting for load")

        def content(self):
            return "<html>" + ("a" * CONTENT_LEN) + "</html>"

        def title(self):
            return "Titulo do dublê"

        # Implementado só para que a versão ANTIGA do script (que avaliava JS
        # para jogar o resultado fora) chegue até o `return` e seja reprovada
        # pelo CONTRATO, não por AttributeError no dublê.
        def evaluate(self, _expression):
            return self.title()


    class _Browser:
        def new_page(self):
            return _Page()


    class Camoufox:
        def __init__(self, **kwargs):
            _calls["launch"] = {k: str(v) for k, v in kwargs.items()}
            _dump()

        def __enter__(self):
            return _Browser()

        def __exit__(self, *_args):
            return False
  PYTHON

  # Tamanho real do HTML que o dublê devolve para um dado FAKE_CONTENT_LEN.
  WRAPPER_CHARS = "<html>".length + "</html>".length

  class Result
    attr_reader :stdout, :stderr, :status, :calls

    def initialize(stdout, stderr, status, calls)
      @stdout = stdout
      @stderr = stderr
      @status = status
      @calls = calls
    end

    def json
      @json ||= JSON.parse(stdout)
    end
  end

  def run_script(url: REQUESTED_URL, content_length: 6_000, final_url: FINAL_URL, load_raises: false, load_raises_runtime: false, args: [])
    Dir.mktmpdir do |dir|
      package = File.join(dir, "camoufox")
      FileUtils.mkdir_p(package)
      File.write(File.join(package, "__init__.py"), "")
      File.write(File.join(package, "sync_api.py"), FAKE_SYNC_API)

      playwright_pkg = File.join(dir, "playwright")
      FileUtils.mkdir_p(File.join(playwright_pkg, "sync_api"))
      File.write(File.join(playwright_pkg, "__init__.py"), "")
      File.write(File.join(playwright_pkg, "sync_api", "__init__.py"), "class TimeoutError(Exception): pass\n")

      calls_path = File.join(dir, "calls.json")
      env = {
        "PYTHONPATH" => dir,
        "FAKE_CAMOUFOX_CALLS" => calls_path,
        "FAKE_CONTENT_LEN" => content_length.to_s,
        "FAKE_FINAL_URL" => final_url,
        "FAKE_LOAD_RAISES" => load_raises ? "1" : "0",
        "FAKE_LOAD_RAISES_RUNTIME" => load_raises_runtime ? "1" : "0"
      }

      stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, url, *args)
      calls = File.exist?(calls_path) ? JSON.parse(File.read(calls_path)) : {}

      Result.new(stdout, stderr, status, calls)
    end
  end

  def assert_ok(result)
    assert_predicate result.status, :success?, "script saiu #{result.status.exitstatus}: #{result.stderr}"
    assert_nothing_raised { result.json }
    result
  end

  test "sobe o navegador em headless" do
    # Sem isto o Firefox do camoufox tenta modo gráfico e morre em
    # "no DISPLAY environment variable specified" — o sidecar não tem XServer.
    result = assert_ok(run_script)

    assert_equal "True", result.calls.dig("launch", "headless"),
                 "launch sem headless=True: #{result.calls['launch'].inspect}"
  end

  test "navega por domcontentloaded, nunca por networkidle" do
    # `networkidle` dispara no silêncio de rede ANTES do redirect por JS para a
    # página de bloqueio: devolve a casca com body vazio e cara de sucesso.
    result = assert_ok(run_script)
    goto = result.calls["goto"]

    assert_equal REQUESTED_URL, goto["url"]
    assert_equal "domcontentloaded", goto.dig("kwargs", "wait_until")
    assert_operator goto.dig("kwargs", "timeout").to_i, :<=, 45_000,
                    "timeout de navegação acima do orçamento de 180s do CamoufoxService"
  end

  test "espera o evento load com teto explícito" do
    # É nesta janela que o redirect por JS para /sorry acontece (medido em 4,0s
    # no Google). Sem a espera, `final_url` ainda traz a URL original.
    result = assert_ok(run_script)
    load_state = result.calls["load_state"]

    assert load_state, "o script não esperou pelo evento load"
    assert_equal "load", load_state["state"]
    assert_operator load_state.dig("kwargs", "timeout").to_i, :<=, 15_000,
                    "espera de load sem teto curto come o orçamento do serviço"
    assert_operator load_state.dig("kwargs", "timeout").to_i, :>, 0,
                    "espera de load sem timeout pode travar a chamada inteira"
  end

  test "página lenta: timeout do Playwright é tolerado, não vira exceção" do
    # PlaywrightTimeoutError (TimeoutError) é a única exceção suprimida; a
    # página lenta ainda entrega o conteúdo já renderizado.
    result = assert_ok(run_script(load_raises: true))

    assert_equal 6_000 + WRAPPER_CHARS, result.json["content_length"]
    assert_equal FINAL_URL, result.json["final_url"]
  end

  test "RuntimeError durante wait_for_load_state vira erro de saída não-zero" do
    # RuntimeError NÃO é PlaywrightTimeoutError — deve chegar ao handler
    # principal que escreve erro e sai com status não zero.
    result = run_script(load_raises_runtime: true)

    assert_not result.status.success?,
               "RuntimeError deveria fazer o script sair com erro, mas saiu: #{result.stderr}"
    assert_match(/RuntimeError|algo quebrou/i, result.stderr + result.stdout)
  end

  test "final_url vem do navegador, não da URL pedida" do
    # O `title` da página de bloqueio do Google traz a URL original dentro e
    # mente; `final_url` é o único campo que denuncia o redirect.
    result = assert_ok(run_script)

    assert_equal REQUESTED_URL, result.json["url"]
    assert_equal FINAL_URL, result.json["final_url"]
    assert_not_equal result.json["url"], result.json["final_url"]
    assert_equal "camoufox", result.json["engine"]
  end

  test "entrega o HTML inteiro, não uma prévia" do
    # A versão antiga cortava em `html_preview: content[:5000]` — 148x menos que
    # a página real da wikipedia, e sem dizer que cortou.
    result = assert_ok(run_script(content_length: 20_000))
    payload = result.json

    assert_not payload.key?("html_preview"), "html_preview voltou: o corte silencioso de 5000 chars"
    assert_equal 20_000 + WRAPPER_CHARS, payload["content_length"]
    assert_equal payload["content_length"], payload["html"].length
    assert_equal false, payload["truncated"]
  end

  test "corte de HTML é declarado, com content_length real" do
    limite = 2_000_000
    real = limite + 5_000

    result = assert_ok(run_script(content_length: real - WRAPPER_CHARS))
    payload = result.json

    assert_equal true, payload["truncated"], "cortou sem declarar"
    # O tamanho tem que ser o da página, não o do que sobrou: é assim que quem
    # lê sabe o que deixou de receber.
    assert_equal real, payload["content_length"]
    assert_equal limite, payload["html"].length
  end

  test "proxy pedido chega ao navegador" do
    result = assert_ok(run_script(args: ["--proxy", "http://proxy.interno:3128"]))

    assert_includes result.calls.dig("launch", "proxy").to_s, "http://proxy.interno:3128"
  end

  test "stdout carrega só o JSON" do
    # `JSON.parse(stdout.strip)` no CamoufoxService: qualquer linha extra em
    # stdout (progresso de download, aviso, print de debug) devolve data nula.
    result = assert_ok(run_script)

    assert_equal 1, result.stdout.strip.lines.size, "stdout com mais de uma linha: #{result.stdout[0, 200]}"
  end
end
