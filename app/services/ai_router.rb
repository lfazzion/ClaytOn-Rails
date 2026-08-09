# frozen_string_literal: true

class AiRouter
  class << self
    def complete(prompt, context: :interactive, tools: [])
      system_msg, user_msg = extract_messages(prompt)

      client = select_client(context)
      Rails.logger.info "[AiRouter] Roteando para #{client.class.name} (ctx: #{context})"

      client.complete(user_msg, system: system_msg, tools: tools)
    rescue Llm::BaseClient::QuotaExceededError, RubyLLM::RateLimitError,
           RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError,
           RubyLLM::PaymentRequiredError => e
      fallback(user_msg, system_msg, tools, e)
    end

    private

    def extract_messages(prompt)
      if prompt.is_a?(Hash)
        [prompt[:system], prompt[:user]]
      else
        [nil, prompt.to_s]
      end
    end

    def select_client(context)
      case context
      when :background
        Llm::GeminiBackgroundClient.new
      when :interactive
        Llm::GeminiInteractiveClient.new
      else
        raise ArgumentError, "Contexto desconhecido: #{context}. Use :background ou :interactive"
      end
    end

    def fallback(user_msg, system_msg, tools, error)
      Rails.logger.warn "[AiRouter] #{error.class.name}: #{error.message}. " \
                        'Fallback para OpenRouter.'
      Llm::OpenrouterClient.new.complete(user_msg, system: system_msg, tools: tools)
    end
  end
end
