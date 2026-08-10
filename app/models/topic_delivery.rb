# frozen_string_literal: true

class TopicDelivery < ApplicationRecord
  belongs_to :topic

  validates :url_key, presence: true
  validates :sent_at, presence: true
  validates :url_key, uniqueness: { scope: :topic_id }

  scope :recent, ->(days = 30) { where("sent_at >= ?", days.days.ago) }
end
