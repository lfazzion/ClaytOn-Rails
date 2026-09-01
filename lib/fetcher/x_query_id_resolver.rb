# frozen_string_literal: true

module Fetcher
  # Solução viva de query ID do X: extrai queryId/operationName dos bundles webpack
  # do X (x.com/home + main.<hash>.js) com cache persistente, soft-TTL 24h,
  # preserva último valor em falha e usa lock de concorrência.
  #
  # Uso:
  #   query_id = Fetcher::XQueryIdResolver.new.resolve('SearchTimeline')
  class XQueryIdResolver
    PIN = 'flaR-PUMshxFWZWPNpq4zA'.freeze

    CORE_CHUNK_PATTERNS = %w[
      main
      bundle.LoggedInMain
      ondemand.HoverCard
      bundle.UserProfile
      bundle.HomeTimeline
      bundle.TrendTimeline
      bundle.SettingsAccount
      bundle.SettingsSecurity
      bundle.DmComposer
      bundle.ComposeTweet
      bundle.Profile
      bundle.ProfileUserActions
      bundle.Followers
      bundle.Following
      bundle.Lists
      bundle.Bookmarks
      bundle.MediaModal
      bundle.VerifiedBadge
      bundle.CommerceBrowser
      bundle.ShoppingS7C
      bundle.Moments
      bundle.SearchTimeline
      bundle.PerThread
      bundle.ArticleCard
      bundle.Promo
      bundle.PinnedTimeline
      bundle.UserMemberships
      bundle.UserEarnings
      bundle.Financial
      bundle.SuperFollowsCampaign
    ].freeze

    QUERY_ID_REGEX = /queryId\s*:\s*"([^"]+)"\s*,\s*operationName\s*:\s*"([^"]+)"/.freeze
    HOME_URL = 'https://x.com/home'.freeze
    BUNDLE_BASE_URL = 'https://abs.twimg.com/responsive-web/client-web/'.freeze

    attr_reader :cache

    def current_pin
      PIN
    end

    def initialize(cache: nil)
      @cache = cache || Rails.cache
      @mutex = Mutex.new
      @fetching = false
    end

    def resolve(operation_name, force: false)
      cache_key = "fetcher:x_query_id:#{operation_name}"
      envelope = @cache.read(cache_key)

      # Cache fresco sem force: retorna imediatamente
      return envelope[:query_id] if envelope && fresh_envelope?(envelope) && !force

      # Se não tem cache, descobre e retorna PIN se falhar
      if envelope.nil?
        return discover!(operation_name) || PIN
      end

      # force: true -> forca discover! de verdade, preserva ultimo em falha
      if force
        begin
          return discover!(operation_name) || envelope[:query_id]
        rescue StandardError
          return envelope[:query_id]
        end
      end

      # Cache stale: retorna último valor, dispara refresh async
      if stale_envelope?(envelope)
        Thread.new { discover!(operation_name) }
        return envelope[:query_id]
      end

      # Falha inesperada: retorna último valor
      envelope[:query_id]
    rescue StandardError
      # Em qualquer falha, preserva último valor conhecido
      envelope&.dig(:query_id) || PIN
    end

    def extract_query_ids(bundle_content)
      results = {}
      bundle_content.scan(QUERY_ID_REGEX) { |q, o| results[o] = q }
      results
    end

    def extract_query_id(bundle_content, operation_name)
      results = extract_query_ids(bundle_content)
      results[operation_name]
    end

    def filter_allowed_bundle_urls(urls)
      urls.select { |url| allowed_bundle?(url) }
    end

    def fetch_fresh(operation_name)
      discover!(operation_name)
    end

    private

    def fresh_envelope?(envelope)
      envelope[:fetched_at] && (Time.now.to_i - envelope[:fetched_at]) < 24 * 3600
    end

    def stale_envelope?(envelope)
      !fresh_envelope?(envelope)
    end

    def allowed_bundle?(url)
      return false unless url.start_with?(BUNDLE_BASE_URL)

      CORE_CHUNK_PATTERNS.any? do |pattern|
        url.include?("#{pattern}.")
      end
    end

    def discover!(operation_name)
      lock_key = "fetcher:x_query_id_lock:#{operation_name}"

      @mutex.synchronize do
        # Se já há fetch em andamento nesta instância, aguarda e retorna o valor em cache (se houver)
        if @fetching
          return @cache.read("fetcher:x_query_id:#{operation_name}")&.dig(:query_id)
        end

        # Se já há alguém descobrindo (lock no cache), retorna nil
        return nil if @cache.read(lock_key)

        # Sinaliza que inicia fetch e mantém lock no cache
        @fetching = true
        @cache.write(lock_key, true, expires_in: 60)
      end

      begin
        home_html = fetch_home_html
        bundle_urls = extract_bundle_urls(home_html)
        allowed_urls = filter_allowed_bundle_urls(bundle_urls)

        query_ids = {}
        allowed_urls.each do |url|
          begin
            bundle_js = fetch_bundle(url)
            query_ids.merge!(extract_query_ids(bundle_js))
            break if query_ids.key?(operation_name)
          rescue StandardError
            next
          end
        end

        query_id = query_ids[operation_name]

        cache_key = "fetcher:x_query_id:#{operation_name}"
        envelope = {
          query_id: query_id || PIN,
          fetched_at: Time.now.to_i,
          stale_at: Time.now.to_i + 24 * 3600
        }
        @cache.write(cache_key, envelope, expires_in: 25 * 3600)

        query_id || PIN
      ensure
        @mutex.synchronize do
          @fetching = false
          # Mantém lock no cache por TTL para evitar refreshes simultâneos de outras instâncias
        end
      end
    end

    def fetch_home_html
      req = Faraday.new(url: HOME_URL).get
      raise "HTTP #{req.status}" unless req.success?

      req.body
    end

    def extract_bundle_urls(html)
      urls = []
      # Extrai URLs dos preload links (independente da ordem dos atributos)
      html.scan(/<link[^>]+>/) do |tag|
        if tag.include?('rel="preload"') && tag.include?('as="script"') && tag =~ /href="([^"]+)"/
          urls << $1
        end
      end
      urls.uniq
    end

    def fetch_bundle(url)
      req = Faraday.new(url: url).get
      raise "HTTP #{req.status}" unless req.success?

      req.body
    end
  end
end
