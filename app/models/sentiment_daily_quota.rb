# frozen_string_literal: true

class SentimentDailyQuota < ApplicationRecord
  # O inflector do Rails 8 não pluraliza 'quota' (medido 10/08/2026: 'quota'.pluralize == 'quota') — tabela explícita.
  self.table_name = "sentiment_daily_quotas"
  validates :day, presence: true, uniqueness: true
  validates :count, presence: true, numericality: { greater_than_or_equal_to: 0 }
end
