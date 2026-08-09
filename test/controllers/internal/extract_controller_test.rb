# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/extract_service"

# As cinco provas pedidas para o /internal/extract. Todas verificam RECUSA:
# um teste que só vê 200 não distingue "protegido" de "não mediu nada".
class Internal::ExtractControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "token-de-teste-1234567890"

  setup do
    @previous_token = ENV["INTERNAL_EXTRACT_TOKEN"]
    ENV["INTERNAL_EXTRACT_TOKEN"] = TOKEN
    Rails.cache.clear
  end

  teardown do
    ENV["INTERNAL_EXTRACT_TOKEN"] = @previous_token
  end

  def auth_headers(token = TOKEN)
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  def post_extract(payload, headers: auth_headers)
    post "/internal/extract", params: payload.to_json, headers: headers
  end

  def first_result
    JSON.parse(response.body)["results"].first
  end

  # ── Prova 1: loopback direto ────────────────────────────────────────────────
  test "PROVA 1: URL de loopback é recusada" do
    post_extract({ urls: ["http://127.0.0.1:8888/"] })

    assert_response :success
    result = first_result
    assert_not_nil result["error"], "esperava erro para 127.0.0.1, veio: #{result.inspect}"
    assert_match(/privado|interno/i, result["error"])
    assert_nil result["content"]
    assert_equal "http://127.0.0.1:8888/", result["requested_url"]
  end

  test "PROVA 1b: localhost por nome também é recusado" do
    Fetcher::SsrfGuard.stubs(:resolve_all).with("localhost").returns(["127.0.0.1"])
    post_extract({ urls: ["http://localhost/admin"] })

    assert_match(/privado|interno/i, first_result["error"].to_s)
  end

  # ── Prova 2: redirect de host público para loopback ─────────────────────────
  # É o caso que falhava antes: SsrfGuard.validate! só olhava a URL inicial.
  test "PROVA 2: redirect de host público para 127.0.0.1 é recusado" do
    Fetcher::SsrfGuard.stubs(:resolve_all).with("redirecionador.example").returns(["93.184.216.34"])

    stub_request(:get, "http://redirecionador.example/vai")
      .to_return(status: 302, headers: { "Location" => "http://127.0.0.1:8888/segredo" })

    post_extract({ urls: ["http://redirecionador.example/vai"] })

    assert_response :success
    result = first_result
    assert_not_nil result["error"], "redirect para loopback passou — revalidação por hop não rodou"
    assert_match(/privado|interno/i, result["error"])
    assert_nil result["content"]
    assert_not_requested :get, "http://127.0.0.1:8888/segredo"
  end

  test "PROVA 2b: redirect para scheme não-http é recusado" do
    Fetcher::SsrfGuard.stubs(:resolve_all).with("redirecionador.example").returns(["93.184.216.34"])

    stub_request(:get, "http://redirecionador.example/file")
      .to_return(status: 302, headers: { "Location" => "file:///etc/passwd" })

    post_extract({ urls: ["http://redirecionador.example/file"] })

    assert_match(/scheme|host vazio/i, first_result["error"].to_s)
  end

  # ── Prova 3: metadata da nuvem ──────────────────────────────────────────────
  test "PROVA 3: endpoint de metadata da nuvem é recusado" do
    post_extract({ urls: ["http://169.254.169.254/latest/meta-data/iam/security-credentials/"] })

    assert_response :success
    result = first_result
    assert_not_nil result["error"]
    assert_match(/privado|interno/i, result["error"])
    assert_nil result["content"]
  end

  # ── Prova 4: sem credencial ─────────────────────────────────────────────────
  test "PROVA 4: POST sem Authorization responde 401" do
    post "/internal/extract",
         params: { urls: ["https://example.com"] }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_nil JSON.parse(response.body)["results"]
  end

  test "PROVA 4b: token errado responde 401" do
    post_extract({ urls: ["https://example.com"] }, headers: auth_headers("token-errado"))

    assert_response :unauthorized
  end

  test "PROVA 4c: sem token configurado o endpoint recusa tudo" do
    ENV["INTERNAL_EXTRACT_TOKEN"] = nil
    post_extract({ urls: ["https://example.com"] })

    assert_response :service_unavailable
  end

  # ── Prova 5: teto de URLs ───────────────────────────────────────────────────
  test "PROVA 5: 50 URLs recebem teto declarado, não truncamento silencioso" do
    urls = Array.new(50) { |i| "https://example.com/#{i}" }

    Fetcher::ExtractService.expects(:call).never

    post_extract({ urls: urls })

    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal Internal::ExtractController::MAX_URLS, body["max_urls"]
    assert_equal 50, body["received"]
    assert_match(/máximo de #{Internal::ExtractController::MAX_URLS} urls/, body["error"])
    assert_nil body["results"], "não pode devolver resultados parciais em silêncio"
  end

  # ── Contrato do plugin ──────────────────────────────────────────────────────
  test "resposta preserva requested_url mesmo com redirect e devolve markdown" do
    html = <<~HTML
      <html><head><title>Notas da versão</title></head>
      <body><article>
        <h1>Release 2.0</h1>
        <p>#{'Texto de corpo com tamanho suficiente para não ser considerado magro. ' * 12}</p>
        <ul><li>Primeiro item</li><li>Segundo item</li></ul>
      </article></body></html>
    HTML

    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    stub_request(:get, "http://exemplo.test/notas")
      .to_return(status: 302, headers: { "Location" => "http://exemplo.test/notas/v2" })
    stub_request(:get, "http://exemplo.test/notas/v2")
      .to_return(status: 200, body: html, headers: { "Content-Type" => "text/html; charset=utf-8" })

    post_extract({ urls: ["http://exemplo.test/notas"], max_chars: 15_000 })

    assert_response :success
    result = first_result
    assert_nil result["error"], result.inspect
    assert_equal "http://exemplo.test/notas", result["requested_url"]
    assert_equal "http://exemplo.test/notas/v2", result["url"]
    assert_equal "Notas da versão", result["title"]
    assert_match(/^# Release 2\.0$/, result["content"])
    assert_match(/^- Primeiro item$/, result["content"])
    assert_not_includes result["content"], "<h1>"
  end

  test "erro de uma URL não derruba as outras do lote" do
    Fetcher::SsrfGuard.stubs(:resolve_all).with("ok.test").returns(["93.184.216.34"])
    stub_request(:get, "http://ok.test/")
      .to_return(status: 200,
                 body: "<html><title>OK</title><body><p>#{'conteúdo suficiente ' * 40}</p></body></html>",
                 headers: { "Content-Type" => "text/html" })

    post_extract({ urls: ["http://127.0.0.1/", "http://ok.test/"] })

    assert_response :success
    results = JSON.parse(response.body)["results"]
    assert_equal 2, results.size
    assert_not_nil results[0]["error"]
    assert_nil results[1]["error"], results[1].inspect
    assert_equal ["http://127.0.0.1/", "http://ok.test/"], results.map { |r| r["requested_url"] }
  end

  test "max_chars é clampado em silêncio" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    stub_request(:get, "http://grande.test/")
      .to_return(status: 200,
                 body: "<html><title>T</title><body><p>#{'a' * 5_000}</p></body></html>",
                 headers: { "Content-Type" => "text/html" })

    post_extract({ urls: ["http://grande.test/"], max_chars: 900_000 })

    assert_response :success
    assert_operator first_result["content"].length, :<=, Fetcher::ExtractService::MAX_MAX_CHARS
  end

  test "lista vazia é rejeitada" do
    post_extract({ urls: [] })
    assert_response :bad_request
  end
end
