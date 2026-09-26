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
    # ── OS PADRÕES DO GUARD, EM UM LUGAR SÓ ────────────────────────────────
    #
    # Eles vivem aqui como constantes porque o teste abaixo (`o guard do
    # LOCK_TTL nao tem furo`) precisa casar contra eles — um regex escrito
    # dentro do `refute_match` não pode ser testado por mutação sem ser
    # duplicado, e um guard duplicado é um guard que diverge.
    #
    # Os refutes são NEGAÇÕES do que o bloco não pode AFIRMAR, e "afirmar" é a
    # palavra que manda: uma frase que cita a promessa antiga para NEGÁ-la é o
    # que a casa quer (é assim que o bloco se contradiz e fecha a conta), então
    # um refute que casa com a citação-negada acusaria o texto HONESTO.
    #
    # Por isso os dois refutes de promessa estruturam a NEGAÇÃO à volta da
    # frase, e é isso que fecha os furos da revisão r2 sem abrir outro:
    #
    #   (1) A promessa que o achado 2 mediu como FALSA: "a descoberta inteira
    #       cabe no TTL". O refute antigo casava `... cabe em LOCK_TTL` — o nome
    #       da constante — e deixava passar "a garantia é que a descoberta
    #       inteira cabe no tempo do lock" (medido por mutação). Aqui o padrão
    #       casa a frase INTEIRA, e a tolerância é de até 24 caracteres entre
    #       ela e a negação: a promessa escrita perto do "não" é a promessa
    #       que o bloco fecha, não a que ele faz.
    #
    #   (2) O nome do total: "pior caso real" sobre uma CONTAGEM de padrões, que
    #       é PISO e não teto (achado 1). O refute antigo era largo demais
    #       aqui também: pegava a frase que o bloco usa para EXPLICAR que o
    #       número não é teto, e acusava o texto honesto.
    #
    #   (3) O NÚMERO. 248s vem de 31 x 8s, e 31 é piso. O refute antigo casava
    #       a grafia (`31 x 8s = 248s`) e deixava passar "31 vezes 8 segundos =
    #       248 segundos". O número não pode aparecer no bloco por NENHUMA
    #       grafia — nem na frase que explica por que ele é falso, que é a
    #       parte que mais tentaria citá-lo para se justificar.
    REFUTE_DESCOBERTA_CABE = /(?:a\s+garantia\s+)?(?:que\s+)?a\s+descoberta\s+inteira\s+cabe/i.freeze
    REFUTE_PIOR_CASO_REAL = /pior\s+caso\s+real/i.freeze
    REFUTE_248 = /248/.freeze

    # ── COMO O GUARD JULGA: AFIRMAÇÃO, NÃO OCORRÊNCIA ───────────────────────
    #
    # O refute é sobre AFIRMAR a promessa, não sobre ela aparecer: o bloco
    # honesto CITA a garantia velha para descartá-la, e é essa citação que dá a
    # informação para quem lê. Três tentativas de guard falharam antes desta,
    # e as três estão medidas nos casos do teste de furo:
    #
    #   (a) Casar a grafia com o nome da constante: a mesma promessa em prosa
    #       ("a garantia é que a descoberta inteira cabe no tempo do lock")
    #       passava — o furo 1 da revisão r2.
    #   (b) Casar a frase com uma JANELA de caracteres: o "não" do parágrafo de
    #       CIMA validava a promessa do parágrafo de baixo.
    #   (c) Ancorar a janela na fronteira (`\s*\z`): a citação honesta do 248s
    #       — "é uma CONTAGEM, NÃO um limite", com a negação a mais de 80
    #       caracteres e atravessando linhas — continuava sendo accusada.
    #
    # A regra que fecha os três é sobre a ORAÇÃO — o trecho até o ponto final,
    # com as quebras de linha IRRELEVANTES (o bloco quebra as frases no meio) —
    # e tem duas metades porque cada uma sozinha deixa um caso passar:
    #
    #   ADVERSATIVA: a construção ", NÃO …" ("é uma contagem, NÃO um limite").
    #     Vale a QUALQUER distância dentro da oração, porque por construção ela
    #     se liga ao que veio ANTES: o "não" e o predicado dela. É o que
    #     absolve a citação do 248s, cuja negação está a mais de 80 caracteres.
    #
    #   COLADA: o verbo de negação ("NÃO é", "NUNCA", "NEM"). Só nega a
    #     promessa se estiver COLADO a ela — até `JANELA_NEGACAO` caracteres,
    #     sem cruzar o ponto final. É o que absolve "a garantia NÃO é 'a
    #     descoberta inteira cabe…'".
    #
    # Por que o verbo precisa ser colado, e a adversativa não: "ela NÃO é
    # repetida aqui" — de outra oração, falando de outra coisa — aparecia na
    # FRAÇÃO seguinte da mutação em prosa e absolvia a promessa de cima. Uma
    # regra de predicado solto no texto inteiro não fecha nada; o que decide é
    # se a negação APONTA para a promessa, e a adversativa aponta por construção
    # enquanto o verbo precisa de proximidade.
    NEGACAO_ADVERSATIVA = /,\s*nao\s+/i.freeze
    NEGACAO = /(?:nao|nunca|jamais|negando|nega|nem)\b/i.freeze
    JANELA_NEGACAO = 20
    NEGACAO_COLADA_ANTES = /#{NEGACAO.source}[^.]{0,#{JANELA_NEGACAO}}\s*\z/i.freeze
    NEGACAO_COLADA_DEPOIS = /\A[^.]{0,#{JANELA_NEGACAO}}\b#{NEGACAO.source}/i.freeze

    # O que o bloco TEM de dizer, para a garantia ser a que o código respeita.
    GARANTIA_EXIGIDA = [
      /por\s+requisicao/i,
      /janela\s+de\s+reabertura/i,
      /nao\s+.{0,24}(garantia|cabe)/i
    ].freeze

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

    # ── O NÚMERO DE REQUISIÇÕES NÃO É LIMITADO POR PADRÃO (achado 1) ──────
    #
    # O `find 3` do card anterior via NUMERÁRIO, e numerário não é teto: a
    # varredura de bundles NÃO para quando um padrão já casou. Ela varre
    # `allowed_urls`, que sai de `filter_allowed_bundle_urls`, e o filtro é um
    # `select` que aceita qualquer URL que case com QUALQUER padrão — o array
    # de padrões é uma ALLOWLIST de nomes, não um contador de requisições.
    #
    # MEDIDO por execução (ruby do container, método real, sem rede):
    #   50 URLs `main.<hash>.js` DISTINTAS, todas casando com UM ÚNICO padrão
    #   ("main") -> allowed.size = 50 -> 51 requisições -> 408s.
    #   200 URLs em 2 padrões ("main", "bundle.Profile") -> allowed.size = 200.
    #
    # Ou seja: `CORE_CHUNK_PATTERNS.size + 1` é o PISO do pior caso (o `home`
    # que traz UM bundle por padrão), não o teto. Nenhuma asserção de teto pode
    # se apoiar nele, porque a resposta real do X o pode ultrapassar sem
    # limite. O único teto que o cliente respeita é `HTTP_TOTAL_TIMEOUT`, e ele
    # é POR REQUISICAO.
    test 'a varredura de bundles nao para no primeiro padrao que casa' do
      base = Fetcher::XQueryIdResolver::BUNDLE_BASE_URL
      # Um ÚNICO padrão casando, com 50 URLs distintas.
      um_padrao = 50.times.map { |i| "#{base}main.hash#{i}.js" }
      # Dois padrões casando, com 200 URLs distintas.
      dois_padroes = 200.times.map { |i| "#{base}#{(i.even? ? 'main' : 'bundle.Profile')}.h#{i}.js" }

      permitido_um = @resolver.send(:filter_allowed_bundle_urls, um_padrao)
      permitido_dois = @resolver.send(:filter_allowed_bundle_urls, dois_padroes)

      puts "  MEDIDO no filtro (metodo real): #{um_padrao.size} URLs casando com UM padrao " \
           "-> #{permitido_um.size} permitidas (#{permitido_um.size + 1} requisicoes, " \
           "#{(permitido_um.size + 1) * XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s de pior caso)."
      puts "  MEDIDO no filtro (metodo real): #{dois_padroes.size} URLs em DOIS padroes " \
           "-> #{permitido_dois.size} permitidas (#{permitido_dois.size + 1} requisicoes, " \
           "#{(permitido_dois.size + 1) * XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s de pior caso)."

      # A allowlist é por NOME de arquivo: padrão repetido não vira um, e o
      # número de URLs não é limitado pelo número de padrões.
      assert_equal um_padrao.size, permitido_um.size,
                   'o filtro aceita todo bundle que casa com um padrao: o array de padroes ' \
                   'e\' allowlist de NOMES, nao contador de requisicoes'
      assert_operator permitido_um.size, :>, XQueryIdResolver::CORE_CHUNK_PATTERNS.size,
                      'pre-condicao do achado 1: 50 URLs de UM padrao Ja passam todas, ' \
                      'entao o pior caso do codigo NAO e\' 31 requisicoes'
    end

    # O que o código REALMENTE garante é o teto POR REQUISICAO. Este é o único
    # número com garantia, porque é o único que o cliente respeita
    # (`Timeout.timeout` em `http_get`, medido pelo teste do drip acima: 8,00s).
    #
    # Nenhuma asserção deste arquivo — nem de teto do lock, nem de teto do join
    # — pode ser derivada do total de requisições, porque esse total não tem
    # teto. Ela seria uma garantia FALSA, que é a mesma classe do bug que o
    # #205 existia para fechar: um número lido do FIXTURE (3 bundles) ou de
    # uma CONTAGEM (30 padrões) vendido como teto.
    test 'nenhuma contagem de bundles e teto de pior_caso: so o teto por requisicao tem garantia' do
      por_requisicao = XQueryIdResolver::HTTP_TOTAL_TIMEOUT

      # O limite do cliente é medido de verdade logo acima (drip cortado em
      # 8,00s), então a constante não pode divergir do comportamento sem
      # quebrar aquele teste. Aqui o que se trava é a FORMA da garantia.
      assert_equal XQueryIdResolver::HTTP_TOTAL_TIMEOUT, por_requisicao,
                   'o teto garantido e\' o total POR REQUISICAO'
      assert_operator por_requisicao, :>, 0, 'um teto por requisicao tem de ser positivo'

      # E o que NÃO pode: a contagem de padrões como teto. Medido do método
      # real, com o dobro e o triplo de bundles por padrão — se a contagem
      # limitasse, o total de requisições pararia aí. O token `pior_caso` no
      # nome é o que o filtro `-n "/pior_caso/"` do par por mutação usa.
      base = Fetcher::XQueryIdResolver::BUNDLE_BASE_URL
      pedidos = [30, 60, 90].map { |n| n.times.map { |i| "#{base}main.p#{n}x#{i}.js" } }
      permitidos = pedidos.map { |urls| @resolver.send(:filter_allowed_bundle_urls, urls).size }

      puts "  MEDIDO: #{pedidos.map(&:size).inspect} bundles por padrao -> " \
           "#{permitidos.inspect} requisicoes de bundle; " \
           "o total cresce com as URLs, nao com CORE_CHUNK_PATTERNS " \
           "(#{XQueryIdResolver::CORE_CHUNK_PATTERNS.size} padroes)."

      assert_equal pedidos.map(&:size), permitidos,
                   'o numero de requisicoes cresce com o numero de URLs servidas, ' \
                   'e nao com o numero de padroes: nenhum total e\' teto'
      assert_operator permitidos.max, :>, 2 * XQueryIdResolver::CORE_CHUNK_PATTERNS.size,
                      'pre-condicao: 90 bundles de UM padrao ja\' sao muito mais que ' \
                      'os 30 padroes, ento a contagem de padroes nao serve de teto'
    end

    # ── O JOIN: A AFIRMAÇÃO HONESTA (achado 4) ──────────────────────────────
    #
    # A garantia que sobrava era "a descoberta normal cabe no join", medida pelo
    # FIXTURE: 3 bundles x 8s = 24s contra join de 25,0s, ou seja folga de
    # 1,04x. Esse é o número que o chamador sente — e a revisão mediu que ele
    # estoura com 4 bundles permitidos (5 x 8s = 40s > 25,0s), que é o modo de
    # falha R3 do #203 voltando pela porta do fixture.
    #
    # A afirmação honesta: o join cobre a descoberta do FIXTURE, que é o que
    # ele foi medido para cobrir, e NÃO cobre toda descoberta que o código
    # permite. O teste passa a afirmar as duas metades, em vez de vender o
    # fixture como teto.
    #
    # O NOME deste teste contém `pior_caso` de propósito: é por ele que
    # `scripts/proofs/timeout_arithmetic_mutation_pair.sh` roda o par por mutação
    # (filtro `-n "/pior_caso/"`), e o filtro existe para isolar os testes de
    # ARITMÉTICA dos de CONFIGURAÇÃO do cliente — que pegam qualquer mudança no
    # read e fariam o par ser falso. Renomear este teste sem manter o token faria
    # o script rodar ZERO testes e sair verde: a mesma classe de furo que o guard
    # do próprio script já fechou uma vez.
    test 'o pior_caso do fixture cabe no join, e o que o codigo permite nao cabe nele' do
      requisicoes, por_requisicao, pior_caso_fixture = aritmetica_da_descoberta

      puts "  MEDIDO no fixture: #{requisicoes} requisicoes x #{por_requisicao}s " \
           "(teto total) = #{pior_caso_fixture}s, contra join de " \
           "#{XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT}s " \
           "(folga de #{format('%.2f', XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT / pior_caso_fixture.to_f)}x)."

      # (1) O que o join cobre: o fixture. Com a folga medida e dita, não
      # declarada — 1,04x é o número real, e escondê-lo seria a mesma
      # falsidade do teto de 248s.
      assert_operator pior_caso_fixture, :<=, XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT,
                     'a descoberta do FIXTURE precisa caber no teto do join: e o que ele foi medido para cobrir'
      folga = XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT / pior_caso_fixture.to_f
      puts "  MEDIDO: folga do join sobre o fixture = #{format('%.2f', folga)}x — estreita, e dita."
      assert_operator folga, :<, 1.5,
                      'a folga do join sobre o fixture e\' estreita: se passar disto, o numero esta virando teto de fachada'

      # (2) O que o join NÃO cobre: a descoberta que o código permite. Com 4
      # bundles permitidos já são 5 requisições x 8s = 40s, acima do join. Isto
      # é uma pré-condição honesta: o código DIZ que o join não é a garantia.
      bundles_que_estouram = (XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT / por_requisicao.to_f).floor
      pior_caso_4 = (4 + 1) * por_requisicao

      puts "  MEDIDO: com 4 bundles permitidos sao 5 requisicoes x #{por_requisicao}s = " \
           "#{pior_caso_4}s, que ja estoura o join de " \
           "#{XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT}s (o join cobre ate " \
           "#{bundles_que_estouram} bundles do fixture)."

      assert_operator pior_caso_4, :>, XQueryIdResolver::BACKGROUND_JOIN_TIMEOUT,
                     'pre-condicao do achado 4: 4 bundles permitidos ja estouram o join, ' \
                     'entao o fixture NAO pode ser vendido como teto do join'
    end

    # ── UMA FONTE SÓ PARA A GARANTIA DO LOCK (achado 2) ─────────────────────
    #
    # O comentário de `LOCK_TTL` afirmava, em duas metades que se anulavam:
    #
    #   linhas 80-84:  "ESTE É A GARANTIA de exclusividade [...] logo a garantia
    #                   é 'a descoberta inteira cabe em LOCK_TTL'"
    #   linhas 94-100: "a garantia NÃO é 'a descoberta inteira cabe no TTL'"
    #
    # A segunda metade é a verdadeira (o número medido diz que 31 x 8s = 248s
    # não cabe em 60s, e o achado 1 mostra que 31 nem é teto), mas a primeira
    # continuava escrita por cima. Um comentário de código que se contradiz em
    # voz alta é pior do que um comentário ausente: quem lê os dois, ou lê a
    # garantia velha, ou não sabe qual das duas vale.
    #
    # Este teste amarra a prosa ao comportamento, lendo o BLOCO de comentário de
    # `LOCK_TTL` do ARQUIVO (não do que o teste lembra), no mesmo espírito de
    # `test/lib/fetcher/lock_release_dependency_test.rb`:
    #
    #   (1) o bloco NÃO pode afirmar que a descoberta inteira cabe no TTL;
    #   (2) o bloco NÃO pode vender um TOTAL de requisições como teto
    #       (é o achado 1, na prosa);
    #   (3) o bloco TEM de dizer o que a garantia é de fato — o teto por
    #       requisição, que é o único número que o cliente respeita.
    test 'a garantia do LOCK_TTL tem UMA fonte, e ela e o teto por requisicao' do
      # O bloco é normalizado (minúsculas, sem acento) ANTES dos casamentos:
      # o que este teste amarra é o CONCEITO que o comentário promete, não a
      # grafia dele. Escrever o acento dentro do regex é o caminho para um
      # erro de codificação silencioso — foi assim que o `NÃO` virou lixo
      # byte a byte e o arquivo deixou de carregar.
      bloco = normalizar(comentario_de_lock_ttl)

      refute_nil bloco, 'o bloco de comentario de LOCK_TTL tem de existir no arquivo do resolver'

      # (1) A promessa que o achado mediu como falsa, na ordem invertida: o
      # bloco abria dizendo que a garantia era a descoberta inteira caber no
      # TTL, e aclos no fim que NÃO era. As duas nao podem sobreviver.
      #
      # O padrão e' a FRASE, nao o nome que ela da ao TTL: o `refute` antigo
      # casava `a descoberta inteira cabe em LOCK_TTL`, entao a mesma promessa
      # escrita em prosa — "a garantia e' que a descoberta inteira cabe no
      # tempo do lock" — passava por ele (medido por mutacao, revisao r2).
      refute afirma_promessa?(bloco, REFUTE_DESCOBERTA_CABE),
                   'o comentario de LOCK_TTL nao pode AFIRMAR que a descoberta inteira cabe no ' \
                   'TTL: o proprio bloco nega isso mais adiante, e o numero medido diz que nao ' \
                   'cabe (achado 2). Citar a promessa para nega-la pode; afirma-la, nao.'

      # (2) A mesma garantia pelo nome do total: "pior caso real" sobre uma
      # CONTAGEM de padroes, que e' piso e nao teto (achado 1).
      refute afirma_promessa?(bloco, REFUTE_PIOR_CASO_REAL),
                   'o comentario de LOCK_TTL nao pode chamar a contagem de padroes de "pior caso ' \
                   'real": a contagem nao limita o numero de requisicoes (achado 1, medido: 50 ' \
                   'URLs de um padrao ja\' dao 51 requisicoes e 408s)'

      # Nem pelo numero que ela produz: 248s vem de 31 x 8s, e 31 e' piso. O
      # refute antigo casava a GRAFIA (`31 x 8s = 248s`), entao "31 vezes 8
      # segundos = 248 segundos" passava (medido por mutacao, revisao r2). O
      # numero nao pode ser APRESENTADO como o pior caso, por nenhuma grafia.
      #
      # Passa pelo mesmo `afirma_promessa?` dos outros dois, pela mesma razão:
      # o bloco pode CITAR o número para dizer que ele não é teto — é isso que
      # fecha a conta — mas não pode AFIRMAR que ele é.
      refute afirma_promessa?(bloco, REFUTE_248),
                   'o comentario de LOCK_TTL nao pode APRESENTAR 248s como se fosse o pior caso: ' \
                   'ele vem de uma CONTAGEM (padroes), e a contagem nao limita as requisicoes ' \
                   '(achado 1). Citar o numero para nega-lo pode; apresenta-lo, nao'

      # (3) A garantia que FICA tem de estar escrita, e tem de ser a que o
      # codigo respeita de verdade: o teto POR REQUISICAO. O regex tolera a
      # QUEBRA DE LINHA porque o comentario e' quebrado no meio da frase.
      assert_match(/por\s+requisicao/i, bloco,
                   'o comentario de LOCK_TTL tem de dizer que a garantia e\' o teto POR REQUISICAO: ' \
                   'e o unico numero que o cliente respeita (medido: drip cortado em ' \
                   "#{XQueryIdResolver::HTTP_TOTAL_TIMEOUT}s)")

      # E tem de dizer o que o TTL e' e o que ele NAO e', para a unica fonte
      # responder as duas perguntas de quem le o TTL.
      assert_match(/janela\s+de\s+reabertura/i, bloco,
                   "o comentario de LOCK_TTL tem de dizer que o TTL e' a janela de reabertura " \
                   "(o que ele e'), alem de dizer o que ele nao e'")
      assert_match(/nao\s+.{0,24}(garantia|cabe)/i, bloco,
                   'o comentario de LOCK_TTL tem de NEGAR explicitamente a garantia antiga: ' \
                   'o que o TTL nao e\' faz parte da garantia, nao um detalhe esquecido')
    end

    # ── O GUARD NÃO TEM FURO (furo 1 e furo 2 da revisão r2) ─────────────────
    #
    # O teste acima afirma sobre o bloco REAL. Este afirma sobre os PRÓPRIOS
    # refutes: cada um precisa pegar a promessa falsa em PROSA, e não só
    # quando ela é escrita da maneira que o regex usou na primeira vez. Sem
    # isto, o guard é exato enquanto a formulação calhar — que é a situação
    # em que a revisão r2 o mediu: `a garantia é que a descoberta inteira cabe
    # no tempo do lock` passava, e `31 vezes 8 segundos = 248 segundos` também.
    #
    # É a diferença entre "o guard passa" e "o guard segura": o primeiro é
    # fato sobre uma redação; o segundo é fato sobre a classe de redações.
    test 'o guard do LOCK_TTL pega a promessa falsa em PROSA, e nao so na grafia' do
      # (1) A promessa do achado 2, em prosa — a grafia que o refute antigo
      # pegava (a do `main`) e as que ele deixavam passar.
      ['a garantia e que a descoberta inteira cabe no tempo do lock',
       'a descoberta inteira cabe no TTL, logo o TTL e a garantia',
       'a garantia que este numero carrega e que a descoberta inteira cabe no ttl',
       'a descoberta inteira cabe em LOCK_TTL segundos'].each do |frase|
        assert afirma_promessa?(normalizar(frase), REFUTE_DESCOBERTA_CABE),
               "o guard tem de pegar a promessa antiga AFIRMADA assim: #{frase}"
      end

      # (2) O mesmo numero por prosa: o refute antigo so pegava `31 x 8s =
      #     248s`, e o furo era a mesma conta escrita por extenso.
      ['31 vezes 8 segundos = 248 segundos',
       'o pior caso e\' de 248s',
       'sao 248 segundos de pior caso'].each do |frase|
        assert_match REFUTE_248, normalizar(frase),
                     "o guard tem de pegar o 248s escrito assim: #{frase}"
      end

      # (3) E o "pior caso real", que precisa pegar a promessa afirmada e
      #     largar a citação que o bloco nega.
      ['o pior caso real e 31 requisicoes x 8s',
       'pior caso real: 31 x 8s = 248s'].each do |frase|
        assert afirma_promessa?(normalizar(frase), REFUTE_PIOR_CASO_REAL),
               "o guard tem de pegar o 'pior caso real' AFIRMADO assim: #{frase}"
      end

      # (4) O CONTROLE NEGATIVO: um refute largo demais é um guard que não
      #     segura nada, e accuse o texto HONESTO. Citar a promessa para
      #     NEGÁ-la é o que o bloco faz — e tem de continuar passando.
      honesto = normalizar(<<~TEXTO)
        a garantia NAO e' a descoberta inteira cabe no TTL, e o 248s nao e' o
        pior caso real. o TTL e' a janela de reabertura, e o que fecha a conta
        e' o teto por requisicao
      TEXTO
      refute afirma_promessa?(honesto, REFUTE_DESCOBERTA_CABE),
                   'o refute do item (1) esta largo demais: a frase NAO promete nada e ainda ' \
                   'casou — citar a promessa para nega-la tem de ser permitido'
      refute afirma_promessa?(honesto, REFUTE_PIOR_CASO_REAL),
                   'o refute do "pior caso real" esta largo demais: a frase o nega e ainda casou'
      refute afirma_promessa?(honesto, REFUTE_248),
                   'o refute do 248s esta largo demais: a frase nega o numero e ainda casou'
      GARANTIA_EXIGIDA.each_with_index do |padrao, i|
        assert_match padrao, honesto,
                     "a garantia exigida #{i} tem de casar com o texto honesto: #{padrao.inspect}"
      end

      # (5) O furo que as DUAS primeiras tentativas de conserto deixaram, ambos
      #     medidos: o "não" de uma frase vizinha validava a promessa quando a
      #     janela era por distância. O primeiro texto é a mutação da revisão
      #     r2 com a frase seguinte do bloco em volta; o segundo é a citação
      #     honesta do 248s, cuja negação ("não um limite") está longe e
      #     separada por quebras de linha.
      #
      #     Sem estes casos, o guard volta a passar pela promessa em prosa — e
      #     ele passa, porque a suíte verde não é o mesmo que o guard seguro.
      com_promessa_devolta = normalizar(<<~TEXTO)
        este numero e a janela de reabertura, e nao a garantia de exclusividade
        a garantia do TTL nao e a garantia da casa. a garantia e' que a
        descoberta inteira cabe no tempo do lock. ela nao e repetida aqui
      TEXTO
      assert afirma_promessa?(com_promessa_devolta, REFUTE_DESCOBERTA_CABE),
             'o guard nao pode deixar o "nao" de uma frase vizinha validar a promessa da ' \
             'frase seguinte: a negacao tem de ser da FRASE da promessa'

      citacao_honesta = normalizar(<<~TEXTO)
        o 248s que a casa mediu (31 x 8s) e uma contagem, nao um limite: o X
        serve o que servir, e o codigo faz uma requisicao por bundle servido
      TEXTO
      refute afirma_promessa?(citacao_honesta, REFUTE_248),
             'o guard nao pode accusar a citacao que o proprio bloco nega: a negacao vale ' \
             'mesmo a mais de 80 caracteres e atravessando linhas'
    end

    private

    # ── AFIRMA OU SÓ CITA? ──────────────────────────────────────────────────
    #
    # O guard do `main` e o da rodada anterior acusavam QUALQUER ocorrência da
    # promessa antiga, inclusive a ocorrência que a NEGA — e o bloco de
    # `LOCK_TTL` faz exatamente isso: ele abre nomeando a garantia velha e a
    # fecha negando, e é essa negação que é a informação para quem lê.
    #
    # Então o refute passa a ser sobre a AFIRMAÇÃO, e a diferença entre as duas
    # é a negação à volta da frase, dentro da janela de `JANELA_NEGACAO`
    # caracteres e sem cruzar ponto final (que fecha a frase).
    #
    # Sem a janela, `NEGACAO_ANTES` viraria `nao.*` e qualquer "não" do texto
    # validaria qualquer promessa depois dele — que é não segurar nada. Com a
    # janela, o que fica de fora é a MEIA-frase em prosa, que é o caso que o
    # refute antigo não pegava.
    def afirma_promessa?(texto, padrao)
      return false if texto.nil? || texto !~ padrao

      # Unidade de julgamento: a ORAÇÃO (até o ponto final), com as quebras de
      # linha achatadas — o bloco quebra as frases no meio, e a quebra não é
      # fronteira de sentido. A promessa é AFIRMADA quando a sua oração não tem
      # negação que a APONTE. Basta UMA oração afirmada, daí o `any?`.
      oracoes_do_texto(texto).any? do |oracao|
        oracao.match?(padrao) && !negacao_aponta_para?(oracao, padrao)
      end
    end

    # A oração nega a promessa? Duas respostas, e nenhuma sozinha fecha:
    # a ADVERSATIVA (", não …"), que se liga ao que veio antes por construção e
    # vale a qualquer distância dentro da oração, e a negação COLADA (o verbo
    # "não é", "nunca", "nem"), que só nega a promessa se estiver perto dela.
    def negacao_aponta_para?(oracao, padrao)
      return true if oracao.match?(NEGACAO_ADVERSATIVA)

      achado = oracao.match(padrao)
      antes = oracao[0...achado.begin(0)].gsub(/\s+/, " ")
      depois = oracao[achado.end(0)..].to_s.gsub(/\s+/, " ")
      NEGACAO_COLADA_ANTES.match?(antes) || NEGACAO_COLADA_DEPOIS.match?(depois)
    end

    # As orações do texto. O ponto final é o separador; a quebra de linha NÃO
    # é, porque o bloco quebra as frases no meio e a negação pode estar na
    # linha de cima da promessa.
    def oracoes_do_texto(texto)
      texto.split(/(?<=\.)\s*/).map { |oracao| oracao.gsub(/\s+/, " ").strip }.reject(&:empty?)
    end

    # Minúsculas, sem acento e SEM a marca de comentário. O bloco lido do
    # arquivo tem um `# ` no começo de cada linha, então uma frase quebrada
    # entre duas linhas vem com `#` no meio — e um regex que exige as palavras
    # adjacentes não casaria com o que o comentário LITERALMENTE diz.
    def normalizar(texto)
      return nil if texto.nil?

      texto.gsub(/^\s*#\s?/, ' ')
          .unicode_normalize(:nfd)
          .gsub(/\p{Mn}/, '')
          .downcase
    end

    # Bloco de comentário imediatamente acima de `LOCK_TTL = ...` no ARQUIVO do
    # resolver, lido do disco. É o CONTRATO documentado do TTL: o que quem lê o
    # código tem direito a esperar que ele signifique.
    #
    # Só o bloco da constante, e não o arquivo inteiro: o cabeçalho da classe e
    # os comentários de outros métodos falam de coisas diferentes (o
    # `Background_JOIN_TIMEOUT` logo abaixo tem o seu próprio bloco, com a
    # garantia dele), e varrer tudo acusaria narrativa como se fosse promessa.
    def comentario_de_lock_ttl
      arquivo = Fetcher::XQueryIdResolver.instance_method(:lock_ttl).source_location&.first
      return nil if arquivo.nil?

      linhas = File.readlines(arquivo)
      indice = linhas.index { |l| l =~ /^\s*LOCK_TTL\s*=/ }
      return nil if indice.nil?

      bloco = []
      cursor = indice - 1
      while cursor >= 0 && (linhas[cursor].strip.start_with?('#') || linhas[cursor].strip.empty?)
        bloco.unshift(linhas[cursor])
        cursor -= 1
      end
      bloco.join
    end

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
