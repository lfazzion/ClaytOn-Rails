# frozen_string_literal: true

class PostSnapshot < ApplicationRecord
  SNAPSHOT_DEDUP_WINDOW = 2.hours

  belongs_to :social_post

  validates :social_post_id, presence: true
  validates :recorded_at, presence: true

  scope :recent, -> { where("recorded_at >= ?", SNAPSHOT_DEDUP_WINDOW.ago) }
  scope :ordered, -> { order(recorded_at: :desc) }
end
