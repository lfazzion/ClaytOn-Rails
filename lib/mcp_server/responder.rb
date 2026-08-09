# frozen_string_literal: true

module McpServer
  # Traduz o retorno das tools do Rails (`{status:, data:}` / `{status:, reason:}`)
  # para o contrato de resultado do MCP.
  #
  # Falha vira `isError: true` com o motivo, não erro JSON-RPC: o modelo consegue
  # se corrigir com o motivo em mãos, e a spec reserva o erro de protocolo para o
  # que ele não consegue consertar. Nunca lista vazia — o modelo leria "não existe
  # nada sobre isso" e responderia isso ao usuário.
  module Responder
    def self.from(resultado)
      if resultado[:status] == :error
        return MCP::Tool::Response.new([{ type: "text", text: resultado[:reason].to_s }], error: true)
      end

      estruturado = estruturar(resultado)
      MCP::Tool::Response.new(
        [{ type: "text", text: JSON.pretty_generate(estruturado) }],
        structured_content: estruturado
      )
    end

    # `unresponsive` chega como chave IRMÃ de `data` (ver o plano do WebSearchTool:
    # aninhá-la dentro de `data` quebraria os asserts existentes). Aqui ela é
    # dobrada para dentro do conteúdo estruturado, porque é o modelo que precisa
    # vê-la. Quem não manda a chave não ganha o campo inventado.
    def self.estruturar(resultado)
      return resultado[:data] unless resultado.key?(:unresponsive)

      { results: resultado[:data], unresponsive: resultado[:unresponsive] }
    end
  end
end
