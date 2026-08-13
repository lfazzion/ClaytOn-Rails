# frozen_string_literal: true

require "digest"
require "yaml"
require "timeout"
require_relative "ssrf_guard"
require_relative "rebinding_guard"
require_relative "ttl_policy"
require_relative "bot_detection"
require_relative "readability_injector"
require_relative "host_rate_limiter"

module Fetcher
  class PageFetcher
    RATE_LIMIT_MAX    = 5
    CACHE_KEY_PREFIX  = "page_fetch:v1"
    # Mutex de CLASSE, avaliado no load: `@browser_mutex ||= Mutex.new` era
    # corrida real — dois threads podiam criar mutex diferentes e ambos entrar
    # em `synchronize`, cada um com o próprio lock, e construir dois browsers
    # (um perdido, sem `quit`, vazando CDP) ou dar `quit` no browser alheio.
    BROWSER_MUTEX     = Mutex.new
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
    class PythonFetchError < FetchError
      def initialize(original_class)
        super("fallback Python falhou: #{original_class}")
      end
    end
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
      def call(url_string, include_html: false, max_chars: ReadabilityInjector::DEFAULT_MAX_CHARS)
        new.call(url_string, include_html: include_html, max_chars: max_chars)
      end

      def browser
        BROWSER_MUTEX.synchronize do
          discard_locked! if @browser && (expired? || !alive?(@browser))

          @browser ||= begin
            @browser_started_at = Time.current
            build_browser
          end
        end
      end

      def reset_browser!
        BROWSER_MUTEX.synchronize { discard_locked! }
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

      # Só chamar com BROWSER_MUTEX já retido — Mutex do Ruby não é reentrante.
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

    # `rate_limit: false` é para quem JÁ cobrou o balde antes (o ExtractService
    # cobra com o teto do canal em `extract`); cobrar de novo contaria em dobro.
    def initialize(browser_factory: nil, clock: Time, rate_limit: true)
      @browser_factory = browser_factory
      @clock = clock
      @rate_limit = rate_limit
    end

    # `include_html: true` acrescenta `article_html` ao payload — o HTML que o
    # Readability.js isolou, insumo do conversor de markdown do /internal/extract.
    # `max_chars:` vai ao ReadabilityInjector: sem ele o default de 8k cortava o
    # caminho browser calado (o ExtractService passa o teto da casa).
    def call(url_string, include_html: false, max_chars: ReadabilityInjector::DEFAULT_MAX_CHARS)
      resolution = SsrfGuard.resolve!(url_string)
      uri = resolution.uri
      host = uri.host.to_s.downcase

      check_cooldown!(host)

      cache_key = build_cache_key(uri, include_html: include_html)
      if (cached = Rails.cache.read(cache_key))
        return cached.merge(cache_age_seconds: (@clock.current - cached[:fetched_at]).to_i)
      end

      # Depois do cache de propósito: acerto de cache não toca o site, e cobrar
      # o balde por ele derrubava a 6a pergunta do minuto com 1 fetch real + 5
      # hits (o ExtractService já acertou essa ordem; o PageFetcher divergia).
      check_rate_limit!(host) if @rate_limit

      raw = if hard_domain?(host)
              fetch_via_python(uri)
            else
              fetch_via_ferrum(uri)
            end

      # O Chrome (e o nodriver) seguem redirects por conta própria — a validação
      # pré-fetch só cobriu a URL inicial. Revalidar o destino final é o que
      # impede um `302 -> http://127.0.0.1/` de virar payload de resposta
      # (`resolve!` levanta Blocked se o destino resolver para IP privado).
      revalidate_final_url!(raw[:final_url], uri)
      # O Chrome re-resolve o hostname sozinho e pode conectar em QUALQUER IP
      # público do conjunto (CDN multi-registro, dual-stack A/AAAA) — exigir o
      # `ips.first` derrubava tráfego legítimo. O cheque pós-navegação garante
      # só o que importa: o documento não pode ter vindo de IP
      # privado/loopback/metadata (rebinding de verdade, TTL curto).
      assert_document_ip!(raw[:document_ip], raw[:final_url])

      if bot_blocked?(raw, host)
        reason = raw[:title].to_s[0, 80]
        BotDetection.cooldown!(host, reason: reason.empty? ? "block detected" : reason)
        raise BotBlocked.new(host, reason)
      end

      extracted = ReadabilityInjector.extract(
        readability_text: raw[:readability_text],
        body_text: raw[:body_text],
        fallback_html: raw[:html].to_s,
        live: TtlPolicy.live_host?(host),
        max_chars: max_chars
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
      begin
        Rails.cache.write(cache_key, payload, expires_in: ttl)
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::PageFetcher] falha ao gravar cache: #{e.class}"
      end
      payload
    end

    private

    def check_rate_limit!(host)
      raise RateLimited.new(host) if HostRateLimiter.exceeded?(host, max: RATE_LIMIT_MAX)
    end

    # Devolve a Resolution do destino (nil quando não houve redirect) para o
    # cheque de DNS rebinding comparar o IP que o Chrome usou de fato.
    def revalidate_final_url!(final_url, original_uri)
      final = final_url.to_s
      return nil if final.empty? || final == original_uri.to_s

      SsrfGuard.resolve!(final)
    end

    # `remote_ip` é o IP que o Chrome usou no documento principal. A validação
    # pré-fetch (`SsrfGuard.resolve!`) já garantiu que TODOS os IPs do host são
    # públicos; o Chrome re-resolve sozinho e pode conectar em qualquer IP
    # público do conjunto (CDN com vários registros, dual-stack A/AAAA) — por
    # isso exigir igualdade com `resolution.ip` (= `ips.first`) derrubava
    # tráfego legítimo. O que importa: o documento não pode ter vindo de IP
    # privado/loopback/metadata (rebinding de verdade). Sem o campo (CDP
    # antigo, caminho Python) o cheque desliga com log, melhor que derrubar o
    # caminho.
    def assert_document_ip!(remote_ip, final_url)
      return if remote_ip.to_s.empty?
      return unless SsrfGuard.ip_blocked?(remote_ip)

      Rails.logger.warn "[Fetcher::PageFetcher] rebinding em #{final_url}: " \
                        "Chrome conectou em IP bloqueado/privado #{remote_ip}"
      raise SsrfGuard::Blocked.new(
        "DNS rebinding detectado em #{final_url}: Chrome conectou em IP bloqueado/privado #{remote_ip}"
      )
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
        # O nodriver não expõe o IP do documento — o cheque de rebinding
        # desliga neste caminho (assert_document_ip! sai cedo com nil).
        document_ip: nil,
        readability_text: nil,
        readability_html: nil,
        body_text: result[:content].to_s,
        html: "",
        status: 200
      }
    rescue Timeout::Error, ScrapingServices::RateLimitError => e
      raise PythonFetchError.new(e.class.name)
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
          # O assinante de `Network.responseReceived` entra ANTES do go_to: é a
          # única forma de pegar o remoteIPAddress do documento principal, e é
          # ele que fecha a janela de DNS rebinding deste caminho.
          document_ip = RebindingGuard.capture_document_remote_ip(page) do
            page.go_to(uri.to_s)
            wait_for_idle_soft(page)
            wait_for_body_stabilize(page)
          end

          pre_check_pdf!(page)

          status = response_status(page)
          html   = page.body.to_s
          title  = page.title.to_s
          body_text = page.evaluate("document.body ? document.body.innerText : ''").to_s
          article = extract_via_readability_js(page)
          {
            title: title,
            final_url: safe_current_url(page) || uri.to_s,
            document_ip: document_ip,
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
