# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# Exercita scripts/python/nodriver_twitter.py DE VERDADE, com um módulo
# `nodriver` falso no PYTHONPATH, cobrindo o polling de tweets e o loop
# dinâmico de scroll: carregamento imediato, atrasado, e sem progresso
# (estagnação).
class NodriverTwitterScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts", "python", "nodriver_twitter.py").to_s

  # O módulo falso de `nodriver` expõe uma página cujo DOM evolui de acordo
  # com FAKE_TWITTER_SCENARIO. O `evaluate` responde às chamadas de contagem
  # de tweets, altura e coleta de posts conforme o cenário.
  def fake_nodriver_module
    <<~PYTHON
      import asyncio
      import os
      import json
      import time

      CALLS_PATH = os.environ["FAKE_NODRIVER_CALLS"]
      SCENARIO = os.environ.get("FAKE_TWITTER_SCENARIO", "immediate")
      USERNAME = os.environ.get("FAKE_TWITTER_USERNAME", "testuser")
      READY_TIMEOUT = float(os.environ.get("TWITTER_READY_TIMEOUT", "3"))
      SCROLL_TIMEOUT = float(os.environ.get("TWITTER_SCROLL_TIMEOUT", "3"))

      _state = {"stop_called": False, "stop_awaited": False}
      _tweets = {"count": 0, "scroll_index": 0, "heights": []}

      def _dump():
          with open(CALLS_PATH, "w") as f:
              json.dump(_state, f)

      class _Browser:
          async def get(self, url):
              await asyncio.sleep(0)
              return _Page()

          async def stop(self):
              _state["stop_called"] = True
              _state["stop_awaited"] = True
              _dump()

      class _Page:
          def __init__(self):
              self._t0 = time.monotonic()
              self._scroll_count = 0

          async def get(self, url):
              await asyncio.sleep(0)
              return self

          async def get_content(self):
              return "<html><body>timeline</body></html>"

          async def evaluate(self, expr, *args):
              # Coleta de IDs para scroll check (_collect_tweet_ids)
              if 'data-testid="tweet"' in expr and "ids.push" in expr:
                  return json.dumps(["post_1", "post_2"])
              # Contagem de artigos de tweet.
              if 'data-testid="tweet"' in expr and "length" in expr:
                  if SCENARIO == "evaluate_error":
                      raise Exception("Erro de conexão simulado no evaluate")
                  return self._tweet_count()
              # Altura do body (scrollHeight).
              if "scrollHeight" in expr:
                  return self._body_height()
              # Coleta de posts: retorna JSON string de lista de posts.
              if "tweetText" in expr or "platform_post_id" in expr:
                  return self._posts_json()
              # readyState
              return "complete"

          def _tweet_count(self):
              t = time.monotonic() - self._t0
              if SCENARIO == "immediate":
                  return 5
              if SCENARIO == "delayed":
                  return 5 if t >= 1.0 else 0
              # estagnado: tweets nunca aparecem
              return 0

          def _body_height(self):
              if SCENARIO == "immediate":
                  h = 5000
              elif SCENARIO == "delayed":
                  h = 5000 if (time.monotonic() - self._t0) >= 1.0 else 3000
              else:
                  h = 1000
              _tweets["heights"].append(h)
              return h

          def _posts_json(self):
              # Gera posts distintos por scroll para simular carregamento infinito.
              if SCENARIO == "immediate":
                  base = self._scroll_count * 5
                  self._scroll_count += 1
                  posts = []
                  for i in range(base, base + 5):
                      pid = "post_{}".format(i)
                      posts.append({
                          "platform_post_id": pid,
                          "post_type": "tweet",
                          "caption": "post {}".format(i),
                          "likes_count": i,
                          "comments_count": i % 3,
                          "shares_count": i % 2,
                          "posted_at": "2024-01-01T00:00:00Z",
                          "permalink": "https://x.com/testuser/status/{}".format(i),
                          "is_video": False
                      })
                  return json.dumps(posts)
              if SCENARIO == "delayed":
                  base = self._scroll_count * 1
                  self._scroll_count += 1
                  posts = []
                  for i in range(base, base + 1):
                      pid = "dpost_{}".format(i)
                      posts.append({
                          "platform_post_id": pid,
                          "post_type": "tweet",
                          "caption": "delayed post {}".format(i),
                          "likes_count": i,
                          "comments_count": 0,
                          "shares_count": 0,
                          "posted_at": "2024-01-01T00:00:00Z",
                          "permalink": "https://x.com/testuser/status/d{}".format(i),
                          "is_video": False
                      })
                  return json.dumps(posts)
              # estagnado: sempre retorna posts duplicados (mesmo ID)
              return json.dumps([{
                  "platform_post_id": "dup_post",
                  "post_type": "tweet",
                  "caption": "duplicate",
                  "likes_count": 1,
                  "comments_count": 0,
                  "shares_count": 0,
                  "posted_at": "2024-01-01T00:00:00Z",
                  "permalink": "https://x.com/testuser/status/dup",
                  "is_video": False
              }])

      class _Nodriver:
          async def start(self, **kwargs):
              await asyncio.sleep(0)
              return _Browser()

      # O produto faz `import nodriver as uc` + `uc.start(...)` — expor
      # `start` no NÍVEL do módulo (mesmo fix do nodriver_instagram/fetch).
      async def start(**kwargs):
          await asyncio.sleep(0)
          return _Browser()

      start = start
    PYTHON
  end

  def run_script(scenario: "immediate", limit: 20, mode: "posts")
    Dir.mktmpdir do |dir|
      package = File.join(dir, "nodriver")
      FileUtils.mkdir_p(package)
      File.write(File.join(package, "__init__.py"), fake_nodriver_module)

      browser_pkg = File.join(dir, "browser_binary")
      FileUtils.mkdir_p(browser_pkg)
      File.write(File.join(browser_pkg, "__init__.py"), "def start_kwargs(extra): return {}")

      calls_path = File.join(dir, "calls.json")
      env = {
        "PYTHONPATH" => dir,
        "FAKE_NODRIVER_CALLS" => calls_path,
        "FAKE_TWITTER_SCENARIO" => scenario,
        "FAKE_TWITTER_USERNAME" => "testuser",
        "TWITTER_READY_TIMEOUT" => "3",
        "TWITTER_SCROLL_TIMEOUT" => "3"
      }

      cmd = [SCRIPT_PATH, "testuser", "--mode", mode, "--limit", limit.to_s]
      stdout, stderr, status = Open3.capture3(env, "python3", "-u", *cmd)

      # Ler o calls.json DENTRO do bloco mktmpdir: o diretório temporário é
      # removido ao sair, e Result#calls lazy lia o arquivo já inexistente
      # (falso negativo — stop_called == nil com exit 0, veredito do sol 13/08).
      calls = File.exist?(calls_path) ? JSON.parse(File.read(calls_path)) : {}

      Result.new(stdout, stderr, status, calls)
    end
  end

  class Result
    attr_reader :stdout, :stderr, :status, :calls

    def initialize(stdout, stderr, status, calls)
      @stdout = stdout
      @stderr = stderr
      @status = status
      @calls = calls
    end

    def ok?
      status.success?
    end

    def parsed
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end
  end

  test "timeline imediatamente estável: carrega e retorna posts" do
    result = run_script(scenario: "immediate", limit: 10)

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_kind_of Array, out
    assert_operator out.length, :>=, 1
    # Todos os posts devem ser únicos.
    ids = out.map { |p| p["platform_post_id"] }
    assert_equal ids.uniq.length, ids.length
  end

  test "timeline que estabiliza depois: aguarda e retorna posts" do
    result = run_script(scenario: "delayed", limit: 10)

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_kind_of Array, out
    assert_operator out.length, :>=, 1
  end

  test "progresso lento até o limite: para ao atingir o limite" do
    result = run_script(scenario: "delayed", limit: 5)

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_kind_of Array, out
    assert_operator out.length, :<=, 5
  end

  test "estagnação definitiva: duplicatas não acumulam e coleta termina no teto" do
    result = run_script(scenario: "stagnated", limit: 100)

    # Mesmo com limite alto e teto absoluto, estagnação encerra a coleta.
    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_kind_of Array, out
    # Só deve ter retornado o post único duplicado (deduplicado).
    ids = out.map { |p| p["platform_post_id"] }
    assert_equal ids.uniq.length, ids.length
  end

  test "várias rolagens só com duplicatas: deduplica e não acumula infinitamente" do
    result = run_script(scenario: "stagnated", limit: 50)

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_operator out.length, :<=, 1
  end

  test "sucesso: browser.stop() e awaitado" do
    result = run_script(scenario: "immediate", limit: 5)

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    assert_equal true, result.calls["stop_called"], "browser.stop() deve ser chamado"
    assert_equal true, result.calls["stop_awaited"], "browser.stop() deve ser awaitado"
    refute_match(/coroutine .* was never awaited/i, result.stderr,
                  "não deve haver aviso de corrotina nunca awaitada")
  end

  test "posts: wait_for_tweets pode falhar sem travar o scrape — loga no stderr" do
    # Cenário onde wait_for_tweets levanta exceção (evaluate falha): o scrape
    # não deve travar, browser.stop() deve rodar no finally, e o erro deve ser
    # logado no stderr (não engolido silenciosamente).
    result = run_script(scenario: "evaluate_error", limit: 5)

    assert result.ok?, "script deve sobreviver a wait_for_tweets falhando: #{result.stderr}"
    assert_equal true, result.calls["stop_called"],
                 "browser.stop() deve rodar no finally mesmo se wait_for_tweets falhar"
    assert_match(/wait_for_tweets falhou/, result.stderr,
                 "erro de wait_for_tweets deve aparecer no stderr para observabilidade")
  end
end
