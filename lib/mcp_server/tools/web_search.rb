# frozen_string_literal: true

module McpServer
  module Tools
    # Sem `require` no topo, pelo mesmo motivo de `platform_search.rb`: arquivo
    # eager-loaded não pode tocar `app/tools/*`, que só carrega depois.
    #
    # Casca sobre `WebSearchTool`. O campo `unresponsive` é o motivo de esta
    # ferramenta existir aqui: o provider searxng do harness descarta
    # `unresponsive_engines`, então "zero resultados" chega ao modelo idêntico
    # nos dois casos — "isso não existe" e "os buscadores que sabiam disso
    # estavam fora". Medido: em 8 de 10 rodadas os dois engines que indexam
    # x.com estavam em CAPTCHA ou suspensos.
    class WebSearch < MCP::Tool
      tool_name "web_search"
      title "Busca web com sinal de engine fora do ar"
      description(
        "Busca na web pelo SearXNG local. Devolve `results` e também `unresponsive`: os engines que " \
        "não responderam. Se `results` vier vazio COM `unresponsive` não vazio, isso NÃO significa que " \
        "o assunto não existe — significa que a busca não aconteceu; diga isso em vez de afirmar " \
        "ausência. Para conteúdo dentro do YouTube, Reddit ou X, use platform_search."
      )

      # `additionalProperties: false` pelo mesmo motivo de `platform_search.rb`:
      # argumento inventado tem que virar erro que o modelo lê, não -32603.
      input_schema(
        properties: {
          query: { type: "string", description: "O que procurar, 1-200 chars" },
          limit: { type: "integer", minimum: 1, maximum: 10, description: "Máximo de resultados (padrão 5)" },
          time_range: { type: "string", enum: %w[day week month year], description: "Recorte de tempo, opcional" }
        },
        required: %w[query],
        additionalProperties: false
      )

      def self.call(query:, limit: nil, time_range: nil, server_context: nil)
        argumentos = { query: query }
        argumentos[:limit] = limit if limit
        argumentos[:time_range] = time_range if time_range
        Responder.from(::WebSearchTool.new.execute(**argumentos))
      end
    end
  end
end
