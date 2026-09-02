# frozen_string_literal: true

require "test_helper"

# Todo teste aqui verifica RECUSA ou NEGOCIAÇÃO: um teste que só vê 200 não
# distingue "servidor certo" de "servidor que responde qualquer coisa".
class McpControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "token-mcp-de-teste-1234567890"

  setup do
    @anterior = ENV["INTERNAL_MCP_TOKEN"]
    ENV["INTERNAL_MCP_TOKEN"] = TOKEN
    Rails.cache.clear
    # OBRIGATORIO. ActionDispatch::IntegrationTest manda HTTP_HOST=www.example.com
    # em todo request (actionpack integration.rb:92,163,258), e a guarda de DNS
    # rebinding do transporte checa o Host na PRIMEIRA linha de handle_request
    # (streamable_http_transport.rb:157-159) contra ["127.0.0.1","::1","localhost"]
    # (:150) — sem isto, todo request util volta 403 e ate o CONTROLE do GET 405
    # falha. Medido: www.example.com POST => 403; 127.0.0.1 POST => 200.
    # A alternativa errada seria passar allowed_hosts: no transporte, que afrouxaria
    # producao para fazer o teste passar. O caminho vivo (Host "127.0.0.1:3000")
    # ja e aceito, porque a guarda tira a porta antes de comparar.
    host! "127.0.0.1"
  end

  teardown { ENV["INTERNAL_MCP_TOKEN"] = @anterior }

  def headers(token = TOKEN)
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream" }
  end

  # As CHAVES em volta do corpo sao obrigatorias em toda chamada de `rpc`, e nao
  # estilo: o metodo declara o keyword `hdrs:`, entao no Ruby 3+ um
  # `rpc(jsonrpc: "2.0", ...)` sem chaves e lido como lista de KEYWORDS, nao como
  # Hash posicional — `body` fica sem valor e estoura
  # `ArgumentError: wrong number of arguments (given 0, expected 1)`.
  def rpc(body, hdrs: headers)
    post "/mcp", params: body.to_json, headers: hdrs
    JSON.parse(response.body)
  end

  test "era legada: initialize negocia 2025-11-25, que e o que o cliente do Hermes fala" do
    corpo = rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "hermes", version: "1.28.1" }
    } })

    assert_response :success
    assert_equal "2025-11-25", corpo.dig("result", "protocolVersion")
  end

  # Este teste discrimina de verdade: Rack::Headers#[] faz downcase na busca
  # (rack-3.2.5 headers.rb:234), entao ele enxerga o "mcp-session-id" minusculo que
  # o transporte gravaria (:876) se stateless: true fosse desligado. E o unico
  # teste que segura a afirmacao central do plano — o reader nunca abre o GET.
  test "era legada: nenhuma sessao e mintada, entao o cliente nunca abre o stream GET" do
    rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "hermes", version: "1.28.1" }
    } })

    assert_response :success
    assert_nil response.headers["Mcp-Session-Id"]
  end

  test "tools/list devolve as duas ferramentas" do
    corpo = rpc({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })

    nomes = corpo.dig("result", "tools").map { |t| t["name"] }
    assert_equal %w[platform_search web_search], nomes.sort
  end

  test "era moderna: server/discover anuncia 2026-07-28" do
    corpo_req = { jsonrpc: "2.0", id: 3, method: "server/discover", params: {
      _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
               "io.modelcontextprotocol/clientCapabilities" => {} }
    } }
    post "/mcp", params: corpo_req.to_json,
                 headers: headers.merge("MCP-Protocol-Version" => "2026-07-28",
                                        "Mcp-Method" => "server/discover")

    assert_response :success
    assert_includes JSON.parse(response.body).dig("result", "supportedVersions"), "2026-07-28"
  end

  # CONTROLE: corpo moderno SEM os cabeçalhos é requisição malformada, não legada.
  # A spec lista cabeçalho obrigatório ausente entre as condições de -32020.
  test "CONTROLE: corpo com _meta moderno e sem cabecalho vira -32020" do
    corpo = rpc({ jsonrpc: "2.0", id: 4, method: "server/discover", params: {
      _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
               "io.modelcontextprotocol/clientCapabilities" => {} }
    } })

    assert_response :bad_request
    assert_equal(-32020, corpo.dig("error", "code"))
  end

  # CONTROLE 1: sem token nao passa. Sem isto, os testes acima nao distinguem
  # "autenticado" de "aberto para qualquer um".
  test "CONTROLE: token errado devolve 401 e nenhuma ferramenta" do
    post "/mcp", params: { jsonrpc: "2.0", id: 4, method: "tools/list", params: {} }.to_json,
                 headers: headers("token-errado")

    assert_response :unauthorized
    refute_match(/platform_search/, response.body)
  end

  # CONTROLE 2: sem token configurado o endpoint se recusa a existir, em vez de
  # abrir. Mesmo contrato do /internal/extract.
  test "CONTROLE: sem INTERNAL_MCP_TOKEN o endpoint devolve 503" do
    ENV["INTERNAL_MCP_TOKEN"] = ""
    post "/mcp", params: { jsonrpc: "2.0", id: 5, method: "tools/list", params: {} }.to_json, headers: headers

    assert_response :service_unavailable
  end

  # CONTROLE 3: o GET nao e um caminho valido nesta revisao.
  test "CONTROLE: GET no endpoint devolve 405" do
    get "/mcp", headers: headers
    assert_response :method_not_allowed
  end

  # CONTROLE 4: Origin de outra origem e recusado (defesa contra DNS rebinding,
  # que a spec exige do transporte). Cliente sem Origin — o caso do Hermes —
  # continua passando, senao esta guarda quebraria o consumidor real.
  test "CONTROLE: Origin de terceiro e recusado, e ausencia de Origin passa" do
    post "/mcp", params: { jsonrpc: "2.0", id: 6, method: "tools/list", params: {} }.to_json,
                 headers: headers.merge("Origin" => "https://evil.example")
    assert_response :forbidden

    post "/mcp", params: { jsonrpc: "2.0", id: 7, method: "tools/list", params: {} }.to_json, headers: headers
    assert_response :success
  end

  # CONTROLE 5: o unico efeito observavel de `enable_json_response: true` e o
  # Accept exigido do cliente — :461 do transporte escolhe entre
  # ["application/json"] e ["application/json","text/event-stream"], e :671 exige
  # TODOS os tipos da lista escolhida. Sem este teste a flag nao e medida por
  # nada: sob `stateless: true` o corpo ja volta JSON com ela desligada (:908),
  # entao todos os testes acima passam dos dois jeitos. Medido com o controle que
  # reprova — com a flag em `false` este mesmo POST devolve 406 "Accept header
  # must include application/json and text/event-stream".
  test "CONTROLE: cliente que aceita so application/json e atendido" do
    post "/mcp", params: { jsonrpc: "2.0", id: 8, method: "tools/list", params: {} }.to_json,
                 headers: { "Authorization" => "Bearer #{TOKEN}", "Content-Type" => "application/json",
                            "Accept" => "application/json" }

    assert_response :success
    assert_includes JSON.parse(response.body).dig("result", "tools").map { |t| t["name"] }, "web_search"
  end

  test "dois handles MCP seguidos na mesma thread: o segundo comeca com contador zerado" do
    SearchApiRouter.reset_paid_search_count!
    SearchApiRouter.increment_paid_search_count!
    assert_equal 1, SearchApiRouter.paid_search_count

    post "/mcp", params: { jsonrpc: "2.0", id: 9, method: "tools/list", params: {} }.to_json, headers: headers
    assert_response :success

    assert_equal 0, SearchApiRouter.paid_search_count
  end
end
