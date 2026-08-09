# frozen_string_literal: true

require "mcp"

module McpServer
  NAME    = "cleitin"
  VERSION = "1.0.0"

  # Dicas de cache exigidas pela revisao 2026-07-28 em `tools/list`. Passadas ao
  # `MCP::Server.new`, valem para as duas eras; cliente legado ignora campo extra.
  # 5 minutos porque a lista de ferramentas so muda em deploy.
  TTL_MS      = 300_000
  CACHE_SCOPE = "public"

  INSTRUCTIONS = <<~TEXTO
    Ferramentas de leitura do cleitin-bot. `platform_search` lê dentro do YouTube, do
    Reddit e do X pelo caminho nativo; `web_search` busca no resto da web e informa
    quais engines não responderam. Resultado vazio com `unresponsive` não vazio
    significa que a busca não aconteceu, não que o assunto não existe.
  TEXTO

  class << self
    # `stateless: true`: sem sessão, GET responde 405, cada requisição é
    # independente. É o modelo da revisão 2026-07-28, e resolve de graça o
    # caminho legado — o cliente do harness só abre o stream GET quando recebe
    # `Mcp-Session-Id`, e aqui nunca recebe.
    #
    # `enable_json_response: true` NÃO muda o formato do corpo: sob
    # `stateless: true` a resposta já é JSON com a flag desligada, porque o ramo
    # SSE exige `session_id && !@stateless && !@enable_json_response`
    # (streamable_http_transport.rb:908). O único efeito observável é o `Accept`
    # exigido do cliente — com a flag basta `application/json`, sem ela o
    # transporte exige TAMBÉM `text/event-stream` e devolve 406 (:461 escolhe a
    # lista, :143 e :142 as definem, :671 exige todos os tipos dela). Fica ligada
    # para não obrigar o cliente a aceitar um stream que este servidor nunca abre.
    # Quem mede isso é o CONTROLE 5 de test/controllers/mcp_controller_test.rb.
    def transport
      @transport ||= MCP::Server::Transports::StreamableHTTPTransport.new(
        server,
        stateless: true,
        enable_json_response: true
      )
    end

    def server
      @server ||= MCP::Server.new(
        name: NAME,
        version: VERSION,
        instructions: INSTRUCTIONS,
        tools: [Tools::PlatformSearch, Tools::WebSearch],
        ttl_ms: TTL_MS,
        cache_scope: CACHE_SCOPE
      )
    end

    # O que o controller chama. A camada moderna na frente, o transporte atras.
    def app
      @app ||= ModernEnvelope.new(transport)
    end
  end
end
