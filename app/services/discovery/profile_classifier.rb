# frozen_string_literal: true

module Discovery
  class ProfileClassifier
    MAX_BATCH_SIZE = 30

    class << self
      def classify(handles, source_profile:)
        return [] if handles.empty?

        batch = handles.first(MAX_BATCH_SIZE)
        prompt = Llm::PromptLoader.load('discovery', handles: batch)

        response = AiRouter.complete(prompt, context: :background)
        parse_classification(response.content, source_profile)
      rescue Llm::BaseClient::QuotaExceededError => e
        Rails.logger.warn "[ProfileClassifier] Quota esgotada, adiando classificação: #{e.message}"
        []
      end

      private

      def parse_classification(raw_response, _source_profile)
        if raw_response.blank?
          Rails.logger.warn '[ProfileClassifier] Resposta vazia ou nula do LLM'
          return []
        end

        cleaned = raw_response.strip
                              .gsub(/\A```json\s*/, '')
                              .gsub(/\A```\s*/, '')
                              .gsub(/\s*```\z/, '')
                              .strip

        parsed = JSON.parse(cleaned)

        if parsed.nil?
          Rails.logger.warn '[ProfileClassifier] Resposta vazia ou nula do LLM'
          return []
        end

if parsed.is_a?(Hash)
list_key =%w[results data items profiles].find { |k| parsed[k].is_a?(Array) }
          if list_key
parsed = parsed[list_key]
          else
Rails.logger.warn "[ProfileClassifier] Formato inesperado doLLM (objeto sem lista): #{parsed.keys.inspect}"
            return []
          end
        end

        unless parsed.is_a?(Array)
          Rails.logger.warn "[ProfileClassifier] Formato inesperado do LLM (esperava Array, recebeu #{parsed.class})"
          return []
        end

        parsed.map(&:symbolize_keys)
      rescue JSON::ParserError => e
        Rails.logger.error "[ProfileClassifier] JSON inválido do LLM: #{e.message}"
        []
      end
    end
  end
end
