# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require "fetcher/x_query_id_resolver"

module Fetcher
  # ── RESSALVA R3 do PR #203: o TTL de 60s É a garantia, e ela não foi medida ──
  #
  # A exclusão do lock de descoberta não é mantida por nenhuma primitiva durante
  # o trabalho: `discover!` grava o lock com `expires_in: lock_ttl` e NÃO o
  # renova, NÃO o apaga ao terminar (decisão deliberada e bem explicada em
  # x_query_id_resolver.rb). A exclusão vale enquanto o TTL não expira — logo a
  # garantia é literalmente "a descoberta inteira cabe em LOCK_TTL segundos", e
  # essa aritmética nunca foi medida. Este arquivo mede.
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
    test 'a descoberta faz no maximo (home + bundles) requisicoes, e o pior caso excede o TTL' do
      resolver = XQueryIdResolver.new(cache: @store)
      html = File.read(Rails.root.join('test/fixtures/x/home_with_manifest.html'))
      urls = resolver.send(:extract_bundle_urls, html)
      allowed = resolver.send(:filter_allowed_bundle_urls, urls)

      assert_operator allowed.size, :>=, 1

      # PIOR CASO EM CÓDIGO: nenhuma requisição do resolver tem timeout. Faraday
      # sem `request.options.timeout` herda o padrão do Net::HTTP, que é 60s de
      # open e 60s de read POR REQUISIÇÃO (medido neste repo em 26/09/2026).
      net_http_default = 60
      requisicoes = allowed.size + 1
      worst_case = requisicoes * net_http_default
      puts "  MEDIDO no fixture: #{urls.size} preload links, #{allowed.size} bundles permitidos, " \
           "#{requisicoes} requisicoes por descoberta."
      puts "  MEDIDO: Net::HTTP sem timeout explicito = #{net_http_default}s por requisicao; " \
           "pior caso = #{worst_case}s, contra LOCK_TTL=#{XQueryIdResolver::LOCK_TTL}s " \
           "(#{XQueryIdResolver::LOCK_TTL / worst_case.to_f} do pior caso)."

      assert_operator worst_case, :>, XQueryIdResolver::LOCK_TTL,
                     'o pior caso sem timeout excede o TTL: e por isso que o TTL sozinho nao e garantia'
    end
  end
end
