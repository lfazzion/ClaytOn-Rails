# frozen_string_literal: true

# Testes PUROS da F2 (schema MCP `type` + specialty_first) — sem Rails/docker.
#
# Cobrem o contrato da matriz L5:
#   news     → tavily primeiro
#   entity   → exa primeiro
#   academic → exa primeiro
#   factual  → linkup primeiro (no router o primeiro é linkup, sem flag explícita)
#   code     → SearXNG local; APIS PAGAS NUNCA (custo zero L5 / doutrina 18/08)
#   auto     → comportamento atual (router reordena por regex specialty_for)
#
# Cobrem o contrato do schema MCP:
#   - `type` é parâmetro opcional com enum exato
#   - default é "auto"
#   - argumento fora do enum é rejeitado (additionalProperties: false)
#
# O stub abaixo recria `RubyLLM::Tool` e Rails.cache mínimos só para carregar
# o `WebSearchTool` em ruby puro, sem Rails/docker.

require "minitest/autorun"
require "net/http"
require "json"
require "digest"
require "set"
require "date"

unless defined?(RubyLLM::Tool)
  module RubyLLM
    class Tool
      def self.inherited(subclass)
        subclass.singleton_class.class_eval do
          def description(*); end
          def param(*); end
        end
      end
    end
  end
end

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

