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

    # ── A ARITMÉTICA COMPLETA: open E read, no mesmo relógio ───────────────
    #
    # `open_timeout` e `read_timeout` NÃO são dois tetos independentes: no
    # Net::HTTP uma requisição faz connect (open) -> escrever -> ler a resposta
    # (read) em SEQUÊNCIA, e o pior caso de UMA requisição é a SOMA dos dois.
    # MEDIDO com relógio de parede (scripts/proofs/http_timeout_cumulativo_proof.rb, roda no
    # container do repo, com controle negativo): servidor com open de ~1,0s e
    # read de 1,2s contra tetos de 2,0 e 10,0 devolveu HTTP 200 (2,21s) — as
    # duas fases passando folgadas; contra tetos de 2,0 e 2,0 devolveu
    # Faraday::TimeoutError (2,06s) — open+read somando ~2,2s > teto de 2,0.
    # Sob a semântica MAX (cada fase no seu relógio) o segundo caso seria
    # 1,2s < 2,0 e devolveria 200.
    #
    # Somar só o OPEN (o que os testes anteriores faziam) subestima o pior caso
    # pela metade — e foi por isso que subir o read timeout passava verde.
    #
    # O pior caso é lido do CLIENTE REAL, não das constantes: se `http_client`
    # deixar de declarar um dos dois, `read_effective`/`open_effective` voltam
    # `nil` e o teste falha, em vez de o cálculo silenciosamente continuar valendo
    # um número que o cliente não usa.
    def aritmetica_da_descoberta
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = @resolver.send(:extract_bundle_urls, html)
      allowed = @resolver.send(:filter_allowed_bundle_urls, urls)
      requisicoes = allowed.size + 1

      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)
      read_efetivo = conn.options.timeout
      open_efetivo = conn.options.open_timeout

      # Cliente sem timeout declarado tem `nil`. SOMAR nil estoura com
      # `TypeError` (ruído: não diz que o problema é o cliente), e DESCARTAR o
      # nil (`compact`) é pior: some com o relógio que faltava e a aritmética
      # continua valendo um número que o cliente não usa — foi assim que a
      # remoção do read timeout passou verde nos testes de teto (medido:
      # imprimiu "3s open + 3s read = 3s" e ficou verde). Por isso a ausência
      # vira um valor que FAZ a conta estourar, e não um valor que a esconde.
      por_requisicao = [read_efetivo, open_efetivo].sum do |v|
        # `nil` (sem timeout declarado) vale o pior caso do Net::HTTP: 60s de
        # open e 60s de read. O Net::HTTP sem timeout explícito é de 60/60
        # (medido neste repo), então é o número que o cliente REALMENTE usa.
        v.nil? ? 60 : v
      end
      [requisicoes, por_requisicao, requisicoes * por_requisicao]
    end

    # O cliente precisa declarar o read E o open, e o read precisa ser o
    # `HTTP_READ_TIMEOUT` — a constante que o nome diz. O teste anterior
    # comparava `conn.options.timeout` com `HTTP_OPEN_TIMEOUT`, o que passava
    # com um cliente cujo read viesse da constante errada.
    test 'o cliente declara o read com HTTP_READ_TIMEOUT e o open com HTTP_OPEN_TIMEOUT' do
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)

      assert_equal XQueryIdResolver::HTTP_READ_TIMEOUT, conn.options.timeout,
                   'o read_timeout precisa ser o HTTP_READ_TIMEOUT: e o valor que o Net::HTTP le'
      assert_equal XQueryIdResolver::HTTP_OPEN_TIMEOUT, conn.options.open_timeout,
                   'o open_timeout precisa ser o HTTP_OPEN_TIMEOUT'
    end

    # A garantia do join só é honesta se a descoberta INTEIRA couber nele, e a
    # descoberta inteira é open + read por requisição. Este é o teste que
    # impede o `BACKGROUND_JOIN_TIMEOUT` de virar uma promessa vazia: mudar o
    # read timeout sem mudar o join quebra aqui, que é o ponto.
    test 'o pior caso de uma descoberta (open + read) cabe no teto do join' do
      requisicoes, por_requisicao, pior_caso = aritmetica_da_descoberta
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)

      # O `puts` mostra o que o CLIENTE USA, não as constantes: com o read
      # removido, imprimir as constantes (3s e 3s) descreveria um cliente que
      # não existe. O que o cliente usa aparece como `nil` = 60s do Net::HTTP.
      puts "  MEDIDO: #{requisicoes} requisicoes x (#{conn.options.open_timeout || 'sem timeout'}s open " \
           "+ #{conn.options.timeout || 'sem timeout'}s read = #{por_requisicao}s) = " \
           "#{pior_caso}s de pior caso, contra join de #{XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT}s " \
           "e LOCK_TTL de #{XQueryIdResolver::LOCK_TTL}s."

      # A pré-condição é sobre o que o cliente DECLARA, não sobre a soma: um
      # `por_requisicao > 0` passaria com o read ausente (o open sozinho já dá
      # 3), e foi exatamente esse o furo que deixou a remoção verde.
      refute_nil conn.options.timeout,
                 'o cliente precisa declarar o read timeout: sem ele o Net::HTTP usa 60s e a aritmetica mente'
      refute_nil conn.options.open_timeout,
                 'o cliente precisa declarar o open timeout: sem ele o Net::HTTP usa 60s e a aritmetica mente'
      assert_operator pior_caso, :<=, XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT,
                     'a descoberta inteira precisa caber no teto do join: e o que garante que a thread nao sobreviva'
    end

    # O TTL do lock e a garantia de exclusividade; se o pior caso da descoberta
    # o ultrapassa, o lock expira com o dono vivo (medido no teste do TTL).
    test 'o pior caso de uma descoberta (open + read) cabe no TTL do lock' do
      _requisicoes, _por_requisicao, pior_caso = aritmetica_da_descoberta

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
