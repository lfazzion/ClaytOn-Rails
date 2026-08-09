# frozen_string_literal: true

module Llm
  class OpenrouterClient < BaseClient
    # Roteador gratuito da OpenRouter — fallback das duas rotas Google.
    # O valor removido era o par de modelos gratuitos fixos google/gemma-4-31b-it:free
    # e openai/gpt-oss-120b:free — não o openrouter/auto.
    MODEL_ID = 'openrouter/free'
    MAX_DAILY = 400 # conservador para tier gratuito/pago básico

    def model_id = MODEL_ID
    def daily_quota_key = 'openrouter_daily'
    def max_daily_requests = MAX_DAILY
  end
end
