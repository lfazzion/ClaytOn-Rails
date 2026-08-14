# frozen_string_literal: true

class SentimentLabel < ApplicationRecord
  belongs_to :sentiment_phrase, foreign_key: "phrase_id"
  belongs_to :sentiment_run, foreign_key: "run_id"

  validates :pass, :attempt, :label, presence: true
end
