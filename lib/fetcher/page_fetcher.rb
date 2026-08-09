# frozen_string_literal: true

require "digest"
require "yaml"
require "timeout"
require_relative "ssrf_guard"
require_relative "ttl_policy"
require_relative "bot_detection"
require_relative "readability_injector"
require_relative "host_rate_limiter"

module Fetcher
  class PageFetcher
    RATE_LIMIT_MAX    = 5
    RATE_LIMIT_WINDOW = 60
    CACHE_KEY_PREFIX  = "page_fetch:v1"
    RATE_KEY_PREFIX   = "page_fetch:rl"
    BROWSER_MAX_AGE   = 24 * 3600
    BROWSER_PROBE_TIMEOUT = 2
    GOTO_TIMEOUT      = 20
    OVERALL_TIMEOUT   = 25
    IDLE_DURATION     = 0.8
    IDLE_TIMEOUT      = 4
    BODY_STABILIZE_ATTEMPTS = 6
    BODY_STABILIZE_INTERVAL = 0.5
    TRACKING_PARAMS = %w[utm_source utm_medium utm_campaign utm_term utm_content
                         fbclid gclid ref mc_cid mc_eid].freeze

    STEALTH_JS = <<~'JS'
      Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
      window.chrome = window.chrome || {runtime: {}};
    JS

    # Sinais de que a sessão CDP em cache morreu (chrome reiniciado, socket caído).
    # `Ferrum::DeadBrowserError` é o caso nomeado; os de IO cobrem o socket cru.
    DEAD_SESSION_ERRORS = [
      Ferrum::DeadBrowserError,
      Ferrum::NoSuchPageError,
      Ferrum::NoSuchTargetError,
      EOFError,
      IOError,
      Errno::ECONNRESET,
      Errno::EPIPE,
      Errno::ECONNREFUSED
    ].freeze

    class FetchError < StandardError; end
    class RateLimited < FetchError
      def initialize(host)
        super("rate limit local: host #{host} atingiu #{RATE_LIMIT_MAX} fetches/min")
      end
    end
    class HostInCooldown < FetchError
      attr_reader :entry
      def initialize(host, entry)
        @entry = entry
        remaining = (entry[:expires_at] - Time.current).to_i
        h = remaining / 3600
        m = (remaining % 3600) / 60
        super("host #{host} em cooldown de bot-detection (expira em #{h}h#{m}m)")
      end
    end
    class BotBlocked < FetchError
      def initialize(host, reason)
        super("host #{host} bloqueou acesso (#{reason}) — em cooldown")
      end
    end
    class PdfNotSupported < FetchError
      def initialize
        super("conteúdo é PDF — use web_search para links de PDF")
      end
    end
    class RenderTimeout < FetchError
      def initialize
        super("render timeout após #{OVERALL_TIMEOUT}s")
      end
    end

    class << self
      def call(url_string, include_html: false)
        new.call(url_string, include_html: include_html)
      end

      def browser
        @browser_mutex ||= Mutex.new
        @browser_mutex.synchronize do
          discard_locked! if @browser && (expired? || !alive?(@browser))

          @browser ||= begin
            @browser_started_at = Time.current
            build_browser
          end
        end
      end

      def reset_browser!
        @browser_mutex ||= Mutex.new
        @browser_mutex.synchronize { discard_locked! }
      end

      # Sonda barata de sessão viva. Sem ela, um restart do container do chrome
      # deixa a instância em cache com um WebSocket morto e TODA escalada trava o
      # OVERALL_TIMEOUT inteiro — por até BROWSER_MAX_AGE, já que o descarte era
      # só por idade. O timeout próprio é obrigatório: o client do ferrum está
      # configurado com `timeout: 30` (config/initializers/ferrum.rb), então uma
      # sessão pendurada bloquearia 30s aqui.
      def alive?(browser)
        Timeout.timeout(BROWSER_PROBE_TIMEOUT) { browser.version }
        true
      rescue Timeout::Error, StandardError => e
        Rails.logger.warn "[Fetcher::PageFetcher] browser em cache não respondeu (#{e.class}) — descartando"
        false
      end

      def hard_domains
        @hard_domains ||= load_yaml("hard_domains.yml", "hard_domains")
      end

      def reset_config!
        @hard_domains = nil
      end

      private

      # Só chamar com @browser_mutex já retido — Mutex do Ruby não é reentrante.
      def discard_locked!
        safe_quit(@browser) if @browser
        @browser = nil
        @browser_started_at = nil
      end

      def expired?
        @browser_started_at.nil? || (Time.current - @browser_started_at).to_i > BROWSER_MAX_AGE
      end

      def build_browser
        opts = FerumConfig.browser_options.merge(dockerize: true)
        browser = Ferrum::Browser.new(**opts)
        # `evaluate_on_new_document` é método de Ferrum::Browser, não de Page:
        # ele só empurra o script para `options.extensions` (browser.rb:192-194),
        # e cada página injeta essa lista ao ser criada (page.rb:478 +
        # `inject_extensions`). Injetar aqui vale para toda página de todo
        # contexto desta instância, que é a semântica do método.
        browser.evaluate_on_new_document(STEALTH_JS)
        browser
      end

      def safe_quit(browser)
        browser.quit
      rescue StandardError
        nil
      end

      def load_yaml(filename, key)
        path = Rails.root.join("config/#{filename}")
        return [] unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        Array(data[key]).map(&:to_s).map(&:downcase)
      end
    end

    def initialize(browser_factory: nil, clock: Time)
      @browser_factory = browser_factory
      @clock = clock
    end

    # `include_html: true` acrescenta `article_html` ao payload — o HTML que o
    # Readability.js isolou, insumo do conversor de markdown do /internal/extract.
    def call(url_string, include_html: false)
      uri  = SsrfGuard.validate!(url_string)
      host = uri.host.to_s.downcase

      check_rate_limit!(host)
      check_cooldown!(host)

      cache_key = build_cache_key(uri, include_html: include_html)
      if (cached = Rails.cache.read(cache_key))
        return cached.merge(cache_age_seconds: (@clock.current - cached[:fetched_at]).to_i)
      end

      raw = if hard_domain?(host)
              fetch_via_python(uri)
            else
              fetch_via_ferrum(uri)
            end

      # O Chrome (e o nodriver) seguem redirects por conta própria — a validação
      # pré-fetch só cobriu a URL inicial. Revalidar o destino final é o que
      # impede um `302 -> http://127.0.0.1/` de virar payload de resposta.
      revalidate_final_url!(raw[:final_url], uri)

      if bot_blocked?(raw, host)
        reason = raw[:title].to_s[0, 80]
        BotDetection.cooldown!(host, reason: reason.empty? ? "block detected" : reason)
        raise BotBlocked.new(host, reason)
      end

      extracted = ReadabilityInjector.extract(
        readability_text: raw[:readability_text],
        body_text: raw[:body_text],
        fallback_html: raw[:html].to_s,
        live: TtlPolicy.live_host?(host)
      )

      payload = {
        title:             raw[:title].to_s,
        url:               raw[:final_url] || uri.to_s,
        content:           extracted[:content],
        truncated:         extracted[:truncated],
        char_count:        extracted[:char_count],
        fetched_at:        @clock.current,
        cache_age_seconds: 0
      }
      payload[:article_html] = raw[:readability_html].to_s if include_html

      ttl = TtlPolicy.for(host: host, path: uri.path)
      Rails.cache.write(cache_key, payload, expires_in: ttl)
      payload
    end

    private

    def check_rate_limit!(host)
      raise RateLimited.new(host) if HostRateLimiter.exceeded?(host, max: RATE_LIMIT_MAX)
    end

    def revalidate_final_url!(final_url, original_uri)
      final = final_url.to_s
      return if final.empty? || final == original_uri.to_s

      SsrfGuard.validate!(final)
    end

    def check_cooldown!(host)
      entry = BotDetection.cooldown_for(host)
      raise HostInCooldown.new(host, entry) if entry
    end

    def hard_domain?(host)
      self.class.hard_domains.any? { |d| host == d || host.end_with?(".#{d}") }
    end

    def build_cache_key(uri, include_html: false)
      canonical = [
        uri.scheme.to_s.downcase,
        "://",
        uri.host.to_s.downcase,
        uri.path.chomp("/").empty? ? "/" : uri.path.chomp("/"),
        canonical_query(uri.query)
      ].join
      # Namespace separado: os dois formatos de payload não podem se sobrescrever.
      suffix = include_html ? ":html" : ""
      "#{CACHE_KEY_PREFIX}#{suffix}:#{Digest::SHA1.hexdigest(canonical)}"
    end

    def canonical_query(query)
      return "" if query.to_s.empty?

      params = URI.decode_www_form(query)
                  .reject { |(k, _)| TRACKING_PARAMS.include?(k.downcase) }
                  .sort_by { |(k, _)| k }
      params.empty? ? "" : "?#{URI.encode_www_form(params)}"
    end

    def bot_blocked?(raw, _host)
      fake_page = Struct.new(:status, :title, :body, :current_url).new(
        raw[:status],
        raw[:title].to_s,
        raw[:body_text].to_s + raw[:html].to_s,
        raw[:final_url].to_s
      )
      BotDetection.blocked?(fake_page)
    end

    def fetch_via_python(uri)
      result = ScrapingServices::NodriverRunner.fetch_page(uri.to_s)
      raise FetchError, "fallback Python retornou vazio" if result.nil?

      {
        title: result[:title].to_s,
        final_url: result[:url].to_s.presence || uri.to_s,
        readability_text: nil,
        readability_html: nil,
        body_text: result[:content].to_s,
        html: "",
        status: 200
      }
    end

    # Uma retentativa com browser novo quando a sessão morre no meio do caminho —
    # a sonda de `PageFetcher.browser` pega o caso comum, esta cobre a corrida em
    # que o chrome cai depois da sonda e antes do render.
    def fetch_via_ferrum(uri)
      render_via_ferrum(uri)
    rescue *DEAD_SESSION_ERRORS => e
      raise if @browser_factory # browser injetado em teste: não é nosso para descartar

      Rails.logger.warn "[Fetcher::PageFetcher] sessão morta (#{e.class}) — reconstruindo browser e tentando de novo"
      self.class.reset_browser!
      render_via_ferrum(uri)
    end

    def render_via_ferrum(uri)
      Timeout.timeout(OVERALL_TIMEOUT) do
        browser = @browser_factory ? @browser_factory.call : self.class.browser
        context = browser.contexts.create
        page    = context.create_page
        begin
          # STEALTH_JS não é injetado aqui: `evaluate_on_new_document` é do
          # Browser, e a injeção acontece em `build_browser`, uma vez por
          # instância. Chamá-lo na Page levantava NoMethodError e matava TODA
          # escalada antes de renderizar.
          page.go_to(uri.to_s)
          wait_for_idle_soft(page)
          wait_for_body_stabilize(page)

          pre_check_pdf!(page)

          status = response_status(page)
          html   = page.body.to_s
          title  = page.title.to_s
          body_text = page.evaluate("document.body ? document.body.innerText : ''").to_s
          article = extract_via_readability_js(page)
          {
            title: title,
            final_url: safe_current_url(page) || uri.to_s,
            readability_text: article[:text],
            readability_html: article[:html],
            body_text: body_text,
            html: html,
            status: status
          }
        ensure
          begin
            page&.close
          rescue StandardError
            nil
          end
          begin
            context&.dispose
          rescue StandardError
            nil
          end
        end
      end
    rescue Timeout::Error
      # Travar o timeout inteiro é a assinatura da sessão envenenada. Mesmo que a
      # sonda tenha deixado passar, o dano para aqui: a próxima chamada reconstrói.
      self.class.reset_browser! unless @browser_factory
      raise RenderTimeout
    end

    def wait_for_idle_soft(page)
      page.network.wait_for_idle(duration: IDLE_DURATION, timeout: IDLE_TIMEOUT)
    rescue Ferrum::TimeoutError, StandardError
      nil
    end

    def wait_for_body_stabilize(page)
      prev = 0
      stable = 0
      BODY_STABILIZE_ATTEMPTS.times do
        len = page.evaluate("document.body ? document.body.innerText.length : 0").to_i
        if prev.positive? && (len - prev).abs <= [1, (prev * 0.01).to_i].max
          stable += 1
          break if stable >= 2
        else
          stable = 0
        end
        prev = len
        sleep BODY_STABILIZE_INTERVAL
      end
    rescue StandardError
      nil
    end

    def pre_check_pdf!(page)
      ct = page.network.response&.headers&.[]("Content-Type").to_s
      raise PdfNotSupported if ct.include?("application/pdf")
    rescue PdfNotSupported
      raise
    rescue StandardError
      nil
    end

    def response_status(page)
      page.network.response&.status
    rescue StandardError
      nil
    end

    def safe_current_url(page)
      page.current_url
    rescue StandardError
      nil
    end

    # Retorna { text:, html: } — o HTML é o artigo isolado pelo Readability,
    # usado só quando o chamador pede markdown.
    def extract_via_readability_js(page)
      js = <<~JS
        (function(){
          try {
            #{ReadabilityInjector::READABILITY_JS}
            var docClone = document.cloneNode(true);
            var article = new Readability(docClone).parse();
            if (!article) { return {text: "", html: ""}; }
            return {text: article.textContent || "", html: article.content || ""};
          } catch (e) { return {text: "", html: ""}; }
        })();
      JS
      result = page.evaluate(js)
      return { text: "", html: "" } unless result.is_a?(Hash)

      { text: result["text"].to_s, html: result["html"].to_s }
    rescue StandardError
      { text: "", html: "" }
    end
  end
end
