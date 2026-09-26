# frozen_string_literal: true

require "test_helper"
require "fetcher/channels/x_graphql"
require "fetcher/x_query_id_resolver"

# ── O PIN SOBREVIVE À RESPOSTA TRUNCADA: PROVA NO NÍVEL DO CHAMADOR ─────────
#
# A rodada anterior do #205 fechou o cache (a resposta cortada pelo
# `HTTP_TOTAL_TIMEOUT` não grava mais o PIN por 25h) e, no mesmo commit,
# passou a devolver `nil` ao chamador. O defeito era o SILÊNCIO, não o cache —
# e a troca trocou um silêncio por OUTRO silêncio, agora com URL quebrada.
#
# Este arquivo é a prova de que a volta ao comportamento da `main` está no
# caminho REAL de produção, e não só no retorno cru do resolver:
#
#   lib/fetcher/channels/x_graphql.rb:90   `last_query_id = query_id_resolver.resolve(operation)`
#   lib/fetcher/channels/x_graphql.rb:379  `resolved_id = query_id || XQueryIdResolver.new.resolve(operation)`
#
# Com `value = nil`, as DUAS linhas caem em
# `https://x.com/i/api/graphql//SearchTimeline` — id vazio no meio do path. E
# como `resolve` devolve só a String, o `:discovery_truncated` nunca chega ao
# log por esse caminho: a falha fica invisível.
#
# O teste que a rodada anterior escreveu olhava o CACHE. O cache estava
# certo. O que quebrava era o valor devolvido, e nenhum assert olhava para ele.
#
# ── O QUE ESTE ARQUIVO AFIRMA (as três metades, e nenhuma substitui a outra) ──
#
#   1. O PIN CONTINUA SENDO USADO: com a busca cortada, o chamador recebe o
#      `value` e monta a URL com o id do PIN no path — nada de `graphql//`.
#   2. O WARN SAI: nomeando a URL do bundle que não chegou ao fim e dizendo
#      que o pin veio de resposta truncada. O defeito era o silêncio, então
#      devolver o pin sem dizer nada seria a metada do defeito.
#   3. O ID REAL DESCOBERTO NÃO É DESCARTADO: um bundle cortado seguido de
#      outro que traz o id de verdade devolve e GRAVA o id real.
#
# E o que NÃO volta (o que a rodada anterior já fechou, e fica fechado): 25h
# de pin no cache vindo de resposta truncada.
#
# Tudo por execução do código real: o drip local de 1 byte a cada 50ms (cada
# leitura fica abaixo do `read_timeout` de 3s, então só o teto TOTAL corta) e
# o `BUNDLE_BASE_URL` apontado para ele.

