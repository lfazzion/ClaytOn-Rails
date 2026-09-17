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

        JSON.parse(cleaned).map(&:symbolize_keys)
      rescue JSON::ParserError => e
        Rails.logger.error "[ProfileClassifier] JSON inválido do LLM: #{e.message}"
        []
      end
    end
  end
end
