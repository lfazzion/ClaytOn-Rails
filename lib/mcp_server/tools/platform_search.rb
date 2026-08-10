# frozen_string_literal: true

module McpServer
  module Tools
    # Casca sobre `PlatformSearchTool`. Não reimplementa nada: a lógica, os
    # gabaritos de erro e os testes já vivem na tool do Rails, e uma segunda
    # cópia divergiria dela.
    #
    # Sem `require` no topo: este arquivo é eager-loaded em produção e
    # `app/tools/*` só existe depois do `after_initialize`. A tool do Rails é
    # resolvida dentro de `self.call`, quando a requisição chega.
    class PlatformSearch < MCP::Tool
      tool_name "platform_search"
      title "Busca dentro do YouTube, Reddit e X"
      description(
        "Lê conteúdo DENTRO do YouTube, do Reddit e do X pelo caminho nativo da plataforma, e devolve " \
        "os permalinks. No youtube e no reddit, `query` é o ASSUNTO procurado. No X, `query` é o ASSUNTO " \
        "(busca por frase, ex. 'ruby rails') OU o PERFIL se vier com @ (ex. '@jack' — posts recentes do perfil). " \
        "Buscador web não indexa permalink de plataforma de forma confiável — use esta " \
        "ferramenta, não web_search, quando a pergunta for sobre o que está dentro dessas três."
      )

      # `additionalProperties: false` é obrigatório aqui, não estilo. O gem valida os
      # argumentos contra o schema e depois faz `tool.call(**args, server_context:)`;
      # sem a trava, um parâmetro que o modelo inventou passa a validação e vira
      # `ArgumentError` -> `-32603`, um erro de protocolo que o modelo não consegue
      # corrigir. É a mesma falha que `ToolBase#execute` absorve lá embaixo (medido em
      # 05/08: o chatbot chamou `page_fetch(url:, engine:)`), reintroduzida acima dele.
      input_schema(
        properties: {
          platform: { type: "string", enum: %w[youtube reddit x], description: "Onde ler" },
          query: { type: "string", description: "Assunto (youtube/reddit/x) ou @perfil (x), 1-200 chars" },
          limit: { type: "integer", minimum: 1, maximum: 25, description: "Máximo de resultados (padrão 10)" }
        },
        required: %w[platform query],
        additionalProperties: false
      )

      def self.call(platform:, query:, limit: nil, server_context: nil)
        Responder.from(::PlatformSearchTool.new.execute(platform: platform, query: query, limit: limit))
      end
    end
  end
end
