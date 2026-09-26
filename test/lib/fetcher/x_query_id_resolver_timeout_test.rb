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
  #
  # ── A ARITMÉTICA, CORRIGIDA (ressalvas Important do #205, card t_cbfa9f27) ──
  #
  # `open_timeout` e `read_timeout` NÃO são um teto só: são DOIS relógios
  # INDEPENDENTES, um por fase. A prova que fecha está em
  # `scripts/proofs/http_timeout_fases_independentes_proof.rb`, com o SYN
  # RETIDO no kernel (fila de accept cheia, sem `accept()`), que de fato atrasa
  # o `connect`:
  #
  #   A  open=5,0 read=10,0 -> HTTP 200            em 3,23s (as duas fases folgadas)
  #   B  open=1,5 read=10,0 -> Net::OpenTimeout  em 1,50s (o read folgado NÃO
  #                                              cobre o connect)
  #   C  open=10,0 read=1,0 -> Net::ReadTimeout  em 3,10s (o open folgado NÃO
  #                                              cobre a resposta)
  #
  # B e C juntos derrubam a semântica "cumulativa" do #205: se o read fosse
  # orçamento SOMADO ao open, o read de 10,0s de B cobriria o open de ~2s e B
  # PASSARIA. A soma do pior caso vem da SEQUENCIALIDADE das fases
  # (connect → escrever → ler), não de dois orçamentos que se acumulam.
  #
  # E, mais forte que isso: `read_timeout` é teto POR LEITURA, não da resposta.
  # `net/protocol.rb:229` chama `wait_readable(@read_timeout)` dentro do laço
  # `do ... end while true` de `rbuf_fill`, então um servidor que pinga bytes
  # devagar NUNCA estoura o read. MEDIDO (ruby 4.0.7, net-http 0.9.1, neste
  # container): com `read_timeout` de 1,0s, 1 byte a cada 0,5s manteve a
  # requisição viva por 21,02s, e a cada 0,9s por 37,01s. Por isso o teto que
  # fecha a conta é `HTTP_TOTAL_TIMEOUT`, que envolve a requisição inteira — e
  # é esse o número que este arquivo usa na aritmética.
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

      assert_equal XQueryIdResolver::HTTP_READ_TIMEOUT, conn.options.timeout,
                   'o timeout do cliente precisa valer para o adapter (read)'
      assert_equal XQueryIdResolver::HTTP_OPEN_TIMEOUT, conn.options.open_timeout,
                   'o open_timeout do cliente precisa ser explicito'
    end

    test 'cada requisicao herda o timeout do cliente' do
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)
      req = conn.build_request(:get)

      assert_equal XQueryIdResolver::HTTP_READ_TIMEOUT, req.options.timeout,
                   'a requisicao precisa carregar o timeout: e o req.options que o Net::HTTP le'
    end

    # O pior caso de UMA requisição é o TETO TOTAL, não `open + read`.
    # `read_timeout` é relógio por leitura (medido: 37,01s com teto de 1,0s), logo
    # somar open e read daria um número que o cliente não respeita. O teto
    # total é o único que a requisição inteira respeita — e é o que a aritmética
    # da descoberta soma.
    #
    # O `max` (e não a soma) porque as fases são EM SÉRIE, não cumulativas: o
    # teto total ENVOLVE as duas e é o maior dos três. Prova em
    # `scripts/proofs/http_timeout_fases_independentes_proof.rb`.
    #
    # `nil` (sem timeout declarado) vale 60s: é o que o Net::HTTP usa de
    # verdade sem timeout explícito, e somar `nil` estouraria com `TypeError`
    # (ruído que não diz que o problema é o cliente). DESCARTAR o `nil`
    # (`compact`) é pior: some com o relógio que faltava e a aritmética segue
    # valendo um número que o cliente não usa — foi assim que a remoção do read
    # passou verde nos testes de teto (medido: imprimiu "3s open + 3s read = 3s").
    #
    # O elo entre a CONSTANTE e o COMPORTAMENTO é o teste do drip logo abaixo:
    # ele executa o `http_get` de verdade contra um servidor que sobrevive a
    # qualquer `read_timeout` e exige o corte no teto. Se o `Timeout.timeout`
    # saísse do `http_get`, esse teste morre — não esta aritmética.
    def aritmetica_da_descoberta
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = @resolver.send(:extract_bundle_urls, html)
      allowed = @resolver.send(:filter_allowed_bundle_urls, urls)
      requisicoes = allowed.size + 1

      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)
      relogios = [conn.options.timeout, conn.options.open_timeout, XQueryIdResolver::HTTP_TOTAL_TIMEOUT]
      por_requisicao = relogios.map { |v| v.nil? ? 60 : v }.max

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

    # ── O TETO TOTAL É O QUE CORTA O DRIP (item 2 do #205) ─────────────────
    #
    # Este é o teste que impede a aritmética de voltar a mentir. Ele mede o
    # `http_get` de VERDADE, contra um servidor que envia 1 byte de cada vez
    # (o drip que sobrevive a qualquer `read_timeout`), e exige que a requisição
    # morra no teto total. Sem o `Timeout.timeout` no `http_get`, esta requisição
    # viveria indefinidamente — que é o furo que o item 2 do #205 mediu (37,01s
    # com `read_timeout` de 1,0s).
    test 'o teto total corta a resposta drip que o read_timeout nunca cortaria' do
      porta = drip_server(intervalo: 0.05, total_aprox: XQueryIdResolver::HTTP_TOTAL_TIMEOUT * 4)

      inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      erro = assert_raises(Faraday::TimeoutError) do
        @resolver.send(:http_get, "http://127.0.0.1:#{porta}/")
      end
      decorrido = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inicio

      puts "  MEDIDO: drip de 1 byte a cada 50ms, read_timeout=#{XQueryIdResolver::HTTP_READ_TIMEOUT}s " \
           "-> #{erro.class} em #{format('%.2f', decorrido)}s (teto total=#{XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s)"

      # Com folga de 1s: o corte é do teto total, não da latência do drip. Um
      # `read_timeout` por leitura NUNCA cortaria este caso — cada leitura
      # individual fica nos 50ms do intervalo.
      assert_operator decorrido, :<, XQueryIdResolver::HTTP_TOTAL_TIMEOUT + 1.0,
                      'o corte tem de vir do teto total, e nao de uma leitura individual'
      assert_operator decorrido, :>=, XQueryIdResolver::HTTP_TOTAL_TIMEOUT * 0.9,
                      'o drip nao pode ser cortado ANTES do teto total: o intervalo e\' de 50ms'
    ensure
      @drip_thread&.kill
    end

    # A garantia que FECHA é a do join para a descoberta NORMAL (o fixture), e
    # ela é a que o chamador sente. O pior caso do join precisa caber acima da
    # descoberta medida no fixture.
    test 'o pior caso de uma descoberta (teto total por requisicao) cabe no teto do join' do
      requisicoes, por_requisicao, pior_caso = aritmetica_da_descoberta
      conn = http_client(Fetcher::XQueryIdResolver::HOME_URL)

      # O `puts` mostra o que o CLIENTE USA, não as constantes: com o read
      # removido, imprimir as constantes descreveria um cliente que não existe.
      puts "  MEDIDO: #{requisicoes} requisicoes x (#{conn.options.open_timeout || 'sem timeout'}s open " \
           "+ #{conn.options.timeout || 'sem timeout'}s read, teto total " \
           "#{XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s => #{por_requisicao}s) = " \
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

    private

    # Espelha o construtor que o resolver usa, para poder afirmar sobre ele sem
    # fazer HTTP. Se o resolver mudar a forma de montar o cliente, este teste
    # passa a apontar a linha nova em vez de medir o cliente errado.
    def http_client(url)
      @resolver.send(:http_client, url)
    end

    # Servidor que envia a CABEÇA e depois 1 byte a cada `intervalo` segundos.
    # É o drip que sobrevive a qualquer `read_timeout` (cada leitura fica abaixo
    # do teto) e que só um teto TOTAL corta — medido: 37,01s com read de 1,0s.
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
        corpo.times { c.print('.'); c.flush; sleep intervalo }
        c.close
      end
      porta
    end
  end
end
