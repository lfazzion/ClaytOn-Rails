# frozen_string_literal: true

class SentimentPhrase < ApplicationRecord
  belongs_to :sentiment_run, foreign_key: "run_id"
  has_many :sentiment_labels, foreign_key: "phrase_id", dependent: :destroy

  validates :source, :external_id, :text, presence: true
end
