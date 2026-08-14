# frozen_string_literal: true

class SentimentChunkDelivery < ApplicationRecord
  belongs_to :sentiment_run, foreign_key: "run_id"

  validates :chunk_index, presence: true, uniqueness: { scope: :run_id }
  validates :delivered_at, presence: true
end
