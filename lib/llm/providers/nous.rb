# frozen_string_literal: true

require "ruby_llm"

module Llm
  module Providers
    # Nous Portal: gateway OpenAI-compatível que serve, entre 354 modelos, os 4
    # gratuitos com tool calling que este projeto usa.
    #
    # Mesma escolha de mãe que a Poolside, e pelo mesmo motivo: herdando da
    # OpenAI, `reasoning_effort` sai no nível de cima do JSON, que é o formato
    # que este gateway entende — medido em 2026-08-07, `reasoning_effort: "none"`
    # zerou o raciocínio (0 tokens em 6 de 6 rodadas).
    #
    # Armadilha conhecida, medida e DESCARTADA para esta stack: o gateway devolve
    # HTTP 403 para `User-Agent: Python-urllib/3.13`. O Faraday manda
    # `Faraday v2.14.1`, que foi medido e passa (HTTP 200), do host e de dentro do
    # container. Se um 403 aparecer aqui um dia, o User-Agent é o primeiro
    # suspeito.
    class Nous < RubyLLM::Providers::OpenAI
      DEFAULT_API_BASE = "https://inference-api.nousresearch.com/v1"

      def api_base
        @config.nous_api_base || DEFAULT_API_BASE
      end

      def headers
        return {} unless @config.nous_api_key

        { "Authorization" => "Bearer #{@config.nous_api_key}" }
      end

      class << self
        def configuration_options
          %i[nous_api_key nous_api_base]
        end

        def configuration_requirements
          %i[nous_api_key]
        end
      end
    end
  end
end
