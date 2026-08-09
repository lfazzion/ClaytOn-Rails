# frozen_string_literal: true

require "test_helper"

# Prova de portao: o gem carrega no Ruby 4.0 e expoe a revisao que o design assume.
# Sem isto, todo o resto do plano assenta em suposicao.
#
# `require "mcp"` avalia SO cinco arquivos de stdlib (mcp.rb:3-7); Server, Tool e o
# transporte sao `autoload` de Ruby, e json_schemer — a unica dependencia de runtime
# do gem — so entra por MCP::Tool -> tool/input_schema.rb -> tool/schema.rb:4. Por
# isso cada teste aqui TOCA a constante: mencionar o nome e o que dispara o autoload.
class McpServerGemBootTest < ActiveSupport::TestCase
  test "o gem carrega e declara 2026-07-28 como versao estavel mais recente" do
    assert_equal "2026-07-28", MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION
  end

  test "a versao legada que o cliente do Hermes fala esta na lista de suportadas" do
    assert_includes MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, "2025-11-25"
  end

  test "as classes que o plano usa carregam no Ruby 4.0" do
    assert MCP::Server
    assert MCP::Tool
    assert MCP::Tool::Response
    assert MCP::Server::Transports::StreamableHTTPTransport
  end

  # json_schemer e a dependencia de runtime do gem, e so e exercitada quando um
  # schema e CONSTRUIDO — `Schema#initialize` chama `validate_schema!` -> `schemer`
  # -> `JSONSchemer.schema(...)` (tool/schema.rb:58-63,143). Sem construir, o
  # portao mediria require, nao compatibilidade.
  test "json_schemer valida um schema no Ruby 4.0" do
    schema = MCP::Tool::InputSchema.new({
      properties: { plataforma: { type: "string" } },
      required: ["plataforma"]
    })

    assert_equal "object", schema.to_h[:type]
  end

  # CONTROLE: uma versao que nao existe nao pode aparecer como suportada, senao o
  # assert acima passaria por a lista conter qualquer coisa.
  test "CONTROLE: versao inventada nao consta" do
    refute_includes MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, "1900-01-01"
  end

  # CONTROLE: schema invalido tem que estourar — `validate_schema!` levanta
  # ArgumentError ("Invalid JSON Schema: ...", tool/schema.rb:166-168). Se o
  # construtor aceitasse qualquer coisa, o teste acima nao mediria validacao.
  test "CONTROLE: schema invalido e recusado" do
    assert_raises(ArgumentError) do
      MCP::Tool::InputSchema.new({ properties: { a: { type: "nao-existe" } }, required: ["a"] })
    end
  end
end
