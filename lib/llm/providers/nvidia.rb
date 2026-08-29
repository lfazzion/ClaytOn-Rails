# frozen_string_literal: true

require "ruby_llm"

module Llm
  module Providers
    # NVIDIA NIM API — gateway OpenAI-compatível para modelos como kimi-k3.
    #
    # Herda de RubyLLM::Providers::OpenAI porque o endpoint é OpenAI-compatível.
    # Mesma escolha que Poolside e Nous: a gem ResolveLLM injeta o provider
    # pelo slug da classe, e o endpoint NVIDIA aceita o formato padrão.
    class Nvidia < RubyLLM::Providers::OpenAI
      DEFAULT_API_BASE = "https://integrate.api.nvidia.com/v1"

      def api_base
        @config.nvidia_api_base || DEFAULT_API_BASE
      end

      def headers
        return {} unless @config.nvidia_api_key

        { "Authorization" => "Bearer #{@config.nvidia_api_key}" }
      end

      class << self
        def configuration_options
          %i[nvidia_api_key nvidia_api_base]
        end

        def configuration_requirements
          %i[nvidia_api_key]
        end
      end
    end
  end
end
