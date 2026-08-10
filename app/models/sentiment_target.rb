# frozen_string_literal: true

class SentimentTarget < ApplicationRecord
  has_many :sentiment_runs, foreign_key: "target_id", dependent: :destroy

  MAX_ACTIVE_TARGETS = 5

  validates :name, presence: true, uniqueness: true
  validates :query, presence: true
  validates :bucket, inclusion: { in: %w[day week] }
  validates :window_days, numericality: { greater_than: 0 }
  validates :max_phrases, numericality: { greater_than: 0 }
  validate :max_active_targets_limit, if: :active?

  def frozen_spec
    {
      "name" => name,
      "query" => query,
      "sources" => sources,
      "window_days" => window_days,
      "bucket" => bucket,
      "max_phrases" => max_phrases
    }
  end

  private

  def max_active_targets_limit
    existing = self.class.where(active: true)
    existing = existing.where.not(id: id) if persisted?
    if existing.count >= MAX_ACTIVE_TARGETS
      errors.add(:base, "Limite máximo de 5 alvos de sentimento ativos foi atingido")
    end
  end
end
