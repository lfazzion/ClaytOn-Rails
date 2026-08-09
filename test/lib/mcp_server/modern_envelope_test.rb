# frozen_string_literal: true

require "test_helper"
# O teste usa Base64 na linha do sentinela ANTES de qualquer referencia que carregue a
# camada (que o requer por conta). Conferido no container: `require "base64"` funciona
# no Ruby 4.0.6, apesar de ser gem empacotada desde a 3.4.
require "base64"

# A camada so age quando a requisicao se declara moderna pelo `_meta` do corpo, que e
# a regra da propria spec ("a request carrying modern per-request _meta is served
# statelessly according to this revision; an initialize request selects legacy").
# Cada teste de era moderna tem um par legado: uma camada que agisse nos dois quebraria
# o unico cliente que existe hoje.
class McpServerModernEnvelopeTest < ActiveSupport::TestCase
  META = "io.modelcontextprotocol/protocolVersion"
  CAPS = "io.modelcontextprotocol/clientCapabilities"
  INFO = "io.modelcontextprotocol/clientInfo"

  # `HTTP_ACCEPT` é obrigatório e o `env_for` não o põe. O transporte valida o Accept
  # antes de qualquer outra coisa no POST (`streamable_http_transport.rb:461-463`) e
  # devolve `406` direto quando o cabeçalho é `nil` (`:664-666`) — sem chegar ao corpo.
  # O valor é o mesmo que o cliente do harness manda; com `enable_json_response: true`
  # bastaria `application/json` (`REQUIRED_POST_ACCEPT_TYPES_JSON`, `:143`), mas o teste
  # existe para provar o cliente real, não o mínimo aceitável.
  def chamar(corpo, cabecalhos = {})
    env = Rack::MockRequest.env_for(
      "/mcp",
      method: "POST",
      input: corpo.to_json,
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_HOST" => "127.0.0.1"
    )
    cabecalhos.each { |k, v| env[k] = v }
    status, _headers, body = McpServer.app.call(env)
    corpo_texto = +""
    body.each { |p| corpo_texto << p }
    [status, (JSON.parse(corpo_texto) if corpo_texto.present?)]
  end

  def moderno(metodo, params = {}, versao: "2026-07-28")
    { jsonrpc: "2.0", id: 1, method: metodo,
      params: params.merge(_meta: { META => versao, CAPS => {}, INFO => { name: "p", version: "0" } }) }
  end

  def cabecalhos_de(metodo, nome = nil, versao: "2026-07-28")
    h = { "HTTP_MCP_PROTOCOL_VERSION" => versao, "HTTP_MCP_METHOD" => metodo }
    h["HTTP_MCP_NAME"] = nome if nome
    h
  end

  test "era moderna: resultado ganha resultType complete e serverInfo" do
    status, corpo = chamar(moderno("tools/list"), cabecalhos_de("tools/list"))

    assert_equal 200, status
    assert_equal "complete", corpo.dig("result", "resultType")
    assert_equal "cleitin", corpo.dig("result", "_meta", "io.modelcontextprotocol/serverInfo", "name")
  end

  test "era moderna: tools/list carrega as dicas de cache" do
    _status, corpo = chamar(moderno("tools/list"), cabecalhos_de("tools/list"))

    assert_kind_of Integer, corpo.dig("result", "ttlMs")
    assert_includes %w[public private], corpo.dig("result", "cacheScope")
  end

  test "era moderna: server/discover e normalizado para a forma da spec" do
    _status, corpo = chamar(moderno("server/discover"), cabecalhos_de("server/discover"))
    resultado = corpo["result"]

    assert_equal "complete", resultado["resultType"]
    assert_includes resultado["supportedVersions"], "2026-07-28"
    assert_equal "cleitin", resultado.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
    assert_equal McpServer::TTL_MS, resultado["ttlMs"]
    assert_equal McpServer::CACHE_SCOPE, resultado["cacheScope"]
    refute resultado.key?("serverInfo"), "serverInfo no topo e a forma antiga; a spec exige dentro de _meta"
  end

  test "CONTROLE: cabecalho de versao divergente do corpo vira -32020" do
    status, corpo = chamar(moderno("tools/list"), cabecalhos_de("tools/list", versao: "2025-11-25"))

    assert_equal 400, status
    assert_equal(-32020, corpo.dig("error", "code"))
  end

  test "CONTROLE: Mcp-Method divergente do corpo vira -32020" do
    status, corpo = chamar(moderno("tools/list"), cabecalhos_de("tools/call"))

    assert_equal 400, status
    assert_equal(-32020, corpo.dig("error", "code"))
  end

  test "CONTROLE: Mcp-Name divergente do params.name vira -32020" do
    corpo_req = moderno("tools/call", { name: "platform_search", arguments: { platform: "reddit", query: "x" } })
    status, corpo = chamar(corpo_req, cabecalhos_de("tools/call", "web_search"))

    assert_equal 400, status
    assert_equal(-32020, corpo.dig("error", "code"))
  end

  # Unico teste do arquivo que atravessa ate a tool de verdade: os outros param na
  # camada ou em `tools/list`. Sem o stub, `PlatformSearchTool` chama
  # `Fetcher::Channels::Reddit.search` -> `BrowserSession` -> Chrome, e o WebMock
  # derruba com `NetConnectNotAllowedError`.
  test "Mcp-Name em base64 e decodificado antes de comparar" do
    ::PlatformSearchTool.any_instance.stubs(:execute).returns(
      status: :success, data: { platform: "reddit", count: 0, results: [] }
    )
    nome = "=?base64?#{Base64.strict_encode64('platform_search')}?="
    corpo_req = moderno("tools/call", { name: "platform_search", arguments: { platform: "reddit", query: "ruby" } })
    status, _corpo = chamar(corpo_req, cabecalhos_de("tools/call", nome))

    assert_equal 200, status
  end

  # CONTROLE do de cima: prova que a camada decodifica E COMPARA, em vez de
  # decodificar e ignorar. Sem ele, uma implementacao que so tirasse o sentinela
  # sem conferir o valor passaria no teste anterior.
  test "CONTROLE: Mcp-Name em base64 que decodifica para outro nome vira -32020" do
    ::PlatformSearchTool.any_instance.stubs(:execute).never
    nome = "=?base64?#{Base64.strict_encode64('web_search')}?="
    corpo_req = moderno("tools/call", { name: "platform_search", arguments: { platform: "reddit", query: "ruby" } })
    status, corpo = chamar(corpo_req, cabecalhos_de("tools/call", nome))

    assert_equal 400, status
    assert_equal(-32020, corpo.dig("error", "code"))
  end

  test "CONTROLE: _meta sem clientCapabilities vira -32602" do
    corpo_req = { jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: { META => "2026-07-28" } } }
    status, corpo = chamar(corpo_req, cabecalhos_de("tools/list"))

    assert_equal 400, status
    assert_equal(-32602, corpo.dig("error", "code"))
  end

  test "CONTROLE: versao nao suportada vira -32022 listando as suportadas" do
    status, corpo = chamar(moderno("tools/list", {}, versao: "1900-01-01"),
                           cabecalhos_de("tools/list", versao: "1900-01-01"))

    assert_equal 400, status
    assert_equal(-32022, corpo.dig("error", "code"))
    assert_includes corpo.dig("error", "data", "supported"), "2026-07-28"
    assert_equal "1900-01-01", corpo.dig("error", "data", "requested")
  end

  # ── O par legado de cada regra acima. Uma camada que agisse aqui quebraria o reader.
  test "CONTROLE: era legada passa intocada, sem resultType e sem exigir cabecalho" do
    status, corpo = chamar(
      { jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "hermes", version: "1.28.1" } } }
    )

    assert_equal 200, status
    assert_equal "2025-11-25", corpo.dig("result", "protocolVersion")
    refute corpo["result"].key?("resultType"), "resultType na era legada e invencao nossa"
  end

  test "CONTROLE: tools/list legado nao exige Mcp-Method e nao ganha resultType" do
    status, corpo = chamar({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })

    assert_equal 200, status
    assert_equal 2, corpo.dig("result", "tools").size
    refute corpo["result"].key?("resultType")
  end
end
