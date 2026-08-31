# frozen_string_literal: true

require 'test_helper'
require 'fetcher/x_query_id_resolver'

module Fetcher
  class XQueryIdResolverTest < ActiveSupport::TestCase
    def setup
      @cache = ActiveSupport::Cache::MemoryStore.new
      @resolver = XQueryIdResolver.new(cache: @cache)
      @home_html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      @bundle_js = File.read(Rails.root.join('test/fixtures/x/main_bundle_with_search_timeline.js'))
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
  end
end
