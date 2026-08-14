# frozen_string_literal: true

class Event < ApplicationRecord
  SOURCES = %w[rss manual].freeze
  EVENT_TYPES = %w[bgs ccxp anime_friends other].freeze

  validates :title, presence: true
  validates :source_url, uniqueness: true, allow_nil: true
  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :event_type, inclusion: { in: EVENT_TYPES }, allow_nil: true

  scope :upcoming, -> { where('start_date >= ?', Date.current).order(:start_date, :id) }
  scope :by_type, ->(type) { where(event_type: type) }
  scope :by_location, ->(location) { where('location LIKE ?', "%#{location}%") }
  scope :recent, ->(days = 7) { where('created_at >= ?', days.days.ago) }
end
