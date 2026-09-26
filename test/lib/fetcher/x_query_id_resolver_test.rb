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
  end
end
