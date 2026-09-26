# frozen_string_literal: true

require 'test_helper'
require 'fetcher/x_query_id_resolver'

module Fetcher
  # Cache remoto para o teste do lock: read e write custam IO. É o SolidCache
  # (config/environments/production.rb:14) em produção, onde cada operação é
  # uma transação separada — modelar esse custo é o que torna visível a janela
  # entre o teste e a escrita do lock, sem dormir dentro do código de produção.
  #
  # Classe COM nome de propósito: o `LocalCache` que o MemoryStore faz prepend
  # deriva a chave local de `self.class.name`, e uma classe anônima daria
  # `nil.underscore` (erro medido ao montar o teste com Class.new).
  class SlowRemoteCacheStore < ActiveSupport::Cache::MemoryStore
    def read(key, options = nil)
      sleep 0.05
      super
    end

    def write(key, value, **options)
      sleep 0.05
      super
    end
  end

  class XQueryIdResolverTest < ActiveSupport::TestCase
    def setup
      @cache = ActiveSupport::Cache::MemoryStore.new
      @resolver = XQueryIdResolver.new(cache: @cache)
      @home_html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      @bundle_js = File.read(Rails.root.join('test/fixtures/x/main_bundle_with_search_timeline.js'))
    end

    # O teste do lock (e o de refresh) contam fetches de descoberta num contador
    # que pertence ao seu próprio stub. `resolve` com cache stale dispara um
    # refresh em BACKGROUND (x_query_id_resolver.rb, `resolve`); essa thread não
    # era joinada e sobrevivia ao teste que a criou, fazendo o GET de home
    # dentro do teste SEGUINTE — cujo stub da mesma URL (o WebMock indexa por
    # URL, não por teste) somava o fetch alheio no contador daqui. Era o
    # "esperado 1, veio 2" do CI (run 36203673307), reproduzido em 1 de 20
    # rodadas sob carga.
    #
    # Esvaziar o que sobrou da thread de fundo no fim de CADA teste fecha a
    # janela sem afrouxar a asserção: o teste do lock continua exigindo
    # exatamente 1 fetch, agora medindo só o seu.
    def teardown
      @resolver&.wait_for_background_refresh
      super
    end

    test 'PIN inicial padrao e flaR-PUMshxFWZWPNpq4zA' do
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', XQueryIdResolver::PIN
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', @resolver.current_pin
    end

    test 'cache fresco serve valor sem bater na rede' do
      @cache.write(
        'fetcher:x_query_id:SearchTimeline',
        { query_id: 'cached-id-123', fetched_at: Time.now.to_i, stale_at: Time.now.to_i + 86_400 }
      )

      # Sem stubs de rede — se tentar chamar rede, WebMock lanca erro
      result = @resolver.resolve('SearchTimeline')
      assert_equal 'cached-id-123', result
    end

    test 'soft-stale serve ultimo valor e dispara refresh em background' do
      stale_envelope = {
        query_id: 'stale-id-456',
        fetched_at:Time.now.to_i - 90_000,
        stale_at: Time.now.to_i - 3_600
      }
      @cache.write('fetcher:x_query_id:SearchTimeline', stale_envelope)

      stub_request(:get, 'https://x.com/home')
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      # Deve retornar o valor stale imediatamente para nao bloquear o chamador
      result = @resolver.resolve('SearchTimeline')
      assert_equal 'stale-id-456', result
    end

    test 'ultimo valor e preservado em falha de rede ou 404 de bundles' do
      @cache.write(
        'fetcher:x_query_id:SearchTimeline',
        { query_id: 'fallback-id-789', fetched_at: Time.now.to_i - 90_000, stale_at: Time.now.to_i - 3_600 }
      )

      stub_request(:get, 'https://x.com/home').to_timeout

      result = @resolver.resolve('SearchTimeline', force: true)
      assert_equal 'fallback-id-789', result, 'Em falha de refresh, deve preservar ultimo valor conhecido'
    end

    test 'quando cache vazio e rede falha, recorre ao PIN inicial' do
      stub_request(:get, 'https://x.com/home').to_return(status: 500, body: 'Server Error')

      result = @resolver.resolve('SearchTimeline', force: true)
      assert_equal XQueryIdResolver::PIN, result
    end

    test 'regex positiva extrai queryId e operationName de bundle webpack' do
      extracted = @resolver.extract_query_ids(@bundle_js)
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', extracted['SearchTimeline']
      assert_equal 'aB3_cD4-eF5gH6iJ7kL8mN', extracted['UserByScreenName']
    end

    test 'regex negativa rejeita strings maliciosas ou js sem queryId valido' do
      invalid_js = 'var foo = { queryId: ""; operationName: "SearchTimeline" };'
      assert_nil @resolver.extract_query_id(invalid_js, 'SearchTimeline')

      noise_js = 'var x = "queryId:fake,operationName:other";'
      assert_nil @resolver.extract_query_id(noise_js, 'SearchTimeline')
    end

    test 'allowlist filtra apenas bundles permitidos pelo core chunk patterns' do
      urls = [
        'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js',
        'https://abs.twimg.com/responsive-web/client-web/bundle.LoggedInMain.b0c4488a.js',
        'https://abs.twimg.com/responsive-web/client-web/disallowed.UnknownChunk.99999999.js',
        'https://malicious.com/evil.js'
      ]

      allowed = @resolver.filter_allowed_bundle_urls(urls)
      assert_includes allowed, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js'
      assert_includes allowed, 'https://abs.twimg.com/responsive-web/client-web/bundle.LoggedInMain.b0c4488a.js'
      refute_includes allowed, 'https://abs.twimg.com/responsive-web/client-web/disallowed.UnknownChunk.99999999.js'
      refute_includes allowed, 'https://malicious.com/evil.js'
    end

    test 'lock de concorrencia impede multiplos refreshes simultaneos' do
      called_count = 0
      stub_request(:get, 'https://x.com/home')
        .to_return do
          called_count += 1
          { status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' } }
        end
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      threads = Array.new(5) do
        Thread.new { @resolver.fetch_fresh('SearchTimeline') }
      end
      threads.each(&:join)

      assert_equal 1, called_count, 'Apenas 1 processo/thread deve executar o fetch de descoberta sob lock'
    end

    # Regressão do flake do CI (26/09/2026, run 36203673307). O lock acima
    # protege a INSTÂNCIA (um só `Thread.new` por `fetch_fresh`), mas ele não
    # prova a garantia que a produção precisa: o job roda no processo `jobs` e o
    # scraper no `app`, cada um com sua própria instância e seu próprio
    # `@mutex`. O lock antigo era read (:143) seguido de write (:147) — duas
    # operações separadas sobre o cache compartilhado, com uma janela real
    # entre elas em que o lock ainda não existia.
    test 'lock de descoberta exclui entre instancias diferentes (cenario de producao: jobs e app)' do
      slow_cache = SlowRemoteCacheStore.new

      calls = 0
      calls_lock = Mutex.new
      dentro = Queue.new
      liberar = Queue.new

      # Duas instâncias = dois processos, cada uma com seu mutex.
      resolvers = Array.new(2) do
        r = XQueryIdResolver.new(cache: slow_cache)
        r.define_singleton_method(:fetch_home_html) do
          calls_lock.synchronize { calls += 1 }
          dentro << :in
          liberar.pop # segura o fetch dentro da janela do lock
          ''
        end
        r.define_singleton_method(:fetch_bundle) { |_url| '' }
        r
      end

      threads = resolvers.map { |r| Thread.new { r.fetch_fresh('SearchTimeline') } }
      dentro.pop # o primeiro comprou o lock e entrou no fetch
      sleep 0.2  # tempo do segundo percorrer read+write sem bloqueio
      3.times { liberar << :liberar }
      threads.each(&:join)

      assert_equal 1, calls,
                   'Duas instancias executaram o fetch de descoberta ao mesmo tempo — ' \
                   'read e write do lock sao operacoes separadas sobre o cache compartilhado. ' \
                   'Em producao isso sao dois fetches contra o X.'
    end

    test 'refresh em background nao atravessa a fronteira do teste seguinte' do
      # O `teardown` desta classe espera a thread de refresh. Sem ele, o
      # "soft-stale" acima dispara uma thread solta que faz o GET /home dentro
      # do TESTE SEGUINTE, cujo stub da mesma URL (WebMock indexa por URL)
      # contaria o fetch alheio. Este teste trava esse comportamento.
      stub_request(:get, 'https://x.com/home')
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      @cache.write(
        'fetcher:x_query_id:SearchTimeline',
        { query_id: 'stale-id-456', fetched_at: Time.now.to_i - 90_000, stale_at: Time.now.to_i - 3_600 }
      )

      assert_equal 'stale-id-456', @resolver.resolve('SearchTimeline')

      # Drenar deve incorporar a thread: o que o teardown vai esperar.
      assert_equal 0, @resolver.wait_for_background_refresh,
                   'O refresh em background deveria estar concluido ao fim do teste'
    end

    test 'refresh unico em 404 (force: true) atualiza cache com novo ID descoberto' do
      stub_request(:get, 'https://x.com/home')
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      # Simula 404 chamando com force: true
      new_id = @resolver.resolve('SearchTimeline', force: true)
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', new_id

      cached = @cache.read('fetcher:x_query_id:SearchTimeline')
      assert_not_nil cached
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', cached[:query_id]
    end

    test 'force: true chama discover! de verdade mesmo com cache stale' do
      stale_envelope = {
        query_id: 'stale-id-456',
        fetched_at: Time.now.to_i - 90_000,
        stale_at: Time.now.to_i - 3_600
      }
      @cache.write('fetcher:x_query_id:SearchTimeline', stale_envelope)

      stub_request(:get, 'https://x.com/home')
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      # Com force: true, deve chamar discover! e retornar o novo ID descoberto
      result = @resolver.resolve('SearchTimeline', force: true)
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', result

      # Cache deve ter sido atualizado
      cached = @cache.read('fetcher:x_query_id:SearchTimeline')
      assert_not_nil cached
      assert_equal 'flaR-PUMshxFWZWPNpq4zA', cached[:query_id]
    end

    test 'force: true preserva ultimo valor quando discover! falha' do
      stale_envelope = {
        query_id: 'fallback-id-789',
        fetched_at: Time.now.to_i - 90_000,
        stale_at: Time.now.to_i - 3_600
      }
      @cache.write('fetcher:x_query_id:SearchTimeline', stale_envelope)

      stub_request(:get, 'https://x.com/home').to_timeout

      # Com force: true e falha no discover!, deve preservar o valor anterior
      result = @resolver.resolve('SearchTimeline', force: true)
      assert_equal 'fallback-id-789', result
    end

    # Sem sessao, x.com/home alterna 200 e 307 (tela de login); com a sessao do jar responde 200.
    test 'descoberta pede x.com/home com os cookies da sessao do x.com' do
      Fetcher::CookieJar.stubs(:for).with('x.com').returns(
        [{ 'name' => 'auth_token', 'value' => 'a1' }, { 'name' => 'ct0', 'value' => 'c2' }]
      )
      stub_request(:get, 'https://x.com/home')
        .with(headers: { 'Cookie' => 'auth_token=a1; ct0=c2' })
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })

      assert_equal 'flaR-PUMshxFWZWPNpq4zA', @resolver.resolve('SearchTimeline', force: true)
    end

    # O PIN e o queryId da SearchTimeline: em outra operacao vira pedido invalido (HTTP 422 no TweetDetail).
    test 'falha de descoberta nao entrega o PIN da busca para outra operacao' do
      stub_request(:get, 'https://x.com/home').to_return(status: 307, headers: { 'Location' => 'https://x.com/i/jf/onboarding/web' })

      assert_nil @resolver.resolve('TweetDetail')
    end

    test 'operacao ausente nos bundles nao grava valor inventado no cache' do
      stub_request(:get, 'https://x.com/home')
        .to_return(status: 200, body: @home_html, headers: { 'Content-Type' => 'text/html' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/main.132b4bba.js')
        .to_return(status: 200, body: @bundle_js, headers: { 'Content-Type' => 'application/javascript' })
      stub_request(:get, 'https://abs.twimg.com/responsive-web/client-web/bundle.LoggedInMain.b0c4488a.js')
        .to_return(status: 404)

      assert_nil @resolver.resolve('TweetDetail', force: true)
      assert_nil @cache.read('fetcher:x_query_id:TweetDetail')
    end

    # ── RESPOSTA TRUNCADA PELO TETO TOTAL NÃO VIRA PIN DE 25h (achado 3) ─────
    #
    # O `HTTP_TOTAL_TIMEOUT` de 8s corta a requisição INTEIRA, e o corte chega
    # ao laço de bundles como `Faraday::TimeoutError`, que cai no
    # `rescue StandardError; next` do `discover_with_outcome!`. O laço termina,
    # `query_id` fica nil, e o desfecho era `:not_found` — que GRAVA O PIN por
    # 25h (`expires_in: 25 * 3600`).
    #
    # Ou seja: um bundle lento do X (ou um drip que sobrevive ao read, medido em
    # 37,01s) produzia um PIN cacheado por 25 horas com `reason: :not_found`,
    # e o log dizia "nao encontrada nos bundles apos a busca" — quando a busca
    # nem terminou. O timeout era reportado como ausência do query id, que é a
    # MESMA classe de bug que o #203 fechou: um desfecho nomeado apontando para
    # a causa errada, com um valor de 25h em cima.
    #
    # O teste é END-TO-END de verdade, com o `http_get` real: o bundle sai de um
    # servidor local que faz drip de 1 byte a cada 50ms (cada leitura fica
    # abaixo do `read_timeout` de 3s, então só o teto TOTAL corta), e o
    # `BUNDLE_BASE_URL` é apontado para ele durante o teste. Extrair, filtrar,
    # buscar, cortar e decidir o que vai para o cache são todos o código real.
    test 'bundle cortado pelo teto total nao vira PIN cacheado por 25h' do
      porta = drip_server(intervalo: 0.05, total_aprox: XQueryIdResolver::HTTP_TOTAL_TIMEOUT * 20)
      base_local = "http://127.0.0.1:#{porta}/"

      # `home` responde com UM preload link para o bundle em drip. O padrão
      # "main" casa com "main.drip.js", então o filtro real deixa passar.
      home = %(<html><head><link rel="preload" as="script" href="#{base_local}main.drip.js">) \
             "</head><body></body></html>"

      inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      desfecho, erro = descobrir_com_base_local(base_local, home)
      decorrido = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inicio

      puts "  MEDIDO: bundle em drip cortado pelo teto total de " \
           "#{XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s em #{format('%.2f', decorrido)}s -> " \
           "desfecho=#{desfecho&.reason.inspect} erro=#{erro&.class}"

      # O corte aconteceu de verdade: o teto total, e não uma leitura.
      assert_operator decorrido, :>=, XQueryIdResolver::HTTP_TOTAL_TIMEOUT * 0.9,
                      'a requisicao do bundle deveria ter morrido no teto total, nao antes'
      assert_operator decorrido, :<, XQueryIdResolver::HTTP_TOTAL_TIMEOUT + 2.0,
                      'a requisicao do bundle deveria ter morrido no teto total, nao depois'

      # E o desfecho NÃO pode ser o do PIN: `:not_found` grava 25h de PIN
      #GERADO POR UMA RESPOSTA QUE NÃO CHEGOU AO FIM.
      refute_equal :not_found, desfecho&.reason,
                   'resposta CORTADA pelo teto total nao pode virar :not_found — ' \
                   ':not_found grava o PIN por 25h, e a busca nem terminou'

      cacheado = @cache.read('fetcher:x_query_id:SearchTimeline')
      if cacheado
        refute_equal XQueryIdResolver::PIN, cacheado[:query_id],
                     'o PIN nao pode ser cacheado a partir de uma resposta TRUNCADA: ' \
                     '25h de um id de ultima instancia para um id que existe nos bundles'
      end
    ensure
      @drip_thread&.kill
    end

    # Roda a descoberta real com `BUNDLE_BASE_URL` apontado para o servidor
    # local, e devolve `[desfecho, erro]`. A constante é trocada no lugar e
    # restaurada no `ensure` — o filtro resolve a constante lexicalmente, então
    # uma subclasse com a sua própria NÃO mudaria o que o `allowed_bundle?` do
    # pai lê.
    def descobrir_com_base_local(base_local, home)
      klass = Fetcher::XQueryIdResolver
      original = klass::BUNDLE_BASE_URL
      klass.send(:remove_const, :BUNDLE_BASE_URL)
      klass.const_set(:BUNDLE_BASE_URL, base_local)
      @resolver.stubs(:fetch_home_html).returns(home)
      begin
        [@resolver.send(:discover_with_outcome!, 'SearchTimeline'), nil]
      rescue StandardError => e
        [nil, e]
      end
    ensure
      klass.send(:remove_const, :BUNDLE_BASE_URL)
      klass.const_set(:BUNDLE_BASE_URL, original)
    end

    private

    # Servidor que envia a CABEÇA e depois 1 byte a cada `intervalo` segundos:
    # o drip que sobrevive a qualquer `read_timeout` e que só o teto TOTAL corta.
    def drip_server(intervalo:, total_aprox:)
      require "socket"
      srv = Socket.new(:INET, :STREAM)
      srv.setsockopt(:SOCKET, :REUSEADDR, true)
      srv.bind(Addrinfo.tcp("127.0.0.1", 0))
      srv.listen(4)
      porta = srv.local_address.ip_port
      corpo = (total_aprox / intervalo).ceil
      @drip_thread = Thread.new do
        c, = srv.accept
        c.gets
        c.print "HTTP/1.1 200 OK\r\nContent-Length: #{corpo}\r\nConnection: close\r\n\r\n"
        c.flush
        corpo.times { c.print("."); c.flush; sleep intervalo }
        c.close
      end
      porta
    end
  end
end
