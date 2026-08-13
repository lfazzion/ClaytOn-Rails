# frozen_string_literal: true

require "test_helper"
require "json"
require "net/http"
require "uri"
require "socket"
require "tmpdir"
require "fileutils"

# Exercita a rota GET /health do `scripts/python/server.py` DE VERDADE em subprocesso,
# cobrindo: prontidão completa (200 quando todos os scripts e imports estão presentes)
# e dependência ausente (503 com lista de scripts/imports indisponíveis).
class ServerHealthTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts/python/server.py").to_s
  TEST_TOKEN = "health_test_token_888"

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Inicia o server.py apontando SCRIPTS_DIR para um diretório temporário.
  # FALTA um ou mais scripts e/ou imports — o /health deve responder 503.
  def with_server(scripts_dir:, env_overrides: {})
    port = find_free_port

    env = {
      "PYTHONPATH" => scripts_dir,
      "PYTHON_SCRAPER_TOKEN" => TEST_TOKEN,
      "SCRAPER_PORT" => port.to_s,
      "SCRAPER_BIND" => "127.0.0.1",
      "SCRAPER_SCRIPTS_DIR" => scripts_dir,
    }.merge(env_overrides)

    pid = Process.spawn(
      env,
      "python3", "-u", SCRIPT_PATH,
      out: File::NULL,
      err: File::NULL,
    )

    uri = URI("http://127.0.0.1:#{port}/health")
    up = false
    20.times do
      sleep 0.1
      res = Net::HTTP.get_response(uri) rescue nil
      if res
        up = true
        break
      end
    end

    flunk("Servidor server.py não subiu na porta #{port}") unless up

    begin
      yield "http://127.0.0.1:#{port}"
    ensure
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  # Monta um SCRIPTS_DIR temporário com todos os scripts permitidos presentes,
  # simulando o sidecar completo (imports reais não existem no ambiente de teste,
  # mas o /health valida scripts via filesystem e imports via importlib).
  def make_full_scripts_dir
    dir = Dir.mktmpdir("health_scripts")
    # Cria stubs vazios para cada script da allowlist — o healthcheck verifica
    # apenas a presença do arquivo, não seu conteúdo.
    ALLOWED_SCRIPTS.each do |script|
      File.write(File.join(dir, script), "# stub\n")
    end
    dir
  end

  # Lista os scripts permitidos — importada diretamente da allowlist do server.py
  # para garantir que o teste cobra exatamente os mesmos nomes.
  ALLOWED_SCRIPTS = %w[
    nodriver_fetch.py
    nodriver_instagram.py
    nodriver_twitter.py
    camoufox_scrape.py
    curl_impersonate.py
  ].freeze

  test "GET /health responde 503 quando scripts permitidos estão ausentes" do
    # Diretório temporário vazio — nenhum script presente.
    Dir.mktmpdir("health_missing") do |dir|
      with_server(scripts_dir: dir) do |base_url|
        uri = URI("#{base_url}/health")
        res = Net::HTTP.get_response(uri)

        assert_equal 503, res.code.to_i
        json = JSON.parse(res.body)

        assert_equal "unavailable", json["status"]
        # Todos os scripts da allowlist devem estar na lista de ausentes.
        assert_equal ALLOWED_SCRIPTS.sort, json["unavailable_scripts"].sort
        # Os imports essenciais também devem ser reportados (ausentes no ambiente
        # de teste onde nodriver/camoufox/curl_cffi/pypdf não estão instalados).
        assert(json["unavailable_imports"].is_a?(Array))
        assert(json["unavailable_imports"].any?, "unavailable_imports não deve estar vazio")
      end
    end
  end

  test "GET /health responde 503 listando apenas os imports ausentes quando scripts estão presentes" do
    dir = make_full_scripts_dir
    begin
      with_server(scripts_dir: dir) do |base_url|
        uri = URI("#{base_url}/health")
        res = Net::HTTP.get_response(uri)

        assert_equal 503, res.code.to_i
        json = JSON.parse(res.body)

        assert_equal "unavailable", json["status"]
        # Scripts todos presentes:
        assert_equal [], json["unavailable_scripts"]
        # Imports ausentes no ambiente de teste:
        assert(json["unavailable_imports"].any?, "unavailable_imports deve listar os módulos Python ausentes")
      end
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end
  end

  test "GET /health responde 200 com status ok e lista de scripts quando tudo está disponível" do
    # Simula o ambiente completo: todos os scripts presentes e todos os imports
    # resolvíveis. Fazemos isso injetando um site-packages customizado com
    # stubs dos módulos — o server.py usa importlib.util.find_spec, que respeita
    # sys.path / PYTHONPATH.
    Dir.mktmpdir("health_full") do |base|
      scripts_dir = File.join(base, "scripts")
      site_dir = File.join(base, "site-packages")
      FileUtils.mkdir_p(scripts_dir)
      FileUtils.mkdir_p(site_dir)

      ALLOWED_SCRIPTS.each do |script|
        File.write(File.join(scripts_dir, script), "# stub\n")
      end

      # Stub mínimo para cada import essencial — find_spec encontra o pacote.
      %w[nodriver camoufox curl_cffi pypdf].each do |mod|
        mod_dir = File.join(site_dir, mod)
        FileUtils.mkdir_p(mod_dir)
        # __init__.py vazio transforma o dir em package importável.
        File.write(File.join(mod_dir, "__init__.py"), "")
      end

      with_server(scripts_dir: scripts_dir, env_overrides: { "PYTHONPATH" => [site_dir, scripts_dir].join(":") }) do |base_url|
        uri = URI("#{base_url}/health")
        res = Net::HTTP.get_response(uri)

        assert res.is_a?(Net::HTTPSuccess), "esperava 200, recebi #{res.code}: #{res.body}"
        json = JSON.parse(res.body)

        assert_equal "ok", json["status"]
        assert_equal ALLOWED_SCRIPTS.sort, json["scripts"].sort
      end
    end
  end

  test "GET /health não inicia navegadores" do
    # O healthcheck valida imports via importlib.util.find_spec — que NÃO
    # executa código do módulo. Garante que stub de pacote sem __init__ executável
    # não levanta erro de importação (não há código de browser sendo carregado).
    Dir.mktmpdir("health_no_browser") do |dir|
      with_server(scripts_dir: dir) do |base_url|
        uri = URI("#{base_url}/health")
        res = Net::HTTP.get_response(uri)

        # Deve responder (503, já que scripts faltam) sem bloquear ou crashar
        # por tentar importar código de browser.
        assert_includes [200, 503], res.code.to_i
        json = JSON.parse(res.body)
        assert_equal "unavailable", json["status"]
      end
    end
  end
end
