# frozen_string_literal: true

# Testes PUROS do contrato de fallback do WebSearchTool (sem Rails/docker).
# Cobrem o Defeito 1 (router só em falha do SearXNG; sem deref nil; erro
# original preservado) e Defeito 5 (cache do fallback; sem RelevanceGuard nos
# resultados externos).
#
# O stub mínimo de RubyLLM::Tool + Rails abaixo permite carregar o
# web_search_tools.rb e instanciar WebSearchTool em ruby puro.

require "minitest/autorun"
require "net/http"
require "json"
require "digest"
require "set"
require "date"

# ── stub de RubyLLM::Tool (apenas o necessário p/ carregar a tool) ──────────
unless defined?(RubyLLM::Tool)
  module RubyLLM
    class Tool
      # A DSL `description`/`param` é chamada no corpo da classe; repassamos
      # como no-op para cada subclasse que herda Tool.
      def self.inherited(subclass)
        subclass.singleton_class.class_eval do
          def description(*); end
          def param(*); end
        end
      end
    end
  end
end

# ── stub de Rails (apenas se Rails não estiver carregado na suíte) ──────────
unless defined?(Rails)
  module Rails
  end
end

unless Rails.respond_to?(:logger) && Rails.logger
  def Rails.logger
    @logger ||= Object.new.tap do |l|
      l.define_singleton_method(:info)  { |*| }
      l.define_singleton_method(:warn)  { |*| }
      l.define_singleton_method(:error) { |*| }
    end
  end
end

unless Rails.respond_to?(:cache) && Rails.cache
  module Rails
    class PureMemoryCacheStore
      def initialize
        @data = {}
      end
      def read(key) = @data[key]
      def write(key, value, **_options)
        @data[key] = value
      end
      def clear
        @data.clear
      end
    end

    def self.cache
      @pure_cache_instance ||= PureMemoryCacheStore.new
    end
  end
end

# ActiveSupport shim: Integer#minute / #minutes usados nas constantes de TTL.
class Integer
  unless method_defined?(:minutes)
    define_method(:minutes) { |_ = nil| self * 60 }
  end
  unless method_defined?(:minute)
    define_method(:minute) { |_ = nil| self * 60 }
  end
end

require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/web_search_tools"
require_relative "../../app/services/search_api_router"

class WebSearchToolFallbackPureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  def setup
    Rails.cache.clear if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:clear)
    # `call` do router é stubado por teste para isolar o `run`. Guardamos a
    # implementação ORIGINAL para restaurá-la no teardown e não
    # contaminar outros testes em ordem aleatória.
    @original_call = SearchApiRouter.singleton_class.instance_method(:call)
    @original_rails_logger = Rails.singleton_class.instance_method(:logger) if Rails.respond_to?(:logger)
    @original_rails_cache = Rails.singleton_class.instance_method(:cache) if Rails.respond_to?(:cache)
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }
    state = { calls: [], fallback: nil }
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state[:calls] << kw
      state[:fallback]
    end
    @state = state
    @tool = WebSearchTool.new
  end

  def teardown
    SearchApiRouter.singleton_class.send(:define_method, :call, @original_call)
    if defined?(@original_rails_logger) && @original_rails_logger
      Rails.singleton_class.send(:define_method, :logger, @original_rails_logger)
      @original_rails_logger = nil
    end
    if defined?(@original_rails_cache) && @original_rails_cache
      Rails.singleton_class.send(:define_method, :cache, @original_rails_cache)
      @original_rails_cache = nil
    end
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
    Rails.cache.clear if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:clear)
  end

  def set_fallback(value)
    @state[:fallback] = value
  end

  def router_calls
    @state[:calls]
  end

  # Sobrescreve fetch (privado) na instância para simular o SearXNG.
  def with_fetch(payload)
    @tool.define_singleton_method(:fetch) { |_q, _l, _tr| payload }
  end

  def fallback(results, engine: :tavily)
    { results: results, engine: engine, cost: nil }
  end

  def test_searxng_ok_nao_chama_router_e_devolve_resultados_do_searxng
    with_fetch({ results: [{ title: "S", url: "https://s.com", content: "c", engine: "ddg" }],
                 unresponsive: [] })
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "rails")

    assert_equal :success, res[:status]
    assert_equal "https://s.com", res[:data].first[:url], "deve devolver resultado do SearXNG, não do fallback"
    assert_empty router_calls, "router não pode ser chamado quando o SearXNG serviu"
  end

  def test_fetch_nil_chama_router_e_devolve_resultados_do_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c", engine: "tavily" }]))

    res = @tool.run(query: "rails")

    assert_equal :success, res[:status]
    assert_equal "https://f.com", res[:data].first[:url]
    assert_equal 1, router_calls.size
  end

  def test_results_vazio_com_engine_caida_e_router_nil_preserva_erro_nao_aconteceu
    with_fetch({ results: [], unresponsive: ["brave"] })
    set_fallback(nil)

    res = @tool.run(query: "placar")

    assert_equal :error, res[:status]
    assert_match(/busca não aconteceu/, res[:reason])
    assert_match(/brave/, res[:reason])
    assert_equal 1, router_calls.size
  end

  def test_fetch_nil_router_nil_preserva_erro_indisponivel_sem_dereferenciar_nil
    with_fetch(nil)
    set_fallback(nil)

    res = @tool.run(query: "rails")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
  end

  def test_resultados_do_fallback_nao_passam_pelo_relevance_guard
    with_fetch(nil)
    irrelevante = { title: "Roblox login", url: "https://roblox.com/x", content: "jogo", engine: "tavily" }
    set_fallback(fallback([irrelevante]))

    res = @tool.run(query: "reddit ruby performance")

    assert_equal :success, res[:status]
    assert_equal 1, res[:data].size, "RelevanceGuard não deve descartar resultado de API externa"
    assert_equal "https://roblox.com/x", res[:data].first[:url]
  end

  def test_resultado_do_fallback_e_cacheado_nao_chamando_router_de_novo
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c", engine: "tavily" }]))

    res1 = @tool.run(query: "cacheme")
    assert_equal :success, res1[:status]
    res2 = @tool.run(query: "cacheme")
    assert_equal "https://f.com", res2[:data].first[:url]
    assert_equal 1, router_calls.size, "fallback deve ser cacheado; 2ª chamada não repete o router"
  end

  def test_fallback_normaliza_limite_de_resultados
    with_fetch(nil)
    five_results = (1..5).map do |i|
      { title: "T#{i}", url: "https://t#{i}.com", content: "c#{i}", engine: "tavily" }
    end
    set_fallback(fallback(five_results))

    res = @tool.run(query: "limite", limit: 2)

    assert_equal :success, res[:status]
    assert_equal 2, res[:data].size, "fallback deve normalizar o limite de resultados para limit: 2"
    assert_equal "https://t1.com", res[:data][0][:url]
    assert_equal "https://t2.com", res[:data][1][:url]
  end



  def test_fallback_search_api_router_levantando_erro_preserva_erro_original
    with_fetch(nil)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**_kw|
      raise StandardError.new("simulated router network error")
    end

    res = @tool.run(query: "falha-router")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason], "deve preservar o erro original do SearXNG mesmo se o router levantar erro"
  end

  def test_results_vazio_com_engine_caida_e_fallback_vazio_preserva_erro_e_nao_grava_cache
    with_fetch({ results: [], unresponsive: ["brave"] })
    set_fallback(fallback([]))

    res = @tool.run(query: "placar-fallback-vazio")

    assert_equal :error, res[:status], "fallback vazio não pode ser tratado como sucesso"
    assert_match(/busca não aconteceu/, res[:reason])
    assert_match(/brave/, res[:reason])
    assert_equal 1, router_calls.size

    # Não pode ter gravado cache de sucesso; 2ª chamada deve tentar de novo e não retornar :success do cache
    res2 = @tool.run(query: "placar-fallback-vazio")
    assert_equal :error, res2[:status], "segunda chamada não pode acertar cache de sucesso espúrio"
    assert_equal 2, router_calls.size
  end

  def test_fetch_nil_com_fallback_vazio_preserva_erro_indisponivel_e_nao_grava_cache
    with_fetch(nil)
    set_fallback(fallback([]))

    res = @tool.run(query: "rails-fallback-vazio")

    assert_equal :error, res[:status], "fallback vazio com fetch nil não pode retornar :success"
    assert_equal "busca indisponível", res[:reason]
    assert_equal 1, router_calls.size

    res2 = @tool.run(query: "rails-fallback-vazio")
    assert_equal :error, res2[:status]
    assert_equal 2, router_calls.size
  end

  def test_query_com_site_plataforma_chama_searxng_normalmente
    with_fetch({ results: [{ title: "X post", url: "https://x.com/exm", content: "tweet content", engine: "ddg" }],
                 unresponsive: [] })
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:x.com EXM7777")

    assert_equal :success, res[:status]
    assert_equal "https://x.com/exm", res[:data].first[:url]
    assert_empty router_calls, "router não pode ser chamado quando SearXNG serviu"
  end

  def test_query_com_site_plataforma_em_falha_do_searxng_nao_gasta_cota_do_router
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:reddit.com ruby")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "queries com site:reddit.com/x.com/twitter.com nunca devem gastar cota do router externo"
  end

  # REGRESSÃO F7 (plano-fase2 31/08/2026): mesmo se a regex de plataforma
  # falhasse e o router fosse chamado com um site:reddit.com, o resultado
  # da URL `reddit.com` carregaria `trust: :ugc` — NUNCA `:primary`. Defesa
  # em profundidade contra um futuro relaxamento da regex de bloqueio do
  # fallback: o classificador de trust precisa fechar a porta de "fonte
  # primária" que veio de UGC. Aqui simulamos o caminho real do router —
  # a normalização é a mesma de produção (via `SearchApiRouter.normalize_results`),
  # então a chave `:trust` está presente em cada item como aconteceria em prod.
  def test_resultado_reddit_para_site_reddit_carrega_trust_ugc_e_nunca_primary
    # Reflete o que o router real devolveria: o resultado bruto da API
    # (Tavily) passa por `normalize_results`, que adiciona `:trust` por host.
    raw = {
      "results" => [
        { "title" => "Reddit", "url" => "https://reddit.com/r/ruby/x",
          "content" => "post", "score" => 0.85 }
      ]
    }
    normalized = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.7)
    item = normalized.first
    assert_equal :ugc, item[:trust],
                 "URL reddit.com deve carregar trust :ugc após a normalização"
    refute_equal :primary, item[:trust],
                 "URL reddit.com NUNCA pode carregar trust :primary"
  end

  # Reforço do comportamento do tool: quando SearXNG falha e o router seria
  # chamado, `site:reddit.com` mesmo assim pula o router (regex de plataforma).
  # Confirma que o caminho "não cai no pago" do brief item 3 continua de pé.
  def test_site_reddit_com_fallback_normalizado_carrega_trust_mas_nao_chama_router
    with_fetch(nil)
    # Stub do router: se for chamado (NÃO deve), devolve um resultado
    # NORMALIZADO com trust :ugc — defesa em profundidade: mesmo se o
    # bloqueador falhasse, o item carrega :ugc.
    normalized = SearchApiRouter.normalize_results(
      :tavily,
      { "results" => [
        { "title" => "R", "url" => "https://reddit.com/r/x", "content" => "c", "score" => 0.9 }
      ] },
      score_threshold: 0.5
    )
    set_fallback({ results: normalized, engine: :tavily, cost: nil })

    res = @tool.run(query: "site:reddit.com ruby")

    assert_empty router_calls, "regex de plataforma deve continuar bloqueando o router para site:reddit.com"
    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    # A invariante fora do tool — trust do resultado hipotético seria :ugc.
    assert_equal :ugc, normalized.first[:trust],
                 "mesmo se o router fosse chamado, o trust seria :ugc"
  end

  def test_query_com_site_plataforma_com_engine_caida_nao_chama_router
    with_fetch({ results: [], unresponsive: ["brave"] })
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:twitter.com openai")

    assert_equal :error, res[:status]
    assert_match(/busca não aconteceu/, res[:reason])
    assert_empty router_calls, "queries com site:twitter.com não devem chamar router em engine caída"
  end

  def test_query_com_outro_dominio_em_falha_chama_router_normalmente
    with_fetch(nil)
    set_fallback(fallback([{ title: "GH", url: "https://github.com/rails/rails", content: "rails code", engine: "tavily" }]))

    res = @tool.run(query: "site:github.com rails")

    assert_equal :success, res[:status]
    assert_equal "https://github.com/rails/rails", res[:data].first[:url]
    assert_equal 1, router_calls.size, "queries com outros domínios devem chamar o router em fallback"
  end

  def test_query_com_tld_superposto_x_com_br_em_falha_chama_router_normalmente
    with_fetch(nil)
    set_fallback(fallback([{ title: "BR", url: "https://x.com.br/noticia", content: "noticia", engine: "tavily" }]))

    res = @tool.run(query: "site:x.com.br noticia")

    assert_equal :success, res[:status]
    assert_equal "https://x.com.br/noticia", res[:data].first[:url]
    assert_equal 1, router_calls.size, "site:x.com.br não é site:x.com e deve chamar o router em fallback"
  end

  def test_query_com_dominio_superposto_x_community_em_falha_chama_router_normalmente
    with_fetch(nil)
    set_fallback(fallback([{ title: "Comm", url: "https://x.community/p", content: "post", engine: "tavily" }]))

    res = @tool.run(query: "site:x.community post")

    assert_equal :success, res[:status]
    assert_equal "https://x.community/p", res[:data].first[:url]
    assert_equal 1, router_calls.size, "site:x.community não é site:x.com e deve chamar o router em fallback"
  end

  # ── Novos casos de plataforma: path, www, fronteira esquerda (Item B) ───────
  def test_query_com_site_reddit_com_com_subpath_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:reddit.com/r/ruby performance")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "site:reddit.com/r/... deve bloquear o router"
  end

  def test_query_com_site_x_com_com_subpath_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:x.com/user/foo tweet")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "site:x.com/user/... deve bloquear o router"
  end

  def test_query_com_site_twitter_com_com_subpath_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:twitter.com/bar status")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "site:twitter.com/bar deve bloquear o router"
  end

  def test_query_com_www_reddit_com_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "www.reddit.com ruby")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "www.reddit.com deve bloquear o router"
  end

  def test_query_com_site_www_reddit_com_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "F", url: "https://f.com", content: "c" }]))

    res = @tool.run(query: "site:www.reddit.com/r/ruby")

    assert_equal :error, res[:status]
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "site:www.reddit.com/r/ruby deve bloquear o router"
  end

  def test_fakesite_reddit_com_nao_bloqueia_fallback
    with_fetch(nil)
    set_fallback(fallback([{ title: "Fake", url: "https://fake.com", content: "c", engine: "tavily" }]))

    res = @tool.run(query: "fakesite:reddit.com algo")

    assert_equal :success, res[:status]
    assert_equal "https://fake.com", res[:data].first[:url]
    assert_equal 1, router_calls.size, "fakesite:reddit.com não é site:reddit.com e deve chamar o router"
  end

  # F7 (plano-fase2 31/08/2026): o helper `ensure_trust!` aplica o classificador
  # em todos os caminhos do tool (SearXNG direto + fallback). Mesmo quando o
  # stub devolve item cru (sem `:trust`), o item chega ao `data` com o selo.
  # Defesa contra bypass do router e contra stub de teste esquecer a chave.
  def test_ensure_trust_aplica_classificador_em_item_cru_do_fallback
    with_fetch(nil)
    # Stub do router com itens CRUS (sem :trust) — exatamente o que um
    # bypass futuro do router poderia devolver.
    set_fallback({ results: [
      { title: "R", url: "https://reddit.com/r/ruby/x", content: "post", engine: "tavily" },
      { title: "G", url: "https://github.com/rails/rails", content: "code", engine: "tavily" },
      { title: "X", url: "https://exemplo.com/x", content: "?", engine: "tavily" }
    ], engine: :tavily, cost: nil })

    res = @tool.run(query: "ruby")

    assert_equal :success, res[:status]
    assert_equal 3, res[:data].size
    trusts = res[:data].map { |i| i[:trust] }
    assert_includes trusts, :ugc, "reddit.com deve virar :ugc mesmo no stub cru"
    assert_includes trusts, :primary, "github.com deve virar :primary mesmo no stub cru"
    assert_includes trusts, :unknown, "exemplo.com deve virar :unknown mesmo no stub cru"
  end

  # F7: o helper `ensure_trust!` é idempotente — quando o router já rotulou
  # (caminho real, não stub), o item NÃO é sobrescrito com valor diferente.
  def test_ensure_trust_e_idempotente_quando_router_ja_rotulou
    with_fetch(nil)
    # Item JÁ com :trust vindo do router real (passou por normalize_results).
    set_fallback({ results: [
      { title: "R", url: "https://reddit.com/r/x", content: "c", engine: "tavily", trust: :ugc }
    ], engine: :tavily, cost: nil })

    res = @tool.run(query: "ruby")

    assert_equal :success, res[:status]
    assert_equal :ugc, res[:data].first[:trust], "trust do router deve ser preservado"
  end
end

