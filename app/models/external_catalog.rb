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
  scope :recent, ->(days = 30) { where('created_at >= ?', days.days.ago) }
  scope :upcoming, lambda {
    where.not(release_date: nil)
         .where.not(status: "cancelled")
         .where('release_date >= ?', Date.current)
         .order(:release_date)
  }
  scope :popular, -> { where.not(popularity: nil).order(popularity: :desc) }

  # C2a: populares RECENTES, determinísticos, com exclusão de itens já enviados.
  #   days         — janela de recência (base 30; fallback 60/90 — ver job).
  #   exclude_keys — chaves "source:external_id" de itens JÁ enviados para este
  #                  digest_type + canal; não entram de novo (supressão).
  # Desempate determinístico: popularity desc; empate ⇒ title asc. Nunca
  # depende da ordem física que o SQLite devolver a tabela.
  scope :recent_popular, lambda { |days: 30, exclude_keys: []|
    rel = where.not(popularity: nil)
             .where('created_at >= ?', days.days.ago)
             .order(popularity: :desc, title: :asc)
    if exclude_keys.any?
      rel = rel.where.not("CONCAT(source, ':', external_id) IN (?)", exclude_keys)
    end
    rel
  }

  # Chave estável de entrega do item (DigestItemDelivery.item_key).
  def key
    "#{source}:#{external_id}"
  end
end
