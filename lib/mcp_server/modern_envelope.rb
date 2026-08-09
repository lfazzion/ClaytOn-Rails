# frozen_string_literal: true

require "base64"

module McpServer
  # O envelope da revisao 2026-07-28, que o gem negocia mas nao serve.
  #
  # Age SOMENTE quando o corpo se declara moderno em `_meta`. E a regra da propria
  # spec: "a request carrying modern per-request `_meta` is served statelessly
  # according to this revision; an `initialize` request selects legacy semantics".
  # Requisicao legada atravessa sem ser tocada — e o unico cliente que existe hoje
  # (mcp==1.28.1 no harness) e legado.
  #
  # O corpo e a fonte da verdade; os cabecalhos sao espelho dele, e divergencia entre
  # os dois e o que `-32020` existe para pegar: um balanceador roteando pelo cabecalho
  # enquanto o servidor executa pelo corpo e a vulnerabilidade que a spec descreve.
  class ModernEnvelope
    CHAVE_VERSAO = "io.modelcontextprotocol/protocolVersion"
    CHAVE_CAPS   = "io.modelcontextprotocol/clientCapabilities"
    CHAVE_SERVER = "io.modelcontextprotocol/serverInfo"

    SUPORTADAS = ["2026-07-28", "2025-11-25"].freeze

    HEADER_MISMATCH   = -32020
    INVALID_PARAMS    = -32602
    VERSAO_NAO_SUPORTADA = -32022

    # Nome que nao cabe em cabecalho ASCII viaja assim, per spec ("Value Encoding").
    SENTINELA_BASE64 = /\A=\?base64\?(.*)\?=\z/

    def initialize(app)
      @app = app
    end

    def call(env)
      bruto = ler_corpo(env)
      corpo = parse(bruto)

      return @app.call(env) unless moderna?(corpo)

      erro = validar(corpo, env)
      return erro if erro

      status, headers, resposta = @app.call(env)
      reescrever(status, headers, resposta, corpo)
    end

    private

    # O corpo e lido aqui e devolvido ao `rack.input` como StringIO: o transporte
    # le de novo depois, e um stream ja consumido chegaria vazio nele.
    def ler_corpo(env)
      entrada = env["rack.input"]
      return "" if entrada.nil?

      bruto = entrada.read.to_s
      env["rack.input"] = StringIO.new(bruto)
      bruto
    end

    def parse(bruto)
      return nil if bruto.empty?

      JSON.parse(bruto)
    rescue JSON::ParserError
      nil
    end

    def moderna?(corpo)
      corpo.is_a?(Hash) && corpo.dig("params", "_meta", CHAVE_VERSAO).present?
    end

    def validar(corpo, env)
      meta = corpo.dig("params", "_meta") || {}
      versao = meta[CHAVE_VERSAO]
      id = corpo["id"]

      unless meta.key?(CHAVE_CAPS)
        return falha(id, INVALID_PARAMS, "Missing required _meta field: #{CHAVE_CAPS}")
      end

      unless SUPORTADAS.include?(versao)
        return falha(id, VERSAO_NAO_SUPORTADA, "Unsupported protocol version",
                     { supported: SUPORTADAS, requested: versao })
      end

      if env["HTTP_MCP_PROTOCOL_VERSION"] != versao
        return falha(id, HEADER_MISMATCH,
                     "Header mismatch: MCP-Protocol-Version #{env['HTTP_MCP_PROTOCOL_VERSION'].inspect} " \
                     "does not match body value #{versao.inspect}")
      end

      if env["HTTP_MCP_METHOD"] != corpo["method"]
        return falha(id, HEADER_MISMATCH,
                     "Header mismatch: Mcp-Method #{env['HTTP_MCP_METHOD'].inspect} " \
                     "does not match body value #{corpo['method'].inspect}")
      end

      validar_nome(corpo, env, id)
    end

    # `Mcp-Name` so e exigido nos metodos que a spec nomeia.
    def validar_nome(corpo, env, id)
      esperado = case corpo["method"]
                 when "tools/call", "prompts/get" then corpo.dig("params", "name")
                 when "resources/read" then corpo.dig("params", "uri")
                 end
      return nil if esperado.nil?

      apresentado = decodificar(env["HTTP_MCP_NAME"])
      return nil if apresentado == esperado

      falha(id, HEADER_MISMATCH,
            "Header mismatch: Mcp-Name #{apresentado.inspect} does not match body value #{esperado.inspect}")
    end

    def decodificar(valor)
      casado = valor.to_s.match(SENTINELA_BASE64)
      return valor if casado.nil?

      Base64.strict_decode64(casado[1]).force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      valor
    end

    def falha(id, codigo, mensagem, dados = nil)
      erro = { code: codigo, message: mensagem }
      erro[:data] = dados if dados
      corpo = { jsonrpc: "2.0", id: id, error: erro }.to_json
      [400, { "content-type" => "application/json" }, [corpo]]
    end

    # O transporte devolve corpo em Array quando stateless+json, e nunca poe
    # content-length (so content-type), entao reescrever e seguro.
    def reescrever(status, headers, resposta, corpo_requisicao)
      texto = +""
      resposta.each { |pedaco| texto << pedaco }
      return [status, headers, [texto]] if texto.empty?

      json = JSON.parse(texto)
      return [status, headers, [texto]] unless json.is_a?(Hash) && json["result"].is_a?(Hash)

      json["result"] = enfeitar(json["result"], corpo_requisicao["method"])
      [status, headers, [json.to_json]]
    rescue JSON::ParserError
      [status, headers, [texto]]
    end

    def enfeitar(resultado, metodo)
      resultado = normalizar_discover(resultado) if metodo == "server/discover"
      resultado["resultType"] ||= "complete"
      meta = resultado["_meta"] || {}
      meta[CHAVE_SERVER] ||= { "name" => McpServer::NAME, "version" => McpServer::VERSION }
      resultado["_meta"] = meta
      resultado
    end

    # O gem devolve `serverInfo` no topo do result (server.rb:721-728). A spec exige
    # em `_meta`, e pede tambem as dicas de cache, que o proprio gem declara nao emitir
    # aqui (server.rb:717-718).
    def normalizar_discover(resultado)
      info = resultado.delete("serverInfo")
      if info
        meta = resultado["_meta"] || {}
        meta[CHAVE_SERVER] = info
        resultado["_meta"] = meta
      end
      resultado["ttlMs"] ||= McpServer::TTL_MS
      resultado["cacheScope"] ||= McpServer::CACHE_SCOPE
      resultado
    end
  end
end
