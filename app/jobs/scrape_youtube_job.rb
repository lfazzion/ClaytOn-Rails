# frozen_string_literal: true

require Rails.root.join("lib/fetcher/cookie_jar")
require Rails.root.join("lib/fetcher/session_cookies")
require Rails.root.join("lib/fetcher/channels/youtube")
require_relative "../services/alert_throttler"

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

  # B3: a transição sem-cookie é EXCLUSIVA do `rescue Fetcher::CookieJar::Expired`.
  # Qualquer outra falha (rede/timeout/parser/etc) NÃO mais chama `cookies_path: nil`
  # — virou "parcial nomeado mantendo o jar". A causa nomeada é derivada da classe
  # da exceção (timeout/network); `parser` e demais não são causas nomeadas do
  # item 3, então caem em `unknown`. `RateLimitError` ainda propaga para o
  # handler de retry de perform.
  #
  # `filter_map` + rescue espelha o RECOVERABLE acima: constância ausente no
  # ambiente (ex.: OpenURI/Faraday não carregados) é filtrada, não quebra o
  # boot; o mapeamento por `kind_of?` em runtime nunca levanta `NameError`.
  TIMEOUT_CAUSE_ERRORS = %w[
    Timeout::Error
    Net::ReadTimeout Net::OpenTimeout
    Errno::ETIMEDOUT
  ].filter_map { |name| Object.const_get(name) rescue nil }.freeze

  NETWORK_CAUSE_ERRORS = %w[
    Errno::ECONNRESET Errno::ECONNREFUSED Errno::ECONNABORTED
    Errno::EHOSTUNREACH Errno::ENETUNREACH Errno::EADDRNOTAVAIL Errno::EPIPE
    SocketError
    Net::HTTPError
    OpenSSL::SSL::SSLError
    OpenURI::HTTPError
    Faraday::Error
  ].filter_map { |name| Object.const_get(name) rescue nil }.freeze

  # B3: classe da exceção → causa nomeada do parcial. Ordem: timeout antes de
  # network (timeout é um subconjunto temporal); parser e demais → unknown.
  def partial_cause_for(exception)
    return "timeout" if TIMEOUT_CAUSE_ERRORS.any? { |k| exception.kind_of?(k) }
    return "network" if NETWORK_CAUSE_ERRORS.any? { |k| exception.kind_of?(k) }
    "unknown"
  end

  def perform(profile_id, options = {})
    profile = SocialProfile.find(profile_id)
    raise ArgumentError, "Perfil #{profile_id} não é YouTube" unless profile.platform == "youtube"

    return unless profile.should_collect?(SNAPSHOT_DEDUP_WINDOW)

    Scraping::FetchPacer.wait("youtube.com")

    proxy = current_proxy(options)
    channel_url = build_channel_url(profile)

    # B8a: o contrato de metadata agora é [dados, causa, nota]. A causa
    # nomeada (bot_check | members_only | timeout | network | session_rejected
    # | unknown) é a que o serviço extraiu do stderr — NUNCA mais um alerta
    # genérico "returned nil" sem motivo. A nota "sessão expirada" vem da
    # transição sem-cookie após Fetcher::CookieJar::Expired (única legítima).
    metadata, metadata_cause, metadata_note = extract_metadata_with_cookies(channel_url, proxy: proxy)
    if metadata.nil?
      detail = metadata_note ? " (sem cookies: #{metadata_note})" : ""
      motivo_causa = metadata_cause ? " (causa: #{metadata_cause})" : ""
      profile.update!(collection_status: "degraded")
      ScrapingFailureAlertJob.perform_later(
        "youtube",
        profile.id,
        "extract_channel_metadata returned nil#{motivo_causa}#{detail}",
        "metadata_failure"
      )
      return
    end

    limit = options.fetch(:limit, 30)
    # ITEM 3: o serviço devolve [itens, fallback?, causa] — a causa nomeada
    # (bot_check | members_only | timeout | network | session_rejected |
    # unknown) vai para o status e para o alerta, que antes era opaco. A causa
    # é não-nil SOMENTE quando o caminho detalhado do /videos FALHOU, então a
    # presença dela já é sinal de coleta parcial — mesmo sem fallback sem-cookie
    # (ex.: bot_check devolve itens vazios + causa, sem cair no flat).
    videos, fallback_used, cause = extract_videos_with_cookies(channel_url, limit: limit, proxy: proxy)

    update_profile(profile, metadata)
    create_posts(profile, videos)
    create_snapshot(profile, metadata)

    if cause || fallback_used
      motivo = cause.presence || "sem causa identificada"
      Rails.logger.warn "[ScrapeYoutubeJob] Perfil #{profile.id}: coleta parcial, causa #{motivo} (sem dados detalhados)"
      profile.update!(
        last_collected_at: Time.current,
        collection_status: "partial (#{motivo})"
      )
      ScrapingFailureAlertJob.perform_later(
        "youtube",
        profile.id,
        "fallback: #{motivo} — sem dados detalhados (likes/comments nil)",
        "partial_collection"
      )
    else
      profile.update!(
        last_collected_at: Time.current,
        collection_status: "success"
      )
      AlertThrottler.resolve_incident("youtube", profile.id)
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

  # ITEM 1 — metadados passam pela MESMA sessão de cookies dos vídeos
  # (mesmo desenho de extract_videos_with_cookies): antes o yt-dlp de
  # metadata rodava anônimo mesmo quando a coleta de vídeo usava cookies —
  # os dois caminhos viam o YouTube com olhos diferentes. `Expired` mantém
  # o comportamento atual: coleta sem cookie, e o `note` devolvido explica
  # AO CHAMADOR por que foi sem cookie (o alerta diz "sessão expirada").
  #
  # O `result` é capturado do bloco e retornado explicitamente: assim o
  # valor de retorno do helper é o PAR [metadata, note] do bloco, e não o
  # valor que um stub de with_netscape_file pudesse sobrepôr via .returns
  # (o helper de vídeos segue devolvendo o retorno de with_netscape_file,
  # e os testes combinam .returns com o stub de extract_videos_detailed).
  def extract_metadata_with_cookies(channel_url, proxy:)
    cookies, = Fetcher::SessionCookies.for("youtube.com")
    result = nil
    Fetcher::CookieJar.with_netscape_file("youtube.com", cookies: cookies) do |cookies_path|
      # B8a: o serviço devolve [dados, causa] — causa nomeada na falha
      # (bot_check/members/timeout/network/session_rejected/unknown), nil no
      # sucesso. O helper repassa isso ao chamador em [metadata, causa, nota].
      metadata, cause = ScrapingServices::YoutubeScraperService.extract_channel_metadata(
        channel_url, proxy: proxy, cookies_path: cookies_path
      )
      Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com",
        path: cookies_path,
        auth_cookies: Fetcher::Channels::Youtube::AUTH_COOKIES,
        expires_at: 7.days.from_now
      )
      result = [metadata, cause, nil]
    end
    result
  rescue Fetcher::CookieJar::Expired
    # B4/B8a: Expired é a ÚNICA prova tipada que abre coleta sem-cookie.
    # `session_rejected` (causa) identifica o motivo na degradação; a nota
    # "sessão expirada" acompanha o alerta do chamador.
    Rails.logger.warn "[ScrapeYoutubeJob] Sessão de youtube.com ausente ou expirada. Coletando metadata sem cookies."
    fallback_metadata, = ScrapingServices::YoutubeScraperService.extract_channel_metadata(
      channel_url, proxy: proxy, cookies_path: nil
    )
    if fallback_metadata.nil?
      [nil, "session_rejected", "sessão expirada"]
    else
      [fallback_metadata, nil, "sessão expirada"]
    end
  rescue ScrapingServices::RateLimitError
    raise
  end

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
    # B3/B4: ÚNICA transição sem-cookie legítima. A sessão ausente/expirada é
    # a prova tipada externa — o jar vazio não tem o que manter, então a
    # coleta segue SEM cookie. O serviço devolve a 3-tupla [itens, fallback,
    # causa] (com causa `session_rejected` quando a sessão expirou).
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
    # B3 (REVERSO do ACHADO D): uma falha recuperável de REDE/TIMEOUT/PARSER
    # na sessão AUTENTICADA NÃO justifica coleta anônima — sem cookie o
    # bloqueio só piora e o run viraria "sucesso anônimo" (o defeito do B1).
    # Devolve um run PARCIAL NOMEADO mantendo o jar: [[], false, causa], com a
    # causa derivada da classe da exceção (network/timeout/unknown). O `jar`
    # NÃO é descartado — a sessão segue valendo para o próximo run.
    cause = partial_cause_for(e)
    Rails.logger.warn "[ScrapeYoutubeJob] Falha recuperável coletando vídeos com cookies (#{e.class}): #{e.message}. Parcial nomeado (#{cause}), mantendo o jar."
    [[], false, cause]
  end

  def build_channel_url(profile)
    return "https://www.youtube.com/channel/#{profile.platform_user_id}" if profile.platform_user_id.to_s.match?(SocialProfile::CHANNEL_ID_PATTERN)
    return "https://www.youtube.com/channel/#{profile.platform_username}" if profile.platform_username.to_s.match?(SocialProfile::CHANNEL_ID_PATTERN)
    return "https://www.youtube.com/@#{profile.platform_username}" if profile.platform_username.present?
    "https://www.youtube.com/channel/#{profile.platform_user_id}"
  end

  def current_proxy(options)
    return nil unless ENV['USE_PROXY'] == 'true'

    # MISSÃO YT-1: `perform_later` chega sem options (ProfileManagementTools
    # 180/435) — cair no proxy do ambiente. A analogia com Ferrum
    # (ferrum.rb:74) vale só para DE ONDE LER o proxy: ele usa .present?
    # e não tem o gate USE_PROXY. options[:proxy] explícito é override;
    # MISSÃO YT-2: .presence — string vazia é truthy, e com SCRAPING_PROXY=""
    # (modelo de .env.example:47) "" viraria --proxy "".
    options[:proxy].presence || ENV['SCRAPING_PROXY'].presence
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
