# frozen_string_literal: true

module Llm
  class GeminiInteractiveClient < BaseClient
    # Gemini 3.5 Flash Lite: rota interativa. 500 RPD.
    MODEL_ID = 'gemini-3.5-flash-lite'
    MAX_DAILY = 480 # margem de segurança dos 500 RPD

    def model_id = MODEL_ID
    def daily_quota_key = 'gemini_interactive_daily'
    def max_daily_requests = MAX_DAILY
  end
end
