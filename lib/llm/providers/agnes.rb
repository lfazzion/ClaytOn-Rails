# frozen_string_literal: true

require "ruby_llm"

module Llm
  module Providers
    # Agnes AI: gateway OpenAI-compatível (https://apihub.agnes-ai.com/v1).
    #
    # Herda de RubyLLM::Providers::OpenAI porque o endpoint é OpenAI-compatível,
    # então `reasoning_effort` sai no nível de cima do JSON — o formato que esta
    # API entende. Mesma escolha de mãe que Nous/Poolside neste repo.
    #
    # Medido em 30/08/2026 (probe real com a chave do .env):
    #   * O modelo `agnes-2.5-flash` RACIOCINA POR PADRÃO. Chamada sem
    #     `reasoning_effort` com `max_tokens` apertado devolve `content: ""` e
    #     `reasoning_content` preenchido. Com `reasoning_effort: "none"` responde
    #     com conteúdo (ex.: 2-3 tokens). Lição idêntica à do Nous
    #     (model_chain.rb / nous.rb).
    #   * Vocabulário ACEITO de effort (HTTP 200, content preenchido com
    #     max_tokens pequeno): `none`, `low`, `medium`, `high`. Fora disso, o
    #     elo é cortado/normalizado pela ModelChain (PROVIDER_EFFORTS[:agnes]).
    #   * `agnes-2.5-pro` devolve HTTP 403 (conta sem saldo para pro) — NÃO usar.
    class Agnes < RubyLLM::Providers::OpenAI
      DEFAULT_API_BASE = "https://apihub.agnes-ai.com/v1"

      def api_base
        @config.agnes_api_base || DEFAULT_API_BASE
      end

      # Sem chave o construtor já teria levantado ConfigurationError
      # (`ensure_configured!`), então esta guarda é cinto e suspensório para
      # quem zerar a chave depois de construído — não é o caminho normal.
      def headers
        return {} unless @config.agnes_api_key

        { "Authorization" => "Bearer #{@config.agnes_api_key}" }
      end

      class << self
        def configuration_options
          %i[agnes_api_key agnes_api_base]
        end

        def configuration_requirements
          %i[agnes_api_key]
        end
      end
    end
  end
end
