# frozen_string_literal: true

class ScrapeYoutubeJob < ApplicationJob
  queue_as :default

  SNAPSHOT_DEDUP_WINDOW = 2.hours

  def perform(profile_id, options = {})
    profile = SocialProfile.find(profile_id)
    raise ArgumentError, "Perfil #{profile_id} não é YouTube" unless profile.platform == 'youtube'

    return unless profile.should_collect?(SNAPSHOT_DEDUP_WINDOW)

    proxy = current_proxy(options)
    channel_url = build_channel_url(profile)

    metadata = ScrapingServices::YoutubeScraperService.extract_channel_metadata(channel_url, proxy: proxy)
    return if metadata.nil?

    videos = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      channel_url,
      limit: options.fetch(:limit, 50),
      proxy: proxy
    )

    update_profile(profile, metadata)
    create_posts(profile, videos)
    create_snapshot(profile, metadata)

    profile.update!(
      last_collected_at: Time.current,
      collection_status: 'success'
    )
  rescue ScrapingServices::RateLimitError => e
    profile&.update(collection_status: 'rate_limited') if profile
    retry_job wait: e.retry_after
  rescue StandardError => e
    Rails.logger.error "[ScrapeYoutubeJob] Erro ao coletar perfil #{profile_id}: #{e.message}"
    profile&.update(collection_status: 'error') if profile
    raise e
  end

  private

  def build_channel_url(profile)
    if profile.platform_username.present?
      "https://www.youtube.com/@#{profile.platform_username}"
    else
      "https://www.youtube.com/channel/#{profile.platform_user_id}"
    end
  end

  def current_proxy(options)
    return nil unless ENV['USE_PROXY'] == 'true'

    options[:proxy]
  end

  def update_profile(profile, metadata)
    profile.update!(
      display_name: metadata[:title] || profile.display_name,
      bio: metadata[:description] || profile.bio,
      followers_count: metadata[:subscriber_count] || profile.followers_count,
      posts_count: metadata[:video_count] || profile.posts_count,
      avatar_url: metadata[:thumbnail_url] || profile.avatar_url
    )
  end

  def create_posts(profile, videos)
    videos.each do |video|
      post = SocialPost.find_or_initialize_by(
        social_profile: profile,
        platform_post_id: video[:platform_post_id]
      )

      # yt-dlp --flat-playlist é flaky: às vezes retorna view_count/posted_at,
      # às vezes nil (depende de qual variante do Innertube responde).
      # Não sobrescrever um valor já coletado com nil — preserva o melhor dado
      # que já temos. CLAUDE.md regra 3: nil = falha, não dado.
      post.assign_attributes(
        post_type: video[:post_type] || post.post_type || 'video',
        content: video[:title] || post.content,
        posted_at: video[:posted_at] || post.posted_at,
        views_count: video[:views_count] || post.views_count,
        thumbnail_url: video[:thumbnail_url] || post.thumbnail_url,
        video_url: video[:video_url] || post.video_url,
        likes_count: video[:likes_count] || post.likes_count,
        comments_count: video[:comments_count] || post.comments_count
      )

      post.save! if post.changed?
    end
  end

  def create_snapshot(profile, metadata)
    ProfileSnapshot.find_or_create_by(
      social_profile: profile,
      recorded_at: Time.current.beginning_of_hour
    ) do |snapshot|
      snapshot.followers_count = metadata[:subscriber_count]
      snapshot.posts_count = metadata[:video_count]
    end
  end
end
