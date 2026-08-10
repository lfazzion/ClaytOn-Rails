# frozen_string_literal: true

class ScrapeTwitterJob < ApplicationJob
  queue_as :scraping

  SNAPSHOT_DEDUP_WINDOW = 20.hours

  def perform(profile_id, options = {})
    profile = SocialProfile.find(profile_id)

    return unless should_collect?(profile)

    Scraping::FetchPacer.wait("twitter.com")

    scraper_data = scrape_profile(profile, options)

    if scraper_data.nil?
      create_snapshot(profile, {}, degraded: true)
      profile.update!(last_collected_at: Time.current, collection_status: "degraded")
      return
    end

    update_profile(profile, scraper_data)
    create_snapshot(profile, scraper_data)

    profile.update!(last_collected_at: Time.current, collection_status: "success")
  rescue ScrapingServices::RateLimitError => e
    profile&.update!(collection_status: "rate_limited", blocked_until: Time.current + e.retry_after) if profile
    retry_job wait: e.retry_after
  rescue StandardError => e
    Rails.logger.error "[ScrapeTwitterJob] Erro ao coletar perfil #{profile_id}: #{e.message}"
    if profile
      create_snapshot(profile, {}, degraded: true)
      profile.update!(last_collected_at: Time.current, collection_status: "degraded")
      ScrapingFailureAlertJob.perform_later("twitter", profile.id, e.message, "scrape_error")
    end
  end

  private

  def should_collect?(profile)
    profile.should_collect?(SNAPSHOT_DEDUP_WINDOW)
  end

  def scrape_profile(profile, options)
    if use_python_scraper?(options)
      scrape_with_python(profile, options)
    else
      scrape_with_ferrum(profile)
    end
  end

  def use_python_scraper?(options)
    options[:use_python] || ENV['USE_NODRIVER'] == 'true'
  end

  def scrape_with_python(profile, options)
    runner = ScrapingServices::NodriverRunner
    runner.scrape_twitter_profile(
      profile.platform_username,
      proxy: current_proxy(options)
    )
  end

  def scrape_with_ferrum(profile)
    scraper = ScrapingServices::TwitterScraper.new(proxy: current_proxy({}))
    scraper.scrape_profile(profile.platform_username)
  ensure
    scraper&.close
  end

  def current_proxy(options)
    return nil unless ENV['USE_PROXY'] == 'true'

    options[:proxy]
  end

  def update_profile(profile, data)
    profile.update!(
      display_name: data[:display_name] || profile.display_name,
      bio: data[:bio] || profile.bio,
      followers_count: data[:followers_count] || profile.followers_count,
      following_count: data[:following_count] || profile.following_count,
      posts_count: data[:posts_count] || profile.posts_count,
      verified: data[:is_verified] || profile.verified,
      avatar_url: data[:profile_image_url] || profile.avatar_url,
      is_private: data.key?(:is_private) ? data[:is_private] : profile.is_private
    )
  end

  def create_snapshot(profile, data, degraded: false)
    snapshot = ProfileSnapshot.find_or_initialize_by(
      social_profile: profile,
      recorded_at: Time.current.beginning_of_hour
    )

    if snapshot.new_record? || !degraded
      snapshot.followers_count = data[:followers_count]
      snapshot.following_count = data[:following_count]
      snapshot.posts_count = data[:posts_count]
      snapshot.source_degraded = degraded
      snapshot.save!
    end
  end
end
