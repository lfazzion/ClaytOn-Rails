# frozen_string_literal: true

require "test_helper"

# Sem `require` dos arquivos de lib/mcp_server: eles são geridos pelo Zeitwerk, e
# requerer à mão um arquivo autoloadable é o jeito clássico de acabar com duas
# cópias da mesma constante. Mencionar o nome já dispara o autoload.
class McpServerToolsTest < ActiveSupport::TestCase
  test "platform_search declara nome e schema com as tres plataformas" do
    schema = McpServer::Tools::PlatformSearch.to_h
    assert_equal "platform_search", schema[:name]
    assert_equal %w[youtube reddit x], schema[:inputSchema][:properties][:platform][:enum]
    assert_equal %w[platform query], schema[:inputSchema][:required]
  end

  # F2 do plano v2 (30/08/2026): a tool MCP `web_search` expoe o classificador
  # `type` com enum fixo e `limit` com teto 5. Quem consome e o modelo do perfil,
  # que le esses campos do schema. Travado aqui — se algum dia o enum perder um
  # valor ou o teto subir, o modelo para de conseguir classificar / cota estoura.
  test "web_search declara schema com type enum e limit maximum 5" do
    schema = McpServer::Tools::WebSearch.to_h
    assert_equal "web_search", schema[:name]
    assert_equal %w[news entity academic factual code auto],
                 schema[:inputSchema][:properties][:type][:enum]
    assert_equal 5, schema[:inputSchema][:properties][:limit][:maximum]
  end

  test "sucesso vira conteudo de texto com structuredContent e sem isError" do
    ::PlatformSearchTool.any_instance.stubs(:execute).returns(
      status: :success, data: { platform: "x", query: "EXM7777", count: 1, results: [{ "url" => "https://x.com/EXM7777/status/1" }] }
    )

    resposta = McpServer::Tools::PlatformSearch.call(platform: "x", query: "EXM7777", limit: 1).to_h

    assert_equal false, resposta[:isError]
    assert_equal "x", resposta[:structuredContent][:platform]
    assert_match(/EXM7777/, resposta[:content].first[:text])
  end

  # CONTROLE: erro da tool vira isError com o motivo legivel, NUNCA lista vazia —
  # o modelo leria lista vazia como "nao existe nada sobre isso".
  test "CONTROLE: erro vira isError true com o motivo" do
    ::PlatformSearchTool.any_instance.stubs(:execute).returns(
      status: :error, reason: "sessão de x.com ausente ou expirada"
    )

    resposta = McpServer::Tools::PlatformSearch.call(platform: "x", query: "EXM7777").to_h

    assert_equal true, resposta[:isError]
    assert_match(/sessão de x\.com/, resposta[:content].first[:text])
    assert_nil resposta[:structuredContent]
  end

  # O caso PARCIAL: vieram resultados E engines cairam. E a unica forma em que
  # `unresponsive` chega nao-vazio junto de sucesso — lista vazia com engine fora
  # vira `error(...)` dentro do proprio `run` (web_search_tools.rb:58-64), e a
  # Task 3 nao muda esse ramo. Stub com data vazia + unresponsive seria um
  # contrato que a tool nunca produz.
  test "web_search repassa unresponsive ao modelo no caso parcial" do
    ::WebSearchTool.any_instance.stubs(:execute).returns(
      status: :success,
      data: [{ title: "Is ruby really slow?", url: "https://reddit.com/r/ruby/x", content: "ruby", engine: "duckduckgo" }],
      unresponsive: %w[brave]
    )

    resposta = McpServer::Tools::WebSearch.call(query: "ruby performance").to_h

    assert_equal %w[brave], resposta[:structuredContent][:unresponsive]
    assert_equal 1, resposta[:structuredContent][:results].size
  end

  # CONTROLE: lista vazia COM engine fora chega como isError, nao como sucesso
  # com results vazio. E o que a description da tool promete ao modelo, e o
  # caminho que de fato acontece.
  test "CONTROLE: busca que nao aconteceu vira isError, nao sucesso vazio" do
    ::WebSearchTool.any_instance.stubs(:execute).returns(
      status: :error, reason: "busca não aconteceu: engines fora do ar (brave, duckduckgo)"
    )

    resposta = McpServer::Tools::WebSearch.call(query: "site:x.com EXM7777").to_h

    assert_equal true, resposta[:isError]
    assert_match(/engines fora do ar/, resposta[:content].first[:text])
  end

  # CONTROLE: quem nao tem a chave irma nao ganha um `unresponsive` inventado.
  # Sem isto, o Responder poderia estar cravando o campo em todo resultado.
  test "CONTROLE: platform_search nao ganha campo unresponsive" do
    ::PlatformSearchTool.any_instance.stubs(:execute).returns(
      status: :success, data: { platform: "reddit", count: 0, results: [] }
    )

    estruturado = McpServer::Tools::PlatformSearch.call(platform: "reddit", query: "ruby").to_h[:structuredContent]

    refute estruturado.key?(:unresponsive)
  end
end
