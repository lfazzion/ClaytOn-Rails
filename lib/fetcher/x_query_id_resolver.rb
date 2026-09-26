# frozen_string_literal: true

module Fetcher
  # Solução viva de query ID do X: extrai queryId/operationName dos bundles webpack
  # do X (x.com/home + main.<hash>.js) com cache persistente, soft-TTL 24h,
  # preserva último valor em falha e usa lock de concorrência.
  #
  # Uso:
  #   query_id = Fetcher::XQueryIdResolver.new.resolve('SearchTimeline')
  class XQueryIdResolver
    # queryId conhecido da SearchTimeline. So vale para ela: outra operacao com este id
    # recebe HTTP 422 do X (medido no TweetDetail em 24/09/2026).
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

    # Desfecho de uma resolução, com a CAUSA. `value` é o query id devolvido
    # (mesmo que preservado do cache); `reason` diz o que aconteceu de verdade.
    #
    # Existe porque o retorno cru (uma String) apagava a diferença entre
    # "descobri agora e gravei" e "perdi a corrida e devolvi o que já estava em
    # cache" — e o `RefreshXQueryIdsJob` logava "refresh concluído" nos dois
    # casos. Um refresh que não descobriu nada sumia do log como sucesso.
    # Falha ou limite sempre ditos, nunca fallback silencioso: quem chama decide
    # o nível do log, mas só pode decidir se o desfecho está nomeado.
    #
    # Motivos possíveis:
    #   :discovered         — buscou agora e achou o query id nos bundles
    #   :not_found          — buscou agora, NÃO achou; gravou o PIN de última instância
    #   :not_found_uncached — buscou agora, NÃO achou, e a operação não tem PIN
    #                         (o PIN é do SearchTimeline): NÃO grava nada
    #   :lock_busy          — outro PROCESSO está descobrindo (perdeu a corrida do lock)
    #   :fetching_in_progress— outra THREAD desta instância está buscando
    #   :fresh_cache        — cache fresco, nem saiu para a rede (force: false)
    #   :stale_cache        — serviu valor stale, refresh disparado em background
    #   :failed             — a descoberta explodiu; serviu o último valor conhecido
    Discovery = Struct.new(:reason, :value, :discovered, :error, keyword_init: true) do
      # "Busquei agora?" — o valor gravado é uma descoberta real (não PIN de
      # última instância, não valor preservado).
      def discovered?
        discovered ? true : false
      end
    end

    # TTL do lock de descoberta. ESTE É A GARANTIA de exclusividade, e ela
    # funciona por aritmética, não por primitiva: `discover!` grava o lock com
    # este TTL e não o renova nem o apaga ao terminar (decisão deliberada, ver o
    # `ensure` de `discover_with_outcome!`). A exclusão vale enquanto o TTL não
    # expira, logo a garantia é "a descoberta inteira cabe em LOCK_TTL".
    #
    # MEDIDO em 26/09/2026 (test/lib/fetcher/x_query_id_lock_ttl_test.rb, store
    # REAL SolidCache, não dublê):
    #   - com TTL menor que o fetch, o lock EXPIRA NO MEIO e um segundo
    #     processo entra e busca — a exclusão se perde de verdade, sem erro.
    #   - pior caso por descoberta = `bundles + 1` requisições. No fixture
    #     real são 3; com `HTTP_OPEN_TIMEOUT` de 3s, 9s de pior caso.
    #   - 9s cabe folgadamente nos 60s deste TTL (folga de 6,7x). Antes do
    #     timeout explícito, cada requisição tinha os 60s do Net::HTTP e o
    #     pior caso era de 180s — 3x o TTL, ou seja a garantia era FALSA.
    #
    # Mesmo valor (60s) que o lock usava antes do conserto de 26/09/2026; o que
    # mudou foi ele deixar de ser uma afirmação sem lastro.
    LOCK_TTL = 60

    # Teto do join em `wait_for_background_refresh`. Acima do fetch de home
    # (~1s) e da varredura de bundles (~dezenas de requisições), folgado o
    # bastante para o refresh normal terminar e curto o bastante para um
    # chamador não depender de rede lenta do X.
    BACKGROUND_JOIN_TIMEOUT = 10.0

    # ── Timeout do cliente HTTP (ressalva R1 do PR #203, medido) ────────────
    # Antes este número não existia: `Faraday.new(url:).get` sem
    # `request.options.timeout` deixa o Net::HTTP no padrão — 60s de open e 60s
    # de read POR requisição (medido neste repo em 26/09/2026). A descoberta faz
    # `bundles + 1` requisições, logo o pior caso era de MINUTOS: o lock de 60s
    # expirava com o dono ainda trabalhando (medido em
    # test/lib/fetcher/x_query_id_lock_ttl_test.rb) e o join de 10s expirava
    # com a thread viva.
    #
    # 3s por requisição: folgado para a latência normal do X, apertado o
    # bastante para que o pior caso da descoberta (3 requisições no fixture
    # medido = 9s) caiba dentro dos dois tetos. A aritmética é travada por
    # teste em test/lib/fetcher/x_query_id_resolver_timeout_test.rb — mudar
    # este número sem mudar a descoberta quebra o teste, que é o ponto.
    HTTP_OPEN_TIMEOUT = 3
    HTTP_READ_TIMEOUT = 3

    # TTL do lock que ESTA execução usa. Existe como método (e não só a
    # constante) para que a MEDIÇÃO da garantia possa usar um TTL curto e
    # terminar em segundos — ver test/lib/fetcher/x_query_id_lock_ttl_test.rb.
    # O valor padrão é o de produção; sobrescrever é para teste.
    def lock_ttl
      LOCK_TTL
    end

    attr_reader :cache

    def current_pin
      PIN
    end

    def pin_for(operation_name)
      PIN if operation_name == 'SearchTimeline'
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

    # API de compatibilidade: devolve só a String, como antes. Quem precisa
    # saber o QUE aconteceu (se descobriu, se perdeu a corrida) usa
    # `resolve_with_outcome` — o retorno cru apaga essa diferença.
    def resolve(operation_name, force: false)
      resolve_with_outcome(operation_name, force: force).value
    end

    # Mesmo caminho de `resolve`, mas devolve um `Discovery` com a CAUSA do
    # desfecho. Ver `Discovery` para os motivos possíveis.
    def resolve_with_outcome(operation_name, force: false)
      cache_key = "fetcher:x_query_id:#{operation_name}"
      envelope = @cache.read(cache_key)

      # Cache fresco sem force: retorna imediatamente
      if envelope && fresh_envelope?(envelope) && !force
        return outcome(:fresh_cache, envelope[:query_id])
      end

      # Se não tem cache, descobre e retorna PIN se falhar
      if envelope.nil?
        # `pin_for` (frente X) em vez do `PIN` cru.
        return discover_with_outcome!(operation_name)
      end

      # force: true -> forca discover! de verdade, preserva ultimo em falha
      if force
        begin
          return discover_with_outcome!(operation_name)
        rescue StandardError => e
          # Falha ou limite sempre ditos: a causa vai no desfecho, não some.
          return outcome(:failed, envelope[:query_id], error: e)
        end
      end

      # Cache stale: retorna último valor, dispara refresh async
      if stale_envelope?(envelope)
        spawn_background_refresh(operation_name)
        return outcome(:stale_cache, envelope[:query_id])
      end

      # Falha inesperada: retorna último valor
      outcome(:failed, envelope[:query_id])
    rescue StandardError => e
      # Em qualquer falha, preserva último valor conhecido.
      # Desfecho nomeado (main) + PIN escopado por operação (frente X): o PIN
      # só vale para a SearchTimeline, então uma operação que ele não cobre
      # recebe nil em vez do id que o X rejeita com 422.
      outcome(:failed, envelope&.dig(:query_id) || pin_for(operation_name), error: e)
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
      discover_with_outcome!(operation_name).value
    end

    # Coração da descoberta, com o desfecho nomeado. `discover!` é a casca que
    # devolve só a String.
    #
    # O ponto que o PR #203 mudou e que este card fecha: quando a aquisição
    # atômica falha (`unless_exist` devolveu false), o retorno cru era o valor
    # em cache — idêntico ao valor de quem REALMENTE descobriu e gravou. O
    # chamador não tinha como distinguir "descobri" de "perdi a corrida", e o
    # job logava sucesso nos dois. Aqui o desfecho carrega a diferença.
    def discover_with_outcome!(operation_name)
      lock_key = "fetcher:x_query_id_lock:#{operation_name}"
      cache_key = "fetcher:x_query_id:#{operation_name}"
      token = SecureRandom.hex(8)

      @mutex.synchronize do
        # Se já há fetch em andamento NESTA instância, quem perdeu a corrida
        # não faz fetch: devolve o valor em cache (se houver) e deixa o
        # vencedor terminar.
        if @fetching
          cached = @cache.read(cache_key)&.dig(:query_id)
          return outcome(:fetching_in_progress, cached || pin_for(operation_name), discovered: false)
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
        unless @cache.write(lock_key, token, unless_exist: true, expires_in: lock_ttl)
          # Lock ocupado: NÃO busca. Este desfecho é o que o conserto do
          # lock tornou possível nomear — `discovered: false` diz ao chamador
          # que o valor abaixo é o que JÁ estava em cache, não uma descoberta.
          cached = @cache.read(cache_key)&.dig(:query_id)
          return outcome(:lock_busy, cached || pin_for(operation_name), discovered: false)
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
        # PIN de última instância, ESCOPADO por operação (frente X): o PIN só
        # vale para a SearchTimeline (medido no TweetDetail em 24/09/2026: outra
        # operação com este id leva HTTP 422). Para as demais, `fallback` é nil
        # e nada inventado pode entrar no cache.
        fallback = pin_for(operation_name)

        if query_id.nil? && fallback
          # Desfecho nomeado (main, PR #203) preservado: o PIN é um id REAL e
          # testado desta operação, então cachear é honesto — o `reason` diz
          # que foi PIN e o job anuncia isso no log em vez de chamar de
          # sucesso. 25h de valor conhecido > redescoberta a cada chamada.
          @cache.write(cache_key, envelope_for(fallback), expires_in: 25 * 3600)
          return outcome(:not_found, fallback, discovered: false)
        end

        # Não achou nos bundles e o PIN não cobre esta operação: NADA vai para o
        # cache, para não servir 25h de valor inventado (frente X). O desfecho
        # continua NOMEADO (main) — a diferença para o `:not_found` acima é o
        # que ficou gravado, e `discovered?` é false nos dois.
        if query_id.nil?
          return outcome(:not_found_uncached, nil, discovered: false)
        end

        @cache.write(cache_key, envelope_for(query_id), expires_in: 25 * 3600)

        # Buscou agora e achou: `discovered: true`. O ramo `:not_found` que citava
        # PIN saiu daqui para os dois `if` acima — o PIN escopado por operação
        # (frente X) tem de ser decidido ANTES de gravar.
        outcome(:discovered, query_id, discovered: true)
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

    def outcome(reason, value, discovered: false, error: nil)
      Discovery.new(reason: reason, value: value, discovered: discovered, error: error)
    end

    # Envelope de cache do query id, com a janela de validade de 24h e o TTL
    # de 25h. Extraído porque o caminho agora grava em DOIS pontos
    # (`:not_found` com o PIN e `:discovered` com o id real) e os dois têm de
    # usar a MESMA aritmética — divergir aí seria a janela de TTL fingindo
    # ser uma.
    def envelope_for(query_id)
      {
        query_id: query_id,
        fetched_at: Time.now.to_i,
        stale_at: Time.now.to_i + 24 * 3600
      }
    end

    # Sem sessao, x.com/home alterna 200 e 307 para a tela de login; com a sessao do jar, 200.
    # E o cliente é o de timeout EXPLICITO (main, PR #203): os dois lados
    # vivem juntos — a sessão é o HEADER e o teto é o do `http_client`.
    def fetch_home_html
      cookies = Fetcher::CookieJar.for('x.com').map { |c| "#{c['name']}=#{c['value']}" }
      headers = cookies.empty? ? {} : { 'Cookie' => cookies.join('; ') }
      req = http_client(HOME_URL, headers: headers).get
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
      req = http_client(url).get
      raise "HTTP #{req.status}" unless req.success?

      req.body
    end

    # Cliente HTTP do resolver, com timeout EXPLICITO.
    #
    # O detalhe que faz este método existir: em Faraday, `connection.options`
    # e `request.options` não são o mesmo objeto. É `request.options.timeout` que
    # o faraday-net_http lê para aplicar `read_timeout` no Net::HTTP, e é
    # `request.options.open_timeout` que vira `open_timeout`
    # (faraday-net_http-3.4.4/lib/faraday/adapter/net_http.rb:153-163). Setar
    # só `connection.options` produz um cliente que PARECE ter timeout e
    # continua com os 60s do Net::HTTP — por isso os dois lados são explícitos.
    #
    # O `headers:` é opcional e existe para a frente X: a descoberta de
    # `x.com/home` precisa da sessão do jar no cabeçalho, e passar header pelo
    # construtor do Faraday (e não pelo `.get`) é o que garante que ele não
    # substitui nem as opções de timeout.
    def http_client(url, headers: {})
      Faraday.new(url: url, headers: headers) do |conn|
        conn.options.timeout = HTTP_READ_TIMEOUT
        conn.options.open_timeout = HTTP_OPEN_TIMEOUT
      end
    end
  end
end
