# frozen_string_literal: true

require "ruby_llm"

module Llm
  module Providers
    # Rota direta da Poolside, sem passar pela OpenRouter.
    #
    # Herda de RubyLLM::Providers::OpenAI porque o endpoint é OpenAI-compatível.
    # NÃO herda da classe OpenRouter da gem de propósito: aquela sobrescreve o
    # payload para `reasoning: { effort: ... }` aninhado, e esta API não usa esse
    # formato.
    #
    # `slug` não é declarado: a gem o deriva do nome da classe
    # (`Poolside` -> "poolside"), e é esse valor que precisa casar, como String,
    # com o campo `provider` dos Model::Info registrados no initializer. Mudar o
    # nome da classe quebra a resolução do modelo.
    #
    # Não existe aqui nenhum ajuste de raciocínio: medido em 2026-08-07, esta
    # rota ignora `reasoning_effort` (a doc oficial confirma que ele não é
    # suportado nos modelos Poolside) e recusa `none` com HTTP 400. Quem desliga
    # o raciocínio é o elo, via `with_params` — ver Llm::ModelChain.
    class Poolside < RubyLLM::Providers::OpenAI
      DEFAULT_API_BASE = "https://inference.poolside.ai/v1"

      def api_base
        @config.poolside_api_base || DEFAULT_API_BASE
      end

      # Sem chave o construtor já teria levantado ConfigurationError
      # (`ensure_configured!`), então esta guarda é cinto e suspensório para
      # quem zerar a chave depois de construído — não é o caminho normal.
      def headers
        return {} unless @config.poolside_api_key

        { "Authorization" => "Bearer #{@config.poolside_api_key}" }
      end

      class << self
        def configuration_options
          %i[poolside_api_key poolside_api_base]
        end

        def configuration_requirements
          %i[poolside_api_key]
        end
      end
    end
  end
end
