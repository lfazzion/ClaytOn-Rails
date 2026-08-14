# frozen_string_literal: true

require Rails.root.join("lib/fetcher/cookie_jar")
require Rails.root.join("lib/fetcher/session_cookies")
require Rails.root.join("lib/fetcher/channels/youtube")

class ScrapeYoutubeJob < ApplicationJob
  queue_as :scraping

  limits_concurrency key: ->(profile_id, _options = {}) { "scrape_youtube/#{profile_id}" }, to: 1

  SNAPSHOT_DEDUP_WINDOW = 20.hours

  # ACHADO D + unificação pós-revisão (13/08): só estas exceções (erros de
  # rede/timeout/parser do scraper) são recuperáveis via fallback sem cookies.
  # Bugs de programação (NoMethodError, ArgumentError, quebra de contrato) NÃO
  # entram aqui e propagam para o handler externo do job.
  # `const_get` com rescue evita NameError no boot caso alguma classe de
  # stdlib (ex.: OpenURI) não esteja carregada no ambiente.
  # União das listas das PRs #135 e #140 (COLLECT_WITH_COOKIES_FALLBACK_ERRORS
  # ∪ RECOVERABLE_SCRAPER_ERRORS) — mesma semântica, cobertura completa.
  RECOVERABLE_SCRAPER_ERRORS = %w[
    Timeout::Error
    Net::ReadTimeout Net::OpenTimeout Net::HTTPError
    SocketError
    OpenURI::HTTPError URI::InvalidURIError
    Faraday::Error
    JSON::ParserError
    Errno::ECONNRESET Errno::ECONNREFUSED Errno::ETIMEDOUT
    OpenSSL::SSL::SSLError
    ScrapingServices::RateLimitError
  ].filter_map { |name| Object.const_get(name) rescue nil }.freeze

  def perform(profile_id, options = {})
    profile = SocialProfile.find(profile_id)
    raise ArgumentError, "Perfil #{profile_id} não é YouTube" unless profile.platform == "youtube"

    return unless profile.should_collect?(SNAPSHOT_DEDUP_WINDOW)

    Scraping::FetchPacer.wait("youtube.com")

    proxy = current_proxy(options)
    channel_url = build_channel_url(profile)

    metadata = ScrapingServices::YoutubeScraperService.extract_channel_metadata(channel_url, proxy: proxy)
    if metadata.nil?
      profile.update!(collection_status: "degraded")
      ScrapingFailureAlertJob.perform_later(
        "youtube",
        profile.id,
        "extract_channel_metadata returned nil",
        "metadata_failure"
      )
      return
    end

    limit = options.fetch(:limit, 30)
    videos, fallback_used = extract_videos_with_cookies(channel_url, limit: limit, proxy: proxy)

    update_profile(profile, metadata)
    create_posts(profile, videos)
    create_snapshot(profile, metadata)

    if fallback_used
      Rails.logger.warn "[ScrapeYoutubeJob] Perfil #{profile.id}: fallback para flat-playlist (sem dados detalhados)"
      profile.update!(
        last_collected_at: Time.current,
        collection_status: "partial"
      )
      ScrapingFailureAlertJob.perform_later(
        "youtube",
        profile.id,
        "fallback: sem dados detalhados (likes/comments nil)",
        "partial_collection"
      )
    else
      profile.update!(
        last_collected_at: Time.current,
        collection_status: "success"
      )
    end
  rescue ScrapingServices::RateLimitError => e
    profile&.update!(collection_status: "rate_limited", blocked_until: Time.current + e.retry_after) if profile
    retry_job wait: e.retry_after
  rescue ArgumentError
    raise
  rescue StandardError => e
    Rails.logger.error "[ScrapeYoutubeJob] Erro ao coletar perfil #{profile_id}: #{e.message}"
    if profile
      profile.update!(collection_status: "degraded")
      ScrapingFailureAlertJob.perform_later("youtube", profile.id, e.message, "scrape_error")
    end
  end

  private

  def extract_videos_with_cookies(channel_url, limit:, proxy:)
    cookies, = Fetcher::SessionCookies.for("youtube.com")
    Fetcher::CookieJar.with_netscape_file("youtube.com", cookies: cookies) do |cookies_path|
      result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
        channel_url,
        limit: limit,
        proxy: proxy,
        cookies_path: cookies_path
      )
      Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com",
        path: cookies_path,
        auth_cookies: Fetcher::Channels::Youtube::AUTH_COOKIES,
        expires_at: 7.days.from_now
      )
      result
    end
  rescue Fetcher::CookieJar::Expired
    Rails.logger.warn "[ScrapeYoutubeJob] Sessão de youtube.com ausente ou expirada. Coletando sem cookies."
    ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      channel_url,
      limit: limit,
      proxy: proxy,
      cookies_path: nil
    )
  rescue ScrapingServices::RateLimitError
    raise
  rescue *RECOVERABLE_SCRAPER_ERRORS => e
    # ACHADO D: só erros RECUPERÁVEIS conhecidos (rede/timeout/parser do
    # scraper) justificam o fallback sem cookies. Qualquer outra exceção —
    # inclusive NoMethodError ou quebra de contrato (bug de programação) —
    # DEVE propagar, e não virar um "sucesso" silencioso sem cookies.
    Rails.logger.warn "[ScrapeYoutubeJob] Erro recuperável coletando vídeos com cookies (#{e.class}): #{e.message}. Coletando sem cookies."
    ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      channel_url,
      limit: limit,
      proxy: proxy,
      cookies_path: nil
    )
  end

  def build_channel_url(profile)
    return "https://www.youtube.com/channel/#{profile.platform_user_id}" if profile.platform_user_id.to_s.match?(SocialProfile::CHANNEL_ID_PATTERN)
    return "https://www.youtube.com/channel/#{profile.platform_username}" if profile.platform_username.to_s.match?(SocialProfile::CHANNEL_ID_PATTERN)
    return "https://www.youtube.com/@#{profile.platform_username}" if profile.platform_username.present?
    "https://www.youtube.com/channel/#{profile.platform_user_id}"
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
    Array(videos).each do |video|
      post = SocialPost.find_or_initialize_by(
        social_profile: profile,
        platform_post_id: video[:platform_post_id]
      )

      # yt-dlp --flat-playlist é flaky: às vezes retorna view_count/posted_at,
      # às vezes nil (depende de qual variante do Innertube responde).
      # Não sobrescrever um valor já coletado com nil — preserva o melhor dado
      # que já temos. CLAUDE.md regra 3: nil = falha, não dado.
      post.assign_attributes(
        # fix 13: só sobrescreve post_type quando a detecção é POSITIVA de
        # short (webpage_url com /shorts/). Um short que perde a detecção num
        # run (parse devolve 'video') mantém 'short' do run anterior; vídeo
        # comum nunca vira short.
        post_type: video[:post_type] == 'short' ? 'short' : (post.post_type || 'video'),
        content: video[:title] || post.content,
        posted_at: video[:posted_at] || post.posted_at,
        views_count: video[:views_count] || post.views_count,
        thumbnail_url: video[:thumbnail_url] || post.thumbnail_url,
        video_url: video[:video_url] || post.video_url,
        likes_count: video[:likes_count] || post.likes_count,
        comments_count: video[:comments_count] || post.comments_count
      )

      post.save! if post.changed?

      create_post_snapshot(post)
    end

    prune_post_snapshots
  end

  def create_post_snapshot(post)
    today = Time.current.in_time_zone("America/Sao_Paulo").beginning_of_day
    snapshot = PostSnapshot.find_or_initialize_by(social_post: post, recorded_at: today)

    snapshot.views_count = post.views_count if post.views_count.present?
    snapshot.likes_count = post.likes_count if post.likes_count.present?
    snapshot.comments_count = post.comments_count if post.comments_count.present?

    snapshot.save! if snapshot.changed?
  end

  def prune_post_snapshots
    PostSnapshot.where("recorded_at < ?", 180.days.ago).delete_all
  end

  def create_snapshot(profile, metadata)
    recorded_at = Time.current.beginning_of_hour
    snapshot = ProfileSnapshot.find_or_initialize_by(
      social_profile: profile,
      recorded_at: recorded_at
    )
    snapshot.followers_count = metadata[:subscriber_count]
    snapshot.posts_count = metadata[:video_count]
    snapshot.save!
  rescue ActiveRecord::RecordNotUnique
    snapshot = ProfileSnapshot.find_by!(
      social_profile: profile,
      recorded_at: recorded_at
    )
    snapshot.followers_count = metadata[:subscriber_count]
    snapshot.posts_count = metadata[:video_count]
    snapshot.save! if snapshot.changed?
  end
end
