# frozen_string_literal: true

class ExternalCatalog < ApplicationRecord
  SOURCES = %w[tmdb igdb anilist rawg].freeze
  MEDIA_TYPES = %w[movie tv game anime].freeze
  STATUSES = %w[upcoming released airing releasing cancelled].freeze

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :external_id, presence: true
  validates :title, presence: true
  validates :media_type, inclusion: { in: MEDIA_TYPES }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  validates :source, uniqueness: { scope: :external_id }

  scope :by_source, ->(source) { where(source: source) }
  scope :by_media_type, ->(type) { where(media_type: type) }
  scope :recent, ->(days = 30) { where('created_at >= :dt OR release_date >= :dt_date', dt: days.days.ago, dt_date: days.days.ago.to_date) }
  scope :upcoming, lambda {
    where.not(release_date: nil)
         .where.not(status: "cancelled")
         .where('release_date >= ?', Date.current)
         .order(:release_date)
  }
  scope :popular, -> { where.not(popularity: nil).order(popularity: :desc, id: :asc) }
  scope :unsent, ->(days = 30) { where('last_sent_at IS NULL OR last_sent_at < ?', days.days.ago) }
  scope :popular_recent, ->(days = 30) { recent(days).unsent(days).popular }
end
