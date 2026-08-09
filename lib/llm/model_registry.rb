# frozen_string_literal: true

module Llm
  # Consulta e atualização do registry de modelos do RubyLLM.
  #
  # O gem embarca um models.json congelado no release, então a lista envelhece
  # sozinha: um slug aposentado pelo provedor continua nela, e um modelo novo
  # nunca aparece. refresh! busca a lista viva de cada provedor configurado.
  class ModelRegistry
    PROVIDER = 'openrouter'

    FreeModel = Struct.new(:id, :context_window, keyword_init: true)

    class << self
      # Retorna o total de modelos após a atualização.
      def refresh!
        RubyLLM.models.refresh!.all.size
      end

      def free(tools_only: true)
        live_rows.filter_map do |row|
          next if tools_only && !supports_tools?(row)
          next unless free?(row)

          FreeModel.new(id: row['id'], context_window: row['context_length'])
        end
      end

      # Resposta crua da OpenRouter, reaproveitando a conexão configurada do gem.
      #
      # Duas informações se perdem no Model::Info: o parser do gem só guarda preço
      # positivo, então tanto "0" (gratuito) quanto "-1" (tarifa variável do
      # openrouter/auto) viram nil; e refresh! ainda funde a resposta com o
      # catálogo models.dev, que traz modelos sem pricing e fora de serviço.
      def live_rows
        provider = RubyLLM::Provider.providers[PROVIDER.to_sym].new(RubyLLM.config)
        Array(provider.connection.get('models').body['data'])
      end

      def free?(row)
        pricing = row['pricing'] || {}
        %w[prompt completion].all? do |key|
          value = pricing[key]
          !value.nil? && value.to_f.zero?
        end
      end

      def supports_tools?(row)
        Array(row['supported_parameters']).include?('tools')
      end
    end
  end
end
