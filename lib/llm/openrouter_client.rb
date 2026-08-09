# frozen_string_literal: true

module Llm
  class OpenrouterClient < BaseClient
    # Roteador gratuito da OpenRouter — fallback das duas rotas Google.
    # Era openrouter/auto, que roteia para modelos pagos e cobra a tarifa de quem
    # atender: um fallback de emergência que gastava dinheiro sem avisar.
    MODEL_ID = 'openrouter/free'
    MAX_DAILY = 400 # conservador para tier gratuito/pago básico

    def model_id = MODEL_ID
    def daily_quota_key = 'openrouter_daily'
    def max_daily_requests = MAX_DAILY
  end
end
