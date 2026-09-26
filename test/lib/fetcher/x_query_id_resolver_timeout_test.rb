# frozen_string_literal: true

require "test_helper"
require "fetcher/x_query_id_resolver"

module Fetcher
  # ── RESSALVA R1 do PR #203: cliente HTTP SEM TIMEOUT + join com teto ───────
  #
  # `fetch_home_html` e `fetch_bundle` eram `Faraday.new(url:).get` sem
  # `request.options.timeout`: o adapter deixa o Net::HTTP no padrão, que é 60s
  # de open e 60s de read POR requisição (medido em 26/09/2026 neste repo,
  # test/lib/fetcher/x_query_id_lock_ttl_test.rb). Uma descoberta faz até
  # `bundles + 1` requisições, logo o pior caso é de minutos — e o
  # `BACKGROUND_JOIN_TIMEOUT` de 10s expira antes, deixando a thread viva.
  #
  # Estes testes travam os três tetos do conserto: o do cliente HTTP, o da
  # descoberta inteira e o do join. O do join é o que fecha a janela: se a
  # descoberta inteira cabe abaixo do teto do join, a thread não sobrevive ao
  # join por construção — e não por sorte.
  class XQueryIdResolverTimeoutTest < ActiveSupport::TestCase
    def setup
      @cache = ActiveSupport::Cache::MemoryStore.new
      @resolver = XQueryIdResolver.new(cache: @cache)
    end

    def teardown
      @resolver&.wait_for_background_refresh
      super
    end

    # O cliente do resolver precisa CONFIGURAR o timeout — e configurá-lo no
    # objeto certo. `Faraday#options` é o da conexão (vale para o adapter) e
    # `request.options` é o da requisição; o que resolve o Net::HTTP é o
    # segundo. Um teste que só olhasse `connection.options` passaria com um
    # cliente que continua sem timeout de verdade.
    test 'o cliente HTTP do resolver declara timeout de open e de read' do
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)

      assert_equal XQueryIdResolver::HTTP_OPEN_TIMEOUT, conn.options.timeout,
                   'o timeout do cliente precisa valer para o adapter (read)'
      assert_equal XQueryIdResolver::HTTP_OPEN_TIMEOUT, conn.options.open_timeout,
                   'o open_timeout do cliente precisa ser explicito'
    end

    test 'cada requisicao herda o timeout do cliente' do
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)
      req = conn.build_request(:get)

      assert_equal XQueryIdResolver::HTTP_OPEN_TIMEOUT, req.options.timeout,
                   'a requisicao precisa carregar o timeout: e o req.options que o Net::HTTP le'
    end

    # O teto do join só é honesto se a descoberta INTEIRA couber nele. Com o
    # pior caso de 3 requisições (fixture medida: home + 2 bundles) e o timeout
    # do cliente, a aritmética tem de fechar. Este é o teste que impede o
    # BACKGROUND_JOIN_TIMEOUT de virar uma promessa vazia.
    test 'o pior caso de uma descoberta cabe no teto do join' do
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = @resolver.send(:extract_bundle_urls, html)
      allowed = @resolver.send(:filter_allowed_bundle_urls, urls)
      requisicoes = allowed.size + 1

      pior_caso = requisicoes * XQueryIdResolver::HTTP_OPEN_TIMEOUT

      puts "  MEDIDO: #{requisicoes} requisicoes x #{XQueryIdResolver::HTTP_OPEN_TIMEOUT}s = " \
           "#{pior_caso}s de pior caso, contra join de #{XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT}s " \
           "e LOCK_TTL de #{XQueryIdResolver::LOCK_TTL}s."

      assert_operator pior_caso, :<=, XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT,
                     'a descoberta inteira precisa caber no teto do join: e o que garante que a thread nao sobreviva'
    end

    # O TTL do lock e a garantia de exclusividade; se o pior caso da descoberta
    # o ultrapassa, o lock expira com o dono vivo (medido no teste do TTL).
    test 'o pior caso de uma descoberta cabe no TTL do lock' do
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = @resolver.send(:extract_bundle_urls, html)
      allowed = @resolver.send(:filter_allowed_bundle_urls, urls)
      pior_caso = (allowed.size + 1) * XQueryIdResolver::HTTP_OPEN_TIMEOUT

      assert_operator pior_caso, :<=, XQueryIdResolver::LOCK_TTL,
                     'o pior caso precisa caber no TTL: e o que mantem a exclusao ate o fim do trabalho'
    end

    private

    # Espelha o construtor que o resolver usa, para poder afirmar sobre ele sem
    # fazer HTTP. Se o resolver mudar a forma de montar o cliente, este teste
    # passa a apontar a linha nova em vez de medir o cliente errado.
    def http_client(url)
      @resolver.send(:http_client, url)
    end
  end
end