module Fetcher
  class XGraphqlQueryIdTruncadoTest < ActiveSupport::TestCase
    CACHE_KEY = "fetcher:x_query_id:SearchTimeline"
    OPERATION = "SearchTimeline"

    # O `queryId` que o X serve no bundle de verdade, e que o PIN não é.
    ID_REAL = "id-descoberto-no-bundle-real"

    def setup
      @cache = ActiveSupport::Cache::MemoryStore.new
      @resolver = XQueryIdResolver.new(cache: @cache)
      @servidores = []
    end

    def teardown
      @drip_thread&.kill
      @servidores.each { |s| s.close rescue nil }
      super
    end

    # ──────────────────────────────────────────────────────────────────────────
    # 1 + 2: o pin continua sendo usado E o warn sai
    # ──────────────────────────────────────────────────────────────────────────
    test "bundle cortado pelo teto: o CHAMADOR usa o pin e o WARN sai" do
      base_local = inicia_bundle_em_drip
      avisos = nil

      url_uso = com_home_do_resolver(base_local, home_com_urls(base_local)) do
        captura_warn { |linhas| avisos = linhas; url_do_chamador }
      end

      # (1) O PIN CONTINUA SENDO USADO — no nível do CHAMADOR, pela linha que
      #     a produção usa. Com `value = nil` esta URL vira
      #     `.../graphql//SearchTimeline`: id vazio no path.
      refute_nil url_uso, "o chamador de producao precisa montar a URL do SearchTimeline"
      assert_includes url_uso, "/i/api/graphql/#{XQueryIdResolver::PIN}/#{OPERATION}",
                      "o pin tem de CONTINUAR no path quando a resposta foi truncada: " \
                      "a rodada anterior trocou o silencio do cache por uma URL com id vazio, " \
                      "que e o mesmo defeito com outra roupa"
      refute_match %r{/i/api/graphql//}, url_uso,
                   "URL com id VAZIO no meio do path: o chamador nao pode montar " \
                   "graphql//SearchTimeline (x_graphql.rb:379)"

      # (2) O WARN SAI — e diz as DUAS coisas: qual bundle nao chegou ao fim e
      #     que o valor servido e' o pin de ultima instancia vindo de resposta
      #     truncada. O defeito do #205 era o silencio, entao devolver o pin sem
      #     dizer nada seria a metada.
      refute_empty avisos, "o caminho do CHAMADOR precisa LOGAR: ele usa `resolve`, que " \
                           "so devolve a String, entao o `:discovery_truncated` nao chega " \
                           "a ninguem por aqui sem um log proprio"
      linha = avisos.grep(/truncad|cortad/i).first
      refute_nil linha, "o aviso tem de dizer que a resposta foi TRUNCADA/cortada; " \
                        "veio: #{avisos.inspect}"
      assert_includes linha, base_local,
                      "o aviso tem de NOMEAR a URL do bundle que nao chegou ao fim, " \
                      "senao nao ha como saber qual requisicao foi cortada"
      assert_match(/pin/i, linha,
                   "o aviso tem de dizer que o valor servido e' o PIN de ultima instancia " \
                   "vindo de resposta truncada (o defeito era o silencio, nao o cache)")

      # E o que continua de pe' do achado 3: NADA de 25h de pin no cache vindo
      # de resposta truncada. O pin e' servido ao chamador, nao GRAVADO.
      refute @cache.read(CACHE_KEY),
             "resposta truncada nao pode gravar o pin no cache por 25h: o valor nao foi " \
             "verificado nesta busca (achado 3 da revisao A do #205)"
    end

    # ──────────────────────────────────────────────────────────────────────────
    # 3: o id REAL descoberto depois do corte nao e' descartado
    # ──────────────────────────────────────────────────────────────────────────
    test "bundle cortado seguido de bundle com o id REAL: o id real e' usado e gravado" do
      base_local = inicia_bundle_em_drip
      # O segundo bundle responde de uma vez, com o query id do X.
      segundo = "#{base_local}bundle.Profile.real.js"
      permite_bundle(segundo, "var o = {queryId: \"#{ID_REAL}\", operationName: \"#{OPERATION}\"};")

      desfecho = nil
      com_home_do_resolver(base_local, home_com_urls(base_local, segundo)) do
        desfecho = @resolver.resolve_with_outcome(OPERATION)
      end

      # Com o id real em mãos, o desfecho é o de DESCOBERTA: o corte de um
      # bundle não invalida um id que foi visto de verdade. O que o corte
      # continua sendo está no `warn` de nível alto, nomeando a URL.
      assert_equal :discovered, desfecho&.reason,
                   "o id real foi visto de verdade: o corte de outro bundle nao o invalida, " \
                   "e o desfecho tem de dizer descoberta, nao corte"
      # Este e' o segundo furo medido: com o `return` do truncado ANTES do
      # `if query_id.nil?`, o id real visto num bundle posterior era jogado fora.
      assert_equal ID_REAL, desfecho&.value,
                   "o id REAL descoberto num bundle posterior nao pode ser descartado: " \
                   "ele foi visto de verdade nesta busca"
      assert_equal ID_REAL, @cache.read(CACHE_KEY)&.dig(:query_id),
                   "o id real visto tem de ser GRAVADO: a resposta truncada impede " \
                   "afirmar que o id nao existe, nao impede usar o que foi visto"
    end

    # ──────────────────────────────────────────────────────────────────────────
    # O CONTROLE: sem id real em nenhum bundle, o pin volta e o cache segue vazio
    # ──────────────────────────────────────────────────────────────────────────
    test "bundle cortado e nenhum id real: o pin e' servido e o cache fica vazio" do
      base_local = inicia_bundle_em_drip
      # O segundo bundle responde de uma vez, mas VAZIO: nao traz o id.
      permite_bundle("#{base_local}bundle.Profile.vazio.js", "")

      desfecho = nil
      vazio = "#{base_local}bundle.Profile.vazio.js"
      com_home_do_resolver(base_local, home_com_urls(base_local, vazio)) do
        desfecho = @resolver.resolve_with_outcome(OPERATION)
      end

      assert_equal :discovery_truncated, desfecho&.reason
      assert_equal XQueryIdResolver::PIN, desfecho&.value,
                   "sem id real, o pin de ultima instancia volta a ser servido: e' o que " \
                   "segura o chamador quando a busca falha (comportamento da main)"
      refute @cache.read(CACHE_KEY),
             "e ainda assim NADA vai para o cache: o pin nao foi verificado nesta busca"
    end

    private

    # ── O drip que so o teto TOTAL corta ──────────────────────────────────────
    # Envia a cabeca e depois 1 byte a cada `intervalo` segundos. Cada leitura
    # fica abaixo do `read_timeout` de 3s, entao o que mata a requisicao e' o
    # `HTTP_TOTAL_TIMEOUT` — o mesmo caminho do achado 3, medido, nao simulado.
    def inicia_bundle_em_drip(intervalo: 0.05)
      require "socket"
      srv = Socket.new(:INET, :STREAM)
      srv.setsockopt(:SOCKET, :REUSEADDR, true)
      srv.bind(Addrinfo.tcp("127.0.0.1", 0))
      srv.listen(8)
      @servidores << srv
      porta = srv.local_address.ip_port
      total = (XQueryIdResolver::HTTP_TOTAL_TIMEOUT * 20 / intervalo).ceil
      @drip_thread = Thread.new do
        loop do
          c, = srv.accept
          c.gets
          c.print "HTTP/1.1 200 OK\r\nContent-Length: #{total}\r\nConnection: close\r\n\r\n"
          c.flush
          total.times { c.print("."); c.flush; sleep intervalo }
          c.close
        rescue StandardError
          nil
        end
      end
      "http://127.0.0.1:#{porta}/"
    end

    # Home com os preload links. O padrao "main" casa com "main.drip.js" e o
    # padrao "bundle.Profile" casa com o segundo, entao o filtro real deixa
    # passar os dois.
    def home_com_urls(base_local, segundo = nil)
      urls = ["#{base_local}main.drip.js"]
      urls << segundo if segundo
      links = urls.map { |u| %(<link rel="preload" as="script" href="#{u}">) }.join
      %(<html><head>#{links}</head><body></body></html>)
    end

    # O bundle que responde de uma vez (o que traz, ou nao, o id real).
    def permite_bundle(url, corpo)
      stub_request(:get, url).to_return(
        status: 200, body: corpo, headers: { "Content-Type" => "application/javascript" }
      )
    end

    # Aplica a base local e o home ao resolver real durante o bloco. A
    # constante e' trocada no lugar e restaurada no `ensure`: o filtro resolve
    # a constante lexicalmente, entao uma subclasse com a sua propria NAO
    # mudaria o que o `allowed_bundle?` do pai le.
    def com_home_do_resolver(base_local, home)
      klass = Fetcher::XQueryIdResolver
      original = klass::BUNDLE_BASE_URL
      klass.send(:remove_const, :BUNDLE_BASE_URL)
      klass.const_set(:BUNDLE_BASE_URL, base_local)
      @resolver.stubs(:fetch_home_html).returns(home)
      @home_do_ciclo = home
      # O valor do bloco é o retorno do helper: sem o `begin` explícito, o
      # `ensure` abaixo não mudaria o valor, mas ler `yield` solto como
      # última expressão é o que devolve a URL ao chamador do teste.
      begin
        yield
      end
    ensure
      klass.send(:remove_const, :BUNDLE_BASE_URL)
      klass.const_set(:BUNDLE_BASE_URL, original)
    end

    # ── O caminho do CHAMADOR, de verdade ─────────────────────────────────────
    # Equivale a `x_graphql.rb:379`: o id vem do resolver quando o chamador nao
    # tem um, e a URL e' montada com ele. O `XQueryIdResolver.new` do chamador
    # usa o MESMO cache do teste — e sem cache, que e' o primeiro arranque em
    # producao.
    #
    # O `home` e' o MESMO HTML que o bloco ja aplicou ao `@resolver`: quem
    # chama cria uma instância nova, e sem o stub ela sairia para a rede real
    # (o WebMock barra, e o teste morreria por um motivo que nao e' o do #205).
    def url_do_chamador
      Fetcher::XQueryIdResolver.any_instance
                           .stubs(:fetch_home_html).returns(@home_do_ciclo)
      resolved_id = XQueryIdResolver.new(cache: @cache).resolve(OPERATION)
      "https://x.com/i/api/graphql/#{resolved_id}/#{OPERATION}"
    end

    # Roda o bloco e devolve o VALOR DELE (a URL, no chamador), deixando as
    # linhas de `warn` em `linhas`. O que este teste afirma é que o aviso SAI e
    # o que ele diz, não que algum método foi chamado.
    #
    # O stub é do `warn` e nada mais: um `expects` em algum logger específico
    # obrigaria a saber de antemão todo o caminho tocado, e quem se importa aqui
    # é o texto do aviso de nível alto.
    def captura_warn
      linhas = []
      Rails.logger.stubs(:warn).with { |m| linhas << m.to_s; true }
      yield(linhas)
    end
  end
end
