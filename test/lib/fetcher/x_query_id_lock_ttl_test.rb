# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require "fetcher/x_query_id_resolver"

module Fetcher
  # ── O TTL DO LOCK NÃO É A GARANTIA, E ESTE ARQUIVO MEDE POR QUE ───────────
  #
  # A exclusão do lock de descoberta não é mantida por nenhuma primitiva durante
  # o trabalho: `discover!` grava o lock com `expires_in: lock_ttl` e NÃO o
  # renova, NÃO o apaga ao terminar (decisão deliberada e bem explicada em
  # x_query_id_resolver.rb). A exclusão vale enquanto o TTL não expira.
  #
  # A garantia ANTIGA era "a descoberta inteira cabe em LOCK_TTL segundos", e
  # ela é FALSA — e o motivo estava neste arquivo desde o começo, escrito ao
  # contrário. A aritmética que provava que ela não cabe vivia sobre a
  # suposição de que cada requisição podia durar 60s do Net::HTTP, o que
  # deixou de ser verdade: o resolver agora tem teto TOTAL por requisição
  # (`HTTP_TOTAL_TIMEOUT`, 8s, medido em
  # test/lib/fetcher/x_query_id_resolver_timeout_test.rb). Este arquivo foi
  # corrigido em 26/09/2026 (revisão r2 do #205) para não ser a segunda fonte
  # da garantia velha: o único contrato do TTL é o bloco de `LOCK_TTL` em
  # lib/fetcher/x_query_id_resolver.rb, e o guard que o protege é o teste
  # `a garantia do LOCK_TTL tem UMA fonte…`.
  #
  # Os testes usam o store REAL de produção (`SolidCache::Store`, gem 1.0.10 — o
  # mesmo de config/environments/production.rb:14), não um dublê: a pergunta é
  # sobre a expiração e a atomicidade do SolidCache, que um MemoryStore não
  # reproduz.
  #
  # O TTL de produção (60s) é o MESMO código com outro número — a expiração é do
  # store, não do resolver. Por isso a MEDIÇÃO do mecanismo usa `ShortTtlResolver`
  # (1s) e fecha em segundos, e o número de produção é confrontado com o pior
  # caso calculado no terceiro teste.
  class XQueryIdLockTtlTest < ActiveSupport::TestCase
    LOCK_KEY = "fetcher:x_query_id_lock:SearchTimeline".freeze

    class ShortTtlResolver < XQueryIdResolver
      SHORT_TTL = 1
      def lock_ttl = SHORT_TTL
    end

    def setup
      @store = SolidCache::Store.new(local_cache: false)
      @store.clear
      Rails.stubs(:cache).returns(@store)
    end

    def teardown
      Rails.unstub(:cache)
      @store.clear
      super
    end

    # Resolver real (só a camada de rede é trocada) que segura o fetch dentro da
    # janela do lock até o teste mandar soltar, e conta quantas vezes o fetch
    # foi realmente chamado. `calls` é lido DEPOIS dos joins, sem `Queue`, para
    # não depender de `Queue#empty?` — que é `Thread::Queue#empty?` e não tem a
    # mesma semântica de `size` entre threads.
    def blocking_resolver(klass = XQueryIdResolver)
      resolver = klass.new(cache: @store)
      mutex = Mutex.new
      calls = 0
      dentro = Queue.new
      liberar = Queue.new
      resolver.define_singleton_method(:fetch_home_html) do
        mutex.synchronize { calls += 1 }
        dentro << :in
        liberar.pop
        ''
      end
      resolver.define_singleton_method(:fetch_bundle) { |_url| '' }
      [resolver, dentro, liberar, -> { calls }]
    end

    # ── A garantia, quando o trabalho cabe no TTL: ninguém mais entra ─────────
    test 'lock de producao (SolidCache) barra o segundo processo enquanto o dono nao terminou' do
      primeiro, dentro, liberar, = blocking_resolver
      segundo, dentro2, _liberar2, calls2 = blocking_resolver

      t1 = Thread.new { primeiro.fetch_fresh('SearchTimeline') }
      dentro.pop # o dono comprou o lock e entrou no fetch
      refute @store.read(LOCK_KEY).nil?, 'o lock deveria estar no store enquanto o dono trabalha'

      t2 = Thread.new { segundo.fetch_fresh('SearchTimeline') }
      sleep 0.3
      assert dentro2.empty?, 'o segundo processo entrou no fetch com o lock ocupado'
      assert_equal 0, calls2.call

      liberar << :ok
      # O segundo já devolveu (lock ocupado) — não precisa de liberação.
      t1.join
      t2.join
      assert true
    end

    # ── A MEDIÇÃO: o que acontece quando o fetch passa do TTL ────────────────
    # Resposta medida, não afirmada: com o store real e TTL de 1s, um fetch que
    # dura mais que isso deixa o lock EXPIRAR NO MEIO, e um segundo processo
    # entra e busca também. É a mesma classe do bug que o PR #203 fechou (dois
    # fetches de descoberta contra o X) — agora no eixo tempo, não read/write.
    test 'fetch mais lento que o TTL deixa o lock expirar e UM SEGUNDO processo buscar' do
      lento, dentro_lento, liberar_lento, = blocking_resolver(ShortTtlResolver)
      rapido, dentro_rapido, liberar_rapido, calls_rapido = blocking_resolver(ShortTtlResolver)

      t1 = Thread.new { lento.fetch_fresh('SearchTimeline') }
      dentro_lento.pop

      # TTL de 1s: espera o lock EXPIRAR com o primeiro processo ainda dentro
      # do fetch. Quem expira é o store real, sem truque de relógio.
      sleep 1.4
      assert_nil @store.read(LOCK_KEY),
                 'pre-condicao: o lock deveria ter expirado com o dono ainda no fetch'

      t2 = Thread.new { rapido.fetch_fresh('SearchTimeline') }
      dentro_rapido.pop # o segundo entrou no fetch: o lock tinha expirado
      assert_equal 1, calls_rapido.call,
                   'o segundo processo so buscaria se o lock tivesse expirado durante o fetch do primeiro'

      liberar_rapido << :ok
      liberar_lento << :ok
      t1.join
      t2.join

      puts "  MEDIDO: TTL=#{ShortTtlResolver::SHORT_TTL}s, fetch de ~1.4s, SolidCache real — " \
           'o lock expirou com o dono vivo e o segundo processo fez o seu fetch.'
    end

    # ── A DIMENSÃO DO PROBLEMA: quantas requisições uma descoberta faz ───────
    #
    # Esta aritmética mudou em 26/09/2026 (revisão r2 do #205) e a mudança é o
    # ponto: ela provava que a garantia velha era FALSA usando o pior caso de
    # 60s POR requisição do Net::HTTP sem timeout explícito — suposição que
    # deixou de valer quando o resolver ganhou o `HTTP_TOTAL_TIMEOUT` de 8s.
    #
    # Com o teto de hoje, a conta é a do ÚNICO número com garantia (o teto POR
    # requisição, medido pelo drip), e ela DÁ CABER no TTL do fixture: 3
    # requisições x 8s = 24s contra 60s. Ou seja: a aritmética que refutava a
    # garantia velha pelo motivo errado agora mede o motivo CERTO — o número de
    # requisições NÃO TEM TETO (é um `select` por nome, não um contador: medido
    # em x_query_id_resolver_timeout_test.rb, 50 URLs de um padrão já dão 51
    # requisições e 408s), e é por isso que o TTL não pode ser a garantia.
    test 'o TTL nao e a garantia: o numero de requisicoes nao tem teto, e o teto e' \
         ' por requisicao' do
      resolver = XQueryIdResolver.new(cache: @store)
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = resolver.send(:extract_bundle_urls, html)
      allowed = resolver.send(:filter_allowed_bundle_urls, urls)

      assert_operator allowed.size, :>=, 1

      # O ÚNICO teto garantido é o POR REQUISIÇÃO (o `HTTP_TOTAL_TIMEOUT`), e ele
      # é medido de verdade em x_query_id_resolver_timeout_test.rb (drip de 1
      # byte a cada 50ms, cortado em 8,00s exatos). Nenhuma requisição do
      # resolver pode passar dele — a suposição antiga ("nenhuma tem timeout")
      # é a que este commit remove.
      por_requisicao = XQueryIdResolver::HTTP_TOTAL_TIMEOUT
      requisicoes = allowed.size + 1
      pior_case_do_fixture = requisicoes * por_requisicao

      # E o número de requisições NÃO TEM TETO: o filtro é um `select` por NOME
      # de arquivo. 50 URLs de UM ÚNICO padrão passam todas — é a mesma
      # medição do achado 1 da revisão A, aqui pelo caminho real do filtro.
      base = Fetcher::XQueryIdResolver::BUNDLE_BASE_URL
      sem_teto = 50.times.map { |i| "#{base}main.p#{i}.js" }
      permitidas = resolver.send(:filter_allowed_bundle_urls, sem_teto).size
      pior_case_sem_teto = (permitidas + 1) * por_requisicao

      puts "  MEDIDO no fixture: #{urls.size} preload links, #{allowed.size} bundles permitidos, " \
           "#{requisicoes} requisicoes por descoberta."
      puts "  MEDIDO: teto TOTAL por requisicao = #{por_requisicao}s; " \
           "fixture = #{pior_case_do_fixture}s contra LOCK_TTL=#{XQueryIdResolver::LOCK_TTL}s."
      puts "  MEDIDO sem teto de requisicoes: #{permitidas} bundles de UM padrao -> " \
           "#{permitidas + 1} requisicoes = #{pior_case_sem_teto}s, " \
           "contra LOCK_TTL=#{XQueryIdResolver::LOCK_TTL}s."

      # O fixture CABE, e é por isso que a aritmética do fixture não pode ser
      # vendida como garantia do TTL: o que estoura é o número de requisições.
      assert_operator pior_case_do_fixture, :<, XQueryIdResolver::LOCK_TTL,
                     'o fixture cabe no TTL: por isso que o TTL medido pelo fixture nao e garantia'

      # E o que o código PERMITE estoura — sem nenhuma requisição sem timeout.
      assert_operator pior_case_sem_teto, :>, XQueryIdResolver::LOCK_TTL,
                     'o que o codigo permite ja estoura o TTL SEM nenhuma requisicao sem timeout: ' \
                     'e por isso que o TTL nao e a garantia (o numero de requisicoes nao tem teto)'
    end
  end
end