class F2SchemaTypePureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  # ── Mapeamento type → provider (matriz L5) ────────────────────────────────
  # Reflete a tabela do plano v2 §2:
  #   news → tavily  · entity → exa  · academic → exa
  #   factual → linkup  · code → searxng (NUNCA API paga)
  # O mapeamento central fica no WebSearchTool; o router recebe `specialty:`
  # como força bruta (testado abaixo).
  TYPE_TO_PROVIDER = {
    "news"     => :tavily,
    "entity"   => :exa,
    "academic" => :exa,
    "factual"  => :linkup,
    "code"     => :searxng,
    "auto"     => nil
  }.freeze

  def setup
    Rails.cache.clear if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:clear)
    @original_call = SearchApiRouter.singleton_class.instance_method(:call)
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

  def with_fetch(payload)
    @tool.define_singleton_method(:fetch) { |_q, _l, _tr| payload }
  end

  def fallback(results, engine: :tavily)
    { results: results, engine: engine, cost: nil }
  end

  # ── F2.1: WebSearchTool aceita `type:` kwarg sem erro ──────────────────────
  # Antes da F2 o `run` rejeitava qualquer kwarg desconhecido via ToolBase.
  def test_run_aceita_type_kwarg
    with_fetch({ results: [{ title: "T", url: "https://t.com", content: "c", engine: "ddg" }],
                 unresponsive: [] })

    res = @tool.run(query: "x", type: "news")
    assert_equal :success, res[:status], "type: kwarg deve ser aceito sem ArgumentError"
  end

  # ── F2.2: type=code → SearXNG local, NUNCA router ────────────────────────
  # Doutrina 18/08 + L5: SearXNG local é custo zero. Code não justifica API
  # paga. Mesmo com SearXNG falhando, o router NÃO é chamado — o erro
  # "busca indisponível" deve voltar ao modelo (e o LLM reformula/usa
  # outra estratégia).
  def test_type_code_nunca_chama_router
    with_fetch(nil)
    set_fallback(fallback([{ title: "Paid", url: "https://paid.com",
                             content: "c", engine: "tavily" }]))

    res = @tool.run(query: "como instalar postgres", type: "code")
    assert_equal :error, res[:status], "type=code não pode devolver sucesso de API paga"
    assert_equal "busca indisponível", res[:reason]
    assert_empty router_calls, "type=code nunca deve chamar API paga"
  end

  # ── F2.3: type=news → Tavily primeiro no fallback ────────────────────────
  # O router já trata tavily como :tavily em `specialty_for(query)`, mas com
  # `type:` explícito do MCP, ele PRECERA mesmo sem o regex casar.
  def test_type_news_chama_tavily_primeiro_no_fallback
    ENV["TAVILY_API_KEY"] = "tv"
    with_fetch(nil)
    # Stub do router: Tavily é o primeiro a ser tentado. Quando recebe o
    # `specialty:` igual a :tavily, devolve sucesso sem consultar Linkup.
    state_calls = @state[:calls]
    tavily_called = false
    # `fb` é capturado AGORA (helper roda com self=instância de teste); sem
    # isso, `next fallback(...)` chamado dentro do `define_method` em outro
    # singleton usaria self=SearchApiRouter e levantaria NoMethodError,
    # capturado pelo rescue do web_search_tools como "fallback falhou".
    fb = fallback([{ title: "News", url: "https://n.com", content: "c",
                     engine: "tavily" }], engine: :tavily)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      if kw[:specialty] == :tavily
        tavily_called = true
        next fb
      end
      # specialty sem tavily → vazio, prova que Tavily não foi para o fim da cascata
      nil
    end

    res = @tool.run(query: "última notícia da SpaceX agora", type: "news", time_range: "day")

    assert_equal :success, res[:status], "type=news com SearXNG fora deve cair em Tavily"
    assert tavily_called, "Tavily precisa ter sido o primeiro provedor tentado quando type=news"
    assert_equal 1, state_calls.size
  end

  # ── F2.4: type=academic → Exa primeiro ────────────────────────────────────
  def test_type_academic_chama_exa_primeiro_no_fallback
    ENV["EXA_API_KEY"] = "ex"
    with_fetch(nil)
    state_calls = @state[:calls]
    exa_called = false
    fb = fallback([{ title: "Paper", url: "https://arxiv.org/x",
                     content: "abstract", engine: "exa" }], engine: :exa)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      if kw[:specialty] == :exa
        exa_called = true
        next fb
      end
      nil
    end

    res = @tool.run(query: "RAG survey 2025 transformers", type: "academic")

    assert_equal :success, res[:status]
    assert exa_called, "Exa precisa ter sido o primeiro provedor tentado quando type=academic"
  end

  # ── F2.5: type=entity → Exa primeiro ──────────────────────────────────────
  def test_type_entity_chama_exa_primeiro_no_fallback
    ENV["EXA_API_KEY"] = "ex"
    with_fetch(nil)
    state_calls = @state[:calls]
    exa_called = false
    fb = fallback([{ title: "Profile", url: "https://about.com/x",
                     content: "entity bio", engine: "exa" }], engine: :exa)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      if kw[:specialty] == :exa
        exa_called = true
        next fb
      end
      nil
    end

    res = @tool.run(query: "biografia Steve Wozniak", type: "entity")

    assert_equal :success, res[:status]
    assert exa_called
  end

  # ── F2.6: type=factual → Linkup primeiro ──────────────────────────────────
  # Linkup é o primeiro no fallback DEFAULT (sem specialty). Mas com
  # `type: factual` explícito, o router recebe `specialty: :linkup` e
  # pula direto para ele (cota permitindo).
  def test_type_factual_chama_linkup_primeiro_no_fallback
    ENV["LINKUP_API_KEY"] = "lk"
    with_fetch(nil)
    state_calls = @state[:calls]
    linkup_called = false
    fb = fallback([{ title: "Factual", url: "https://f.com",
                     content: "fato", engine: "linkup" }], engine: :linkup)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      if kw[:specialty] == :linkup
        linkup_called = true
        next fb
      end
      nil
    end

    res = @tool.run(query: "preço do bitcoin hoje", type: "factual")

    assert_equal :success, res[:status]
    assert linkup_called, "Linkup precisa ter sido o primeiro provedor tentado quando type=factual"
  end

  # ── F2.7: type=auto (default) preserva comportamento atual ────────────────
  # Sem `specialty:` explícito, o router usa o regex `specialty_for(query)`:
  # papers → exa, lookup → tavily, resto → cascata padrão (linkup→exa→tavily).
  def test_type_auto_preserva_comportamento_atual
    with_fetch(nil)
    set_fallback(fallback([{ title: "Cascata", url: "https://c.com",
                             content: "c", engine: "linkup" }]))

    res = @tool.run(query: "preço do bitcoin hoje") # factual genérica

    assert_equal :success, res[:status]
    assert_equal 1, router_calls.size
    # Sem type → router recebe call sem `specialty:` (decisão fica para o regex interno)
    refute router_calls.first.key?(:specialty),
           "type=auto NÃO deve forçar specialty — comportamento atual preservado"
  end

  def test_type_auto_explicito_preserva_comportamento_atual
    with_fetch(nil)
    set_fallback(fallback([{ title: "Cascata", url: "https://c.com",
                             content: "c", engine: "linkup" }]))

    res = @tool.run(query: "preço do bitcoin hoje", type: "auto")

    assert_equal :success, res[:status]
    assert_equal 1, router_calls.size
    refute router_calls.first.key?(:specialty),
           "type=auto explícito também NÃO deve forçar specialty"
  end

  # ── F2.8: type inválido é tratado como auto (não derruba) ────────────────
  # Modelo pode inventar valor fora do enum. Não pode explodir; cai no auto.
  def test_type_invalido_caiu_em_auto
    with_fetch(nil)
    set_fallback(fallback([{ title: "OK", url: "https://ok.com",
                             content: "c", engine: "linkup" }]))

    res = @tool.run(query: "x", type: "qualquer-coisa")
    assert_equal :success, res[:status]
    refute router_calls.first&.key?(:specialty)
  end

  # ── F2.9: SearXNG OK com type=code → não chama router mesmo assim ────────
  # code só proíbe API PAGA no fallback. SearXNG OK = sempre sucesso local.
  def test_searxng_ok_com_type_code_nao_chama_router
    with_fetch({ results: [{ title: "GH", url: "https://github.com/r",
                             content: "code", engine: "ddg" }],
                 unresponsive: [] })

    res = @tool.run(query: "como instalar rails", type: "code")
    assert_equal :success, res[:status]
    assert_empty router_calls, "SearXNG serviu — router não pode ser chamado mesmo com type=code"
  end

  # ── F2.10: SearXNG OK com type=news → não chama router ────────────────────
  # A força do `type` é só no FALLBACK, não no happy path (custo zero).
  def test_searxng_ok_com_type_news_nao_chama_router
    with_fetch({ results: [{ title: "Notícia", url: "https://n.com",
                             content: "c", engine: "ddg" }],
                 unresponsive: [] })

    res = @tool.run(query: "última notícia SpaceX", type: "news")
    assert_equal :success, res[:status]
    assert_empty router_calls, "SearXNG serviu — type não deve pagar nada"
  end

  # ── F4 do plano-fase2 (30/08/2026): origin=discord IGNORA `type` ────────
  # F2 vazou o `type` na tool Rails — Discord não tem `type:` no schema e
  # o caminho não pode ser poluído. No Discord, `type` é forçado a nil
  # e o WebSearchTool cai no fluxo legado (cascata padrão, sem specialty).
  def test_discord_com_type_news_injetado_e_ignorado_sem_specialty
    with_fetch(nil)
    state_calls = @state[:calls]
    fb = fallback([{ title: "Cascata", url: "https://c.com",
                     content: "c", engine: "linkup" }], engine: :linkup)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      # Se origin=:discord mandaria specialty=:tavily, este stub devolve
      # nil — provando que NÃO entrou nessa branch.
      next nil if kw[:specialty] == :tavily
      fb
    end

    begin
      Thread.current[:cleitin_origin] = :discord
      res = @tool.run(query: "última notícia SpaceX agora", type: "news")
      assert_equal :success, res[:status], "Discord ignora type=news injetado — deve cair em cascata padrão"
      assert_equal 1, state_calls.size
      refute state_calls.first.key?(:specialty),
             "Discord: type=news injetado NÃO pode virar specialty=:tavily (sem specialty no caminho Discord)"
    ensure
      Thread.current[:cleitin_origin] = nil
    end
  end

  def test_discord_com_type_news_injetado_e_path_b_reordenado_ainda_sem_specialty
    # F4 cobre as duas camadas: (a) ignora type (sem specialty); (b) Path B
    # reordenado usa o regex `specialty_for(query)` interno. Se (a) falha,
    # o teste pega. Para origin=:discord a fila da cascata segue a ordem
    # LEGADA (linkup 1º), porque o `provider` interno é nil.
    with_fetch(nil)
    state_calls = @state[:calls]
    linkup_called = false
    fb = fallback([{ title: "Cascata", url: "https://c.com",
                     content: "c", engine: "linkup" }], engine: :linkup)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      linkup_called = true
      fb
    end

    begin
      Thread.current[:cleitin_origin] = :discord
      res = @tool.run(query: "última notícia SpaceX agora", type: "news")
      assert_equal :success, res[:status]
      assert linkup_called, "Discord sem specialty: linkup é chamado (cascata padrão)"
      assert_equal 1, state_calls.size
      refute state_calls.first.key?(:specialty),
             "Discord ignora type e cai no fluxo legacy sem specialty"
    ensure
      Thread.current[:cleitin_origin] = nil
    end
  end

  def test_mcp_com_type_news_segue_normalmente_sem_ignorar_type
    # F4: a regra de ignorar `type` é EXCLUSIVA do Discord. MCP path mantém
    # o contrato da F2 — type=news → Tavily primeiro.
    with_fetch(nil)
    state_calls = @state[:calls]
    tavily_called = false
    fb = fallback([{ title: "N", url: "https://n.com",
                     content: "c", engine: "tavily" }], engine: :tavily)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state_calls << kw
      if kw[:specialty] == :tavily
        tavily_called = true
        next fb
      end
      nil
    end

    begin
      Thread.current[:cleitin_origin] = :mcp
      res = @tool.run(query: "última notícia SpaceX agora", type: "news")
      assert_equal :success, res[:status], "MCP path: type=news continua acionando Tavily"
      assert tavily_called, "MCP NÃO ignora type — Tavily primeiro preservado (F2)"
    ensure
      Thread.current[:cleitin_origin] = nil
    end
  end

  # ── F2.11: contracto type→provider documentado e fixo ─────────────────────
  # Quem mantém a tabela: o WebSearchTool tem um método de classe que devolve
  # o provider preferencial. A tabela É O CONTRATO com o schema MCP.
  def test_provider_for_type_doctrine_table
    TYPE_TO_PROVIDER.each do |type, expected|
      actual = WebSearchTool.provider_for_type(type)
      # `assert_equal nil, …` falha em Minitest novo pedindo `assert_nil`.
      # Padrão do repo: assert_nil para nil (vários testes em test/jobs/*).
      if expected.nil?
        assert_nil actual, "type=#{type.inspect} deve mapear para nil"
      else
        assert_equal expected, actual, "type=#{type.inspect} deve mapear para #{expected.inspect}"
      end
    end
  end

  def test_provider_for_type_invalido_retorna_nil
    assert_nil WebSearchTool.provider_for_type(nil)
    assert_nil WebSearchTool.provider_for_type("")
    assert_nil WebSearchTool.provider_for_type("nao-existe")
  end
end