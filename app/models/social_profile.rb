# frozen_string_literal: true

class SocialProfile < ApplicationRecord
  PLATFORMS = %w[twitter instagram youtube tiktok].freeze

  # Channel ID canônico do YouTube: "UC" + 22 chars [A-Za-z0-9_-].
  # Case significativo — o @handle e o channel ID vivem em namespaces
  # distintos no YouTube; um ID downcasado vira um handle que não resolve
  # e a coleta morre em silêncio (achado 1/3 do PR #36).
  CHANNEL_ID_PATTERN = /\AUC[A-Za-z0-9_-]{22}\z/

  has_many :social_posts, dependent: :destroy
  has_many :profile_snapshots, dependent: :destroy
  has_many :discovered_profiles, foreign_key: :source_profile_id, dependent: :nullify

  validates :platform, presence: true, inclusion: { in: PLATFORMS }
  validates :platform_username, presence: true
  validates :platform_user_id, presence: true
  validates :platform, uniqueness: { scope: :platform_user_id }

  before_validation :normalize_platform_username

  scope :verified, -> { where(verified: true) }
  scope :by_platform, ->(platform) { where(platform: platform) }
  scope :monitored, -> { where(monitoring_status: "active", archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  scope :needs_collection, lambda {
    monitored
      .where("blocked_until IS NULL OR blocked_until < ?", Time.current)
      .where.not(last_collected_at: nil)
      .where("last_collected_at < ?", 2.hours.ago)
  }

  scope :pending_first_collection, lambda {
    where(last_collected_at: nil)
  }

  scope :by_platform_and_needs_collection, lambda { |platform|
    by_platform(platform)
      .monitored
      .where("blocked_until IS NULL OR blocked_until < ?", Time.current)
      .where("last_collected_at IS NULL OR last_collected_at < ?", 2.hours.ago)
  }

  def should_collect?(window = 2.hours)
    return true if last_collected_at.nil?

    Time.current - last_collected_at > window
  end

  def platform_url
    case platform
    when "instagram" then "https://www.instagram.com/#{platform_username}/"
    when "twitter" then "https://twitter.com/#{platform_username}/"
    when "youtube" then youtube_url
    when "tiktok" then "https://www.tiktok.com/@#{platform_username}/"
    end
  end

  def engagement_rate
    return nil if followers_count.nil? || followers_count.zero?

    posts = social_posts.last(10)
    return nil if posts.empty?

    total_engagement = posts.sum do |post|
      [post.likes_count || 0, post.comments_count || 0, post.shares_count || 0].sum
    end
    avg_engagement = total_engagement.to_f / posts.size
    (avg_engagement / followers_count * 100).round(2)
  end

  before_save :set_platform_url

  private

  def normalize_platform_username
    return if platform_username.blank?

    self.platform_username = platform_username.to_s.strip.sub(/\A@/, "")
    self.platform_username = self.platform_username.downcase unless self.platform_username.match?(CHANNEL_ID_PATTERN)
  end

  def set_platform_url
    self[:platform_url] = case platform
                          when "instagram" then "https://www.instagram.com/#{platform_username}/"
                          when "twitter" then "https://twitter.com/#{platform_username}/"
                          when "youtube" then youtube_url
                          when "tiktok" then "https://www.tiktok.com/@#{platform_username}/"
                          end
  end

  def youtube_url
    return "https://www.youtube.com/channel/#{platform_user_id}" if platform_user_id.to_s.match?(CHANNEL_ID_PATTERN)
    return "https://www.youtube.com/channel/#{platform_username}" if platform_username.to_s.match?(CHANNEL_ID_PATTERN)
    "https://www.youtube.com/@#{platform_username}"
  end
end

