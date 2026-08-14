# frozen_string_literal: true

class SentimentRun < ApplicationRecord
  belongs_to :sentiment_target, foreign_key: "target_id"
  has_many :sentiment_phrases, foreign_key: "run_id", dependent: :destroy
  has_many :sentiment_labels, foreign_key: "run_id", dependent: :destroy
  has_many :sentiment_chunk_deliveries, foreign_key: "run_id", dependent: :destroy

  validates :status, presence: true
end
