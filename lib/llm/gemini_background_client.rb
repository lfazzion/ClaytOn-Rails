# frozen_string_literal: true

module Llm
  class GeminiBackgroundClient < BaseClient
    # Gemini 3.1 Flash Lite: rota de background (classificação, digest). 500 RPD.
    MODEL_ID = 'gemini-3.1-flash-lite'
    MAX_DAILY = 480 # margem de segurança dos 500 RPD

    def model_id = MODEL_ID
    def daily_quota_key = 'gemini_background_daily'
    def max_daily_requests = MAX_DAILY
  end
end
