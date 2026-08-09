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

  # Contrato mínimo do resultado — usado onde basta stubbar `Fetcher::ExtractService.call`
  # (testes de TETO do lote, que não provam pareamento).
  def extract_contract(url, title: "Título", error: nil)
    {
      requested_url: url, url: url, title: title, content: "Conteúdo de #{title}",
      raw_content: nil, engine: "static", rendered: false, metadata: {}, error: error
    }
  end

  # ── Prove 6 (novo): o teto não pode estrangular o lote real do reader ─────
  # O reader (Hermes) manda 5 URLs por chamada. Antes este teste falhava com
  # 400 (MAX_URLS = CONCURRENCY = 4). O teto subiu para 2×CONCURRENCY, e o
  # lote de 5 cabe no orçamento de 90s (pior caso 2 ondas × 40s = 80s).
  #
  # O lote roda PARALELO (threads). Para provar que o pareamento
  # results[index] ↔ url pedida não embaralha, cada host devolve um HTML com
  # TÍTULO e conteúdo DISTINTOS, e o serviço real (não stub de .call) monta o
  # `requested_url`. Se os resultados cruzassem posições, o título do host i
  # apareceria sob a URL do host j. Stubbar `.call` com um hash único não prova
  # nada aqui — só provaria o stub.
  def body_html(title)
    corpo = "Conteúdo de #{title} — " + ("texto estatico de corpo para nao ser magro. " * 15)
    "<html><head><title>#{title}</title></head><body><article><h1>#{title}</h1><p>#{corpo}</p></article></body></html>"
  end

  test "PROVA 6: lote de 5 URLs é aceito, processado e pareado sem embaralhar" do
    urls = (0...5).map { |i| "https://exemplo#{i}.test/pagina#{i}" }
    titulos = urls.each_with_index.to_h { |url, i| [url, "Orgao #{i}"] }

    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    titulos.each { |url, titulo| stub_request(:get, url).to_return(status: 200, body: body_html(titulo), headers: { "Content-Type" => "text/html; charset=utf-8" }) }

    post_extract({ urls: urls, max_chars: 1000 })

    assert_response :success, "lote de 5 não pode dar 400: #{response.body.inspect}"
    body = JSON.parse(response.body)
    assert_nil body["error"]
    assert_equal urls.size, body["results"].size
    seen = body["results"].each_with_index.map do |r, i|
      refute_nil r, "cada posição do lote deve ter um resultado, não nil"
      assert_nil r["error"], r.inspect
      assert_equal urls[i], r["requested_url"], "resultado na posição #{i} não casa com a URL pedida"
      assert_equal titulos[urls[i]], r["title"], "título da posição #{i} não é o do host #{urls[i]} — lote embaralhou"
      r["requested_url"]
    end
    assert_equal urls.sort, seen.sort, "toda URL do lote foi pareada com o próprio resultado"
  end

  # ── Teto de URLs (MAX_URLS): limite é exatamente CONCURRENCY × 2 ───────────
  test "lote de exatamente MAX_URLS é aceito" do
    urls = Array.new(Internal::ExtractController::MAX_URLS) { |i| "https://cheia#{i}.test/" }

    # Prova o TETO, não o pareamento: retorno fixo basta.
    Fetcher::ExtractService.expects(:call).times(urls.size).returns(extract_contract("x"))

    post_extract({ urls: urls })

    assert_response :success, "lote de MAX_URLS (#{urls.size}) não pode dar 400: #{response.body.inspect}"
    body = JSON.parse(response.body)
    assert_nil body["error"]
    assert_equal urls.size, body["results"].size
  end

  test "lote de MAX_URLS+1 é rejeitado com 400 e teto declarado" do
    urls = Array.new(Internal::ExtractController::MAX_URLS + 1) { |i| "https://estouro#{i}.test/" }

    Fetcher::ExtractService.expects(:call).never

    post_extract({ urls: urls })

    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal Internal::ExtractController::MAX_URLS, body["max_urls"]
    assert_equal urls.size, body["received"]
    assert_match(/máximo de #{Internal::ExtractController::MAX_URLS} urls/, body["error"])
    assert_nil body["results"]
  end

  test "EXTRACT_CONCURRENCY=1 → MAX_URLS=2 (aceita 2, rejeita 3)" do
    with_forced_concurrency(1, 2) do
      ok = Array.new(2) { |i| "https://c1-ok#{i}.test/" }
      Fetcher::ExtractService.expects(:call).times(2).returns(extract_contract("x"))
      post_extract({ urls: ok })
      assert_response :success, "com C=1, lote de 2 deve ser aceito: #{response.body.inspect}"
      assert_equal 2, JSON.parse(response.body)["results"].size

      Fetcher::ExtractService.unstub(:call)
      Fetcher::ExtractService.expects(:call).never
      estouro = Array.new(3) { |i| "https://c1-estouro#{i}.test/" }
      post_extract({ urls: estouro })
      assert_response :bad_request
      assert_equal 3, JSON.parse(response.body)["received"]
    end
  end

  test "EXTRACT_CONCURRENCY=8 → MAX_URLS=16 (aceita 16, rejeita 17)" do
    with_forced_concurrency(8, 16) do
      ok = Array.new(16) { |i| "https://c8-ok#{i}.test/" }
      Fetcher::ExtractService.expects(:call).times(16).returns(extract_contract("x"))
      post_extract({ urls: ok })
      assert_response :success, "com C=8, lote de 16 deve ser aceito: #{response.body.inspect}"
      assert_equal 16, JSON.parse(response.body)["results"].size

      Fetcher::ExtractService.unstub(:call)
      Fetcher::ExtractService.expects(:call).never
      estouro = Array.new(17) { |i| "https://c8-estouro#{i}.test/" }
      post_extract({ urls: estouro })
      assert_response :bad_request
      assert_equal 17, JSON.parse(response.body)["received"]
    end
  end

  # `CONCURRENCY` e `MAX_URLS` são avaliados no load da classe e referenciados em
  # runtime, então para testar um cenário de env forçado troco as duas constantes
  # na mão (guardar → remove_const → const_set → yield → restaurar no ensure).
  # Isso funciona em qualquer pilha, sem depender da assinatura do `stub_const`.
  def with_stubbed_const(mod, name, value)
    original = mod.const_get(name, false)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end

  def with_forced_concurrency(concurrency, max_urls)
    with_stubbed_const(Internal::ExtractController, :CONCURRENCY, concurrency) do
      with_stubbed_const(Internal::ExtractController, :MAX_URLS, max_urls) do
        yield
      end
    end
  end

  # ── Teto TOTAL por URL (TOTAL_PER_URL_TIMEOUT) ─────────────────────────────
  # O timeout externo em ExtractService.call converte estouro de tempo em
  # failure com `error` preenchido — nunca 500, nunca derruba o lote.
  # Teste unitário: baixa o teto para 0.2s e faz `extract` dormir além dele,
  # provando que o Timeout.timeout de `call` pega e devolve failure.
  # NÃO usar Mocha para o `extract` que bloqueia: `returns { bloco }` do Mocha
  # devolve nil na hora (medido 09/08/2026) — usar singleton method, Ruby puro.
  test "URL que excede o teto total por URL vira failure com error, não 500" do
    url = "https://lenta.test/a"

    with_stubbed_const(Fetcher::ExtractService, :TOTAL_PER_URL_TIMEOUT, 0.2) do
      service = Fetcher::ExtractService.new(max_chars: 1000)
      service.define_singleton_method(:extract) { |_u| sleep 5 }

      result = service.call(url)

      refute_nil result[:error], "esperava error no resultado do timeout, veio sucesso"
      assert_includes result[:error], "excedeu", "mensagem de timeout esperada, veio: #{result[:error].inspect}"
      assert_nil result[:content]
      assert_nil result[:title]
    end
  end

  # Timeout de URL não corta as outras do lote: cada URL é isolada em um
  # Thread no controller, e o failure do tempo não pode virar 500 (o endpoint
  # já tem teste de que erro de uma URL não derruba as outras; este garante,
  # no nível do serviço, que o path do Timeout também devolve hash, nunca
  # exceção). O isolamento por thread em si é coberto pelo teste do controller
  # "erro de uma URL não derruba o lote".
  test "URL estourando tempo vira failure e não afeta a extração de outra URL (nível serviço)" do
    urls = ["https://lenta.test/a", "https://rapida.test/b"]
    rapida = extract_contract(urls[1], title: "Rápida")

    with_stubbed_const(Fetcher::ExtractService, :TOTAL_PER_URL_TIMEOUT, 0.2) do
      lenta = Fetcher::ExtractService.new(max_chars: 1000)
      lenta.define_singleton_method(:extract) { |_u| sleep 5 }
      rapida_service = Fetcher::ExtractService.new(max_chars: 1000)
      rapida_service.define_singleton_method(:extract) { |_u| rapida }

      results = [lenta.call(urls[0]), rapida_service.call(urls[1])]

      assert_not_nil results[0][:error], "lenta deveria ter error, veio: #{results[0].inspect}"
      assert_nil results[1][:error], "rápida não deveria ter error: #{results[1].inspect}"
      assert_equal "Rápida", results[1][:title]
    end
  end

  test "TOTAL_PER_URL_TIMEOUT não é menor que CHANNEL_TIMEOUT (teto interno)" do
    assert_operator Fetcher::ExtractService::TOTAL_PER_URL_TIMEOUT, :>=,
                    Fetcher::ExtractService::CHANNEL_TIMEOUT
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
