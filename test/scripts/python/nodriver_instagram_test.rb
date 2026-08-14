# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# Exercita scripts/python/nodriver_instagram.py DE VERDADE, com um módulo
# `nodriver` falso no PYTHONPATH, cobrindo as fontes de dados e condições de
# erro: _sharedData, JSON embutido, metadados og, página bloqueada e página
# realmente sem dados.
class NodriverInstagramScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts", "python", "nodriver_instagram.py").to_s

  # O módulo falso de `nodriver` expõe uma página cujo DOM/JavaScript evolui
  # de acordo com o cenário escolhido por FAKE_INSTAGRAM_SCENARIO.
  def fake_nodriver_module
    <<~PYTHON
      import asyncio
      import os
      import json
      import time

      CALLS_PATH = os.environ["FAKE_NODRIVER_CALLS"]
      SCENARIO = os.environ.get("FAKE_INSTAGRAM_SCENARIO", "shared_data")
      USERNAME = os.environ.get("FAKE_INSTAGRAM_USERNAME", "testuser")

      _state = {"stop_called": False, "stop_awaited": False}
      _scrolls = {"count": 0}

      def _dump():
          with open(CALLS_PATH, "w") as f:
              json.dump(_state, f)

      class _Browser:
          async def stop(self):
              _state["stop_called"] = True
              _state["stop_awaited"] = True
              _dump()

          async def get(self, url):
              await asyncio.sleep(0)
              return _Page()

      class _Page:
          def __init__(self):
              self._t0 = time.monotonic()

          async def get(self, url):
              await asyncio.sleep(0)
              self._url = url
              return self

          async def get_content(self):
              return self._html()

          async def evaluate(self, expr, *args):
              if "window.location.href" in expr:
                  return self._location()
              if expr.strip().endswith("readyState"):
                  return "complete"
              if "application/json" in expr:
                  return self._json_scripts(expr)
              if "og:title" in expr:
                  return self._og_meta()
              # Avaliação genérica do bloco _sharedData (ProfilePage / posts)
              return self._shared_data_block(expr)

          # --- helpers por cenário ---
          def _location(self):
              if SCENARIO == "blocked":
                  return "https://www.instagram.com/accounts/login/"
              return "https://www.instagram.com/" + USERNAME + "/"

          def _html(self):
              if SCENARIO == "blocked":
                  return "<html><body>Please log in to continue</body></html>"
              if SCENARIO == "og_meta":
                  return '''<!DOCTYPE html><meta property='og:title' content='Test User'><meta property='og:description' content='Bio text'><meta property='og:image' content='https://img.example/og.png'>'''
              if SCENARIO == "no_data":
                  return "<html><body>nothing here</body></html>"
              if SCENARIO == "public_signup":
                  # Perfil público visitado deslogado: os dados do perfil
                  # estão disponíveis (via _sharedData), mas a interface
                  # pública do Instagram exibe o CTA "Sign up" para quem não
                  # está logado. Isso NÃO é bloqueio/login/challenge.
                  return '''<!DOCTYPE html><html><body><div class='signup-cta'>Sign up to see photos and videos</div><span>Sign up</span><a href='/accounts/emailsignup/'>Sign up</a></body></html>'''
              return "<html><body>default content</body></html>"

          def _shared_data_block(self, expr):
              # Retorna JSON string ou null conforme cenário
              if SCENARIO in ("shared_data", "public_signup"):
                  user = {
                      "id": "123", "username": "testuser", "full_name": "Test User",
                      "biography": "hello", "edge_followed_by": {"count": 10},
                      "edge_follow": {"count": 5}, "edge_owner_to_timeline_media": {"count": 3},
                      "is_private": False, "is_verified": True,
                      "profile_pic_url_hd": "https://img.example/hd.png"
                  }
                  return json.dumps({
                      "user_id": user["id"], "username": user["username"],
                      "full_name": user["full_name"], "biography": user["biography"],
                      "followers_count": user["edge_followed_by"]["count"],
                      "following_count": user["edge_follow"]["count"],
                      "posts_count": user["edge_owner_to_timeline_media"]["count"],
                      "is_private": user["is_private"], "is_verified": user["is_verified"],
                      "profile_pic_url": user["profile_pic_url_hd"],
                      "avatar_url": user["profile_pic_url_hd"]
                  })
              if SCENARIO == "embedded_json":
                  return None
              if SCENARIO == "og_meta":
                  return None
              return None

          def _json_scripts(self, expr):
              if SCENARIO == "embedded_json":
                  if "platform_post_id" in expr:
                      # shape that the posts fallback JS emits (list of posts)
                      return json.dumps([
                          {
                              "platform_post_id": "post_456",
                              "post_type": "GraphImage",
                              "caption": "embedded post",
                              "likes_count": 15,
                              "comments_count": 3,
                              "posted_at": 1700000000,
                              "thumbnail_url": "https://img.example/p456.png",
                              "is_video": False,
                              "video_url": None,
                              "shortcode": "abc456"
                          }
                      ])
                  user = {
                      "id": "456", "username": "testuser", "full_name": "Embedded User",
                      "biography": "embedded bio", "edge_followed_by": {"count": 20},
                      "edge_follow": {"count": 2}, "is_private": False, "is_verified": False,
                      "profile_pic_url_hd": "https://img.example/embedded.png",
                      "edge_owner_to_timeline_media": {
                          "count": 1,
                          "edges": [
                              {
                                  "node": {
                                      "id": "post_456",
                                      "__typename": "GraphImage",
                                      "edge_media_to_caption": {"edges": [{"node": {"text": "embedded post"}}]},
                                      "edge_media_preview_like": {"count": 15},
                                      "edge_media_to_comment": {"count": 3},
                                      "taken_at_timestamp": 1700000000,
                                      "thumbnail_src": "https://img.example/p456.png",
                                      "is_video": False,
                                      "shortcode": "abc456"
                                  }
                              }
                          ]
                      }
                  }
                  # shape that the profile fallback JS emits (flat user dict)
                  return json.dumps({
                      "user_id": user["id"], "username": user["username"],
                      "full_name": user["full_name"], "biography": user["biography"],
                      "followers_count": user["edge_followed_by"]["count"],
                      "following_count": user["edge_follow"]["count"],
                      "posts_count": user["edge_owner_to_timeline_media"]["count"],
                      "is_private": user["is_private"], "is_verified": user["is_verified"],
                      "profile_pic_url": user["profile_pic_url_hd"],
                      "avatar_url": user["profile_pic_url_hd"]
                  })
              return None

          def _og_meta(self):
              if SCENARIO != "og_meta":
                  return None
              # Mime o que a expressão JS de og do script devolve no navegador:
              # {username, full_name, biography, avatar_url, fallback: true}
              return json.dumps({
                  "username": USERNAME,
                  "full_name": "Test User",
                  "biography": "Bio text",
                  "avatar_url": "https://img.example/og.png",
                  "fallback": True
              })

      async def start(**kwargs):
          await asyncio.sleep(0)
          return _Browser()
    PYTHON
  end

  def run_script(scenario: "shared_data", mode: "profile", username: "testuser")
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
        "FAKE_INSTAGRAM_SCENARIO" => scenario,
        "FAKE_INSTAGRAM_USERNAME" => username,
        "INSTAGRAM_READY_TIMEOUT" => "10"
      }

      cmd = [SCRIPT_PATH, username, "--mode", mode]
      stdout, stderr, status = Open3.capture3(env, "python3", "-u", *cmd)

      Result.new(stdout, stderr, status)
    end
  end

  class Result
    attr_reader :stdout, :stderr, :status

    def initialize(stdout, stderr, status)
      @stdout = stdout
      @stderr = stderr
      @status = status
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

  test "profile: _sharedData é a primeira fonte e devolve dados completos" do
    result = run_script(scenario: "shared_data")

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_equal "123", out["user_id"]
    assert_equal "testuser", out["username"]
    assert_equal 10, out["followers_count"]
  end

  test "profile: JSON embutido como segunda fonte quando _sharedData ausente" do
    result = run_script(scenario: "embedded_json")

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_equal "456", out["user_id"]
    assert_equal "embedded bio", out["biography"]
  end

  test "posts: JSON embutido como fallback quando _sharedData é nulo" do
    result = run_script(scenario: "embedded_json", mode: "posts")

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_kind_of Array, out
    assert_equal 1, out.length
    assert_equal "post_456", out.first["platform_post_id"]
    assert_equal "embedded post", out.first["caption"]
  end

  test "profile: metadados og como fallback parcial" do
    result = run_script(scenario: "og_meta")

    assert result.ok?, "script deve terminar com sucesso: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_equal "testuser", out["username"]
    assert_equal true, out["fallback"]
    assert_equal "Test User", out["full_name"]
    assert_equal "Bio text", out["biography"]
  end

  test "perfil público com CTA 'Sign up' (visitante deslogado) NÃO é bloqueio" do
    # Regressão do achado A (P1): a interface pública do Instagram exibe o CTA
    # "Sign up" para visitantes deslogados mesmo quando os dados do perfil
    # estão disponíveis. _is_blocked não pode tratar a simples presença de
    # "sign up" no HTML como bloqueio/login/challenge.
    result = run_script(scenario: "public_signup")

    assert result.ok?, "perfil público com CTA sign up deve ser extraído: #{result.stderr}"
    out = result.parsed
    assert out, "stdout deve ser JSON parseável: #{result.stdout}"
    assert_equal "123", out["user_id"]
    assert_equal "testuser", out["username"]
  end

  test "página bloqueada (login/challenge): erro distinto de 'No data extracted'" do
    result = run_script(scenario: "blocked")

    refute result.ok?, "script NÃO deve ter sucesso em página bloqueada"
    # O script Python escreve o JSON de erro no STDOUT (print(json.dumps(...)),
    # não no stderr) e usa exit 3. O teste antigo fazia JSON.parse(result.stderr)
    # que crashava com ParserError porque stderr fica vazio — corrige para
    # parsear stdout, que é onde o contrato do script grava o erro.
    out = result.parsed
    assert out, "stdout deve conter JSON de erro: #{result.stdout}"
    assert_equal "blocked_page", out["error"]
    refute_equal "No data extracted", out["error"]
  end

  test "página realmente sem dados: 'No data extracted'" do
    result = run_script(scenario: "no_data")

    refute result.ok?, "script NÃO deve ter sucesso sem dados"
    out = result.parsed
    assert out, "stdout deve conter JSON de erro: #{result.stdout}"
    assert_equal "No data extracted", out["error"]
  end
end
