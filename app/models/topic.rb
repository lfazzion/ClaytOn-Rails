# frozen_string_literal: true

class Topic < ApplicationRecord
  has_many :topic_deliveries, dependent: :destroy

  before_validation :normalize_name

  validates :name, presence: true, uniqueness: true, length: { in: 2..100 }
  validate :validate_active_topics_limit

  scope :active, -> { where(active: true) }

  private

  def normalize_name
    return if name.nil?

    self.name = name.to_s.squish.downcase
  end

  def validate_active_topics_limit
    return unless active?

    active_count = Topic.active.where.not(id: id).count
    if active_count >= 15
      errors.add(:base, "Limite máximo de 15 tópicos ativos atingido")
    end
  end
end
