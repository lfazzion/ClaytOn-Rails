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

    # TTL do lock de descoberta. Cobre a descoberta com folga (o fetch de
    # home + a varredura dos bundles) para o lock não expirar no meio do
    # trabalho; passados 60s, o lock é considerado órfão e outra instância
    # pode tentar de novo. Mesmo valor (60s) que o lock usava antes do
    # conserto de 26/09/2026.
    LOCK_TTL = 60

    # Teto do join em `wait_for_background_refresh`. Acima do fetch de home
    # (~1s) e da varredura de bundles (~dezenas de requisições), folgado o
    # bastante para o refresh normal terminar e curto o bastante para um
    # chamador não depender de rede lenta do X.
    BACKGROUND_JOIN_TIMEOUT = 10.0

    attr_reader :cache

    def current_pin
      PIN
    end

    def initialize(cache: nil)
      @cache = cache || Rails.cache
      @mutex = Mutex.new
      @fetching = false
      # Threads de refresh em background disparadas por `resolve` (cache stale).
      # São guardadas por referência para poderem ser ESPERADAS: uma thread
      # solta (fire-and-forget) sobrevive ao chamador e continua usando o
      # cache depois que o chamador já terminou. Ver `wait_for_background_refresh`.
      @threads_mutex = Mutex.new
      @background_refreshes = []
    end

    # Espera os refreshes em background disparados por esta instância e devolve
    # quantos ainda estavam pendentes. Não estoura: uma thread que travou não
    # pode segurar o chamador para sempre, então o join tem teto de tempo.
    #
    # Serve a dois consumidores legítimos:
    #  - shutdown ordenado: um processo que vai morrer não deixa a thread
    #    de descoberta no ar;
    #  - teste: o teste do lock precisa que o refresh do teste ANTERIOR já
    #    tenha terminado antes de contar os seus próprios fetches, senão o
    #    fetch alheio cai no contador deste teste.
    def wait_for_background_refresh(timeout: BACKGROUND_JOIN_TIMEOUT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        # Só as threads VIVAS interessam; as que já terminaram são descartadas
        # aqui, senão a lista cresceria para sempre (uma entrada por refresh) e
        # esta chamada nunca veria a lista vazia.
        waiting = @threads_mutex.synchronize do
          @background_refreshes.select! { |thread| thread.alive? }
          @background_refreshes.dup
        end
        break if waiting.empty?

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        # `join` re-levanta a exceção da thread; os erros já são tratados
        # dentro do corpo do refresh, então isto é só rede de segurança.
        waiting.each do |thread|
          begin
            thread.join(remaining)
          rescue StandardError => e
            Rails.logger.warn "[XQueryIdResolver] refresh em background falhou: #{e.class}: #{e.message}"
          end
        end
      end

      @threads_mutex.synchronize { @background_refreshes.size }
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
        spawn_background_refresh(operation_name)
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

    # Dispara o refresh de descoberta em background e GUARDA a thread para que
    # possa ser esperada por `wait_for_background_refresh`.
    #
    # Antes (26/09/2026) era um `Thread.new` solto, sem referência. E era
    # exatamente isso que produzia o flake do CI: a thread sobrevivia ao
    # `resolve` que a criou e fazia o GET de descoberta a qualquer momento
    # depois — inclusive dentro do teste SEGUINTE, cujo stub da mesma URL
    # (WebMock indexa por URL, não por teste) somava esse fetch alheio no
    # contador daquele teste. O teste do lock via "2 em vez de 1" com a
    # exclusividade do lock funcionando perfeitamente.
    def spawn_background_refresh(operation_name)
      # O lock de descoberta decide sozinho se vale a pena buscar: se outro
      # processo já está buscando, `discover!` devolve o valor em cache e
      # termina sem tocar a rede.
      thread = Thread.new do
        begin
          discover!(operation_name)
        rescue StandardError => e
          Rails.logger.warn "[XQueryIdResolver] refresh em background falhou: #{e.class}: #{e.message}"
        end
      end

      @threads_mutex.synchronize { @background_refreshes << thread }
      thread
    end

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
      cache_key = "fetcher:x_query_id:#{operation_name}"
      token = SecureRandom.hex(8)

      @mutex.synchronize do
        # Se já há fetch em andamento NESTA instância, quem perdeu a corrida
        # não faz fetch: devolve o valor em cache (se houver) e deixa o
        # vencedor terminar.
        if @fetching
          return @cache.read(cache_key)&.dig(:query_id)
        end

        # ADQUIRIÇÃO ATÔMICA do lock (bug do CI, 26/09/2026): o par
        # read+write que vivia aqui (read na linha 143, write na 147) são DUAS
        # operações separadas sobre o cache COMPARTILHADO. Em produção o store
        # é o SolidCache (production.rb:14) — cada operação é uma transação
        # separada, então existia uma janela em que o lock ainda não estava no
        # cache e um segundo processo (o job roda em `jobs`, o scraper em
        # `app`) adquiria o mesmo lock: dois fetches de descoberta contra o X
        # ao mesmo tempo. O `@mutex` é POR INSTÂNCIA e nunca fechou essa
        # janela.
        #
        # `unless_exist: true` resolve teste-e-escrita num passo só: o STORE
        # decide, e só quem consegue gravar (devolve `true`) continua. Sem isso
        # havia uma janela entre o read e o write em que o lock ainda não
        # existia e outro processo o adquiria — dois fetches contra o X.
        # Padrão já usado na casa em lib/scraping/fetch_pacer.rb:23 e
        # app/jobs/sentiment_analysis_job.rb:144.
        unless @cache.write(lock_key, token, unless_exist: true, expires_in: LOCK_TTL)
          # Lock ocupado: não busca. Devolve o que houver em cache; se ainda
          # não houver (o vencedor ainda está buscando), o chamador cai no
          # fallback de `resolve`/no PIN de `discover!`.
          return @cache.read(cache_key)&.dig(:query_id)
        end

        @fetching = true
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

        envelope = {
          query_id: query_id || PIN,
          fetched_at: Time.now.to_i,
          stale_at: Time.now.to_i + 24 * 3600
        }
        @cache.write(cache_key, envelope, expires_in: 25 * 3600)

        query_id || PIN
      ensure
        @mutex.synchronize { @fetching = false }
        # O lock NÃO é apagado aqui, e essa é a diferença deliberada em
        # relação ao conserto anterior (26/09/2026). O TTL continua sendo a
        # janela de exclusão, como o código original fazia: apagar o lock ao
        # terminar faria cada thread que estava NA FILA adquirir o lock em
        # seguida e fazer o seu próprio fetch — medido: 5 threads na mesma
        # instância passaram a buscar 5 vezes (antes do conserto: 1).
        #
        # Quem perde a corrida (`unless_exist` devolveu false) devolve o valor
        # em cache; o TTL curto (60s) é o que reabre a descoberta depois.
        # O `@fetching` por instância continua barrando o fetch paralelo DENTRO
        # desta instância.
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
