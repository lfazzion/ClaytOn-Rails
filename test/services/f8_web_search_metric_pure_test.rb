# frozen_string_literal: true

# Testes PUROS do F8 (métricas) — sem Rails/docker, ruby puro.
#
# Cobre o aceite do brief D5-F8:
#   "1 teste: uma busca com stub gera a linha [WebSearchMetric] com os
#    campos-chave"
#
# O teste stuba o logger onde a métrica é gravada, executa uma busca
# real do WebSearchTool com `fetch` stubado e verifica:
#   1. A linha `[WebSearchMetric] {json}` foi gravada no logger.
#   2. O JSON tem os campos canônicos do contrato F8 (origem, provider,
#      type, query_len, results_count, latency_ms, from_cache=false).
#   3. Cache hit NÃO emite métrica (brief: "em cada busca executada
#      (nao cache hit)").
#
# Os campos opcionais (cost_usd, engine, trust_*) ficam como
# asserções adicionais só quando a busca stubada os produz — fora isso,
# nil é o contrato.

require "minitest/autorun"
require "net/http"
require "json"
require "digest"
require "set"
require "date"
require "stringio"

# ── stub de RubyLLM::Tool (apenas o necessário p/ carregar a tool) ──────────
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

# ── stub de Rails (mínimo) ─────────────────────────────────────────────────
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

      def delete(key)
        @data.delete(key)
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

require_relative "../../app/services/search_metric"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/web_search_tools"
require_relative "../../app/services/search_api_router"

class F8WebSearchMetricPureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  # Captura linhas `[WebSearchMetric]` no nível info do logger.
  class CollectingLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(msg = nil, *_args)
      @lines << msg.to_s
      true
    end

    def warn(*_); end
    def error(*_); end
    def debug(*_); end
  end

  def setup
    Rails.cache.clear if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:clear)
    WebSearchTool.reset_searxng_turn_state!
    @original_call = SearchApiRouter.singleton_class.instance_method(:call)
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }

    state = { calls: [], fallback: nil }
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**kw|
      state[:calls] << kw
      state[:fallback]
    end
    @state = state

    @io = StringIO.new
    SearchMetric.attach_logger(@io)

    @tool = WebSearchTool.new
  end

  def teardown
    SearchApiRouter.singleton_class.send(:define_method, :call, @original_call)
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
    Rails.cache.clear if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:clear)
    SearchMetric.detach_logger
  end

  def with_fetch(payload)
    @tool.define_singleton_method(:fetch) { |_q, _l, _tr| payload }
  end

  def set_fallback(value)
    @state[:fallback] = value
  end

  def metric_lines
    @io.string.lines.map(&:chomp).select { |l| l.include?("[WebSearchMetric]") }
  end

  def parse_metric(line)
    json_part = line.sub(/.*\[WebSearchMetric\]\s*/, "")
    JSON.parse(json_part)
  end

  # ── Aceite do brief ──────────────────────────────────────────────────────
  def test_busca_com_stub_gera_linha_web_search_metric_com_campos_chave
    # SearXNG direto, type=auto (provider nil → "searxng"), origin nil (teste).
    with_fetch({
      results: [
        { title: "S1", url: "https://github.com/rails/rails", content: "rails code", engine: "github" },
        { title: "S2", url: "https://stackoverflow.com/q/1", content: "answer", engine: "stackoverflow" }
      ],
      unresponsive: []
    })

    res = @tool.run(query: "rails")
    assert_equal :success, res[:status], "busca stubada deve dar sucesso"

    lines = metric_lines
    assert_equal 1, lines.size, "uma busca executada deve emitir exatamente 1 linha [WebSearchMetric]"

    metric = parse_metric(lines.first)
    # Campos canônicos — pelo menos os seguintes devem aparecer com o
    # tipo correto:
    assert_equal "searxng",   metric["provider"],     "provider SearXNG direto = searxng"
    assert_equal "auto",      metric["type"],         "type=auto (ausente na chamada)"
    assert_nil   metric["origin"],                    "sem Thread.current[:cleitin_origin] → nil"
    assert_equal 5,           metric["query_len"],    "query_len conta a string \"rails\""
    assert_equal 2,           metric["results_count"]
    assert_equal false,       metric["from_cache"],   "cache hit não emite — from_cache=false sempre"
    assert_kind_of Integer,   metric["latency_ms"]
    assert_operator metric["latency_ms"], :>=, 0

    # Campos opcionais do brief:
    assert_equal "searxng", metric["source"], "SearXNG direto → source=searxng"
    assert_nil metric["cost_usd"], "SearXNG não tem cost_usd"
    assert_equal "github", metric["engine"], "engine do 1º resultado stubado"
    # Trust counts (chave canônica do brief):
    assert_equal 1, metric["trust_primary"], "github.com → primary"
    assert_equal 1, metric["trust_ugc"],     "stackoverflow.com → ugc"
    assert_equal 0, metric["trust_unknown"]
    # ISO ts presente e parseável:
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, metric["ts"])
    assert Time.iso8601(metric["ts"]), "ts deve ser ISO8601"
  end

  def test_cache_hit_nao_emite_metrica
    # 1ª chamada: popula o cache.
    with_fetch({
      results: [{ title: "S", url: "https://s.com", content: "c", engine: "ddg" }],
      unresponsive: []
    })
    @tool.run(query: "rails")
    baseline_lines = metric_lines.size

    # 2ª chamada com fetch que LEVANTA — se o cache não tiver hit,
    # o fetch seria chamado e a exceção viria. Como vamos esvaziar o
    # fallback e o fetch stubado retorna nil também seria problema.
    # A forma mais limpa é trocar o fetch para um que falhe:
    @tool.define_singleton_method(:fetch) { |*| raise "fetch NAO deveria ser chamado em cache hit" }

    # Limpa origem/contagem (mas NÃO o cache).
    res = @tool.run(query: "rails")
    assert_equal :success, res[:status], "2ª chamada deve acertar o cache"

    assert_equal baseline_lines, metric_lines.size,
                 "cache hit NÃO emite métrica (brief: 'em cada busca executada (nao cache hit)')"
  end

  def test_fallback_pago_emite_provider_e_source_router_e_cost
    with_fetch(nil) # SearXNG falhou
    set_fallback({
      results: [{ title: "T", url: "https://arxiv.org/abs/1", content: "paper", engine: "tavily" }],
      engine: :tavily,
      cost: 2
    })

    @tool.run(query: "arxiv papers")

    lines = metric_lines
    assert_equal 1, lines.size
    metric = parse_metric(lines.first)
    assert_equal "tavily", metric["provider"], "provider efetivo do fallback = tavily"
    assert_equal "router", metric["source"],   "fallback → source=router"
    assert_equal 2,        metric["cost_usd"], "Tavily expôs usage.credits=2"
    assert_equal 1,        metric["results_count"]
  end

  # ── L1 (02/09/2026): jitter_ms/backoff_ms no F8 (SCHEMA_VERSION 1->2) ──────
  def test_metrica_schema_v2_carrega_jitter_ms_e_backoff_ms
    with_fetch({
      results: [{ title: "S", url: "https://s.com", content: "c", engine: "ddg" }],
      unresponsive: []
    })

    res = @tool.run(query: "rails")
    assert_equal :success, res[:status]

    metric = parse_metric(metric_lines.first)
    assert_equal 2, metric["v"], "SCHEMA_VERSION deve subir de 1 para 2"
    assert_equal 0, metric["jitter_ms"], "1a busca do turno: jitter_ms=0"
    assert_equal 0, metric["backoff_ms"], "sem sinal de bloqueio prévio: backoff_ms=0"
  end

  def test_search_metric_record_aceita_jitter_ms_backoff_ms_explicitos_sem_quebrar_leitores_antigos
    SearchMetric.record(
      origin: nil, provider: nil, type: "auto", query_len: 5, results_count: 1,
      latency_ms: 10, source: "searxng", jitter_ms: 321, backoff_ms: 5000
    )

    metric = parse_metric(metric_lines.first)
    assert_equal 321,  metric["jitter_ms"]
    assert_equal 5000, metric["backoff_ms"]
    # Campos do contrato v1 continuam presentes e no formato de sempre —
    # bump de schema é aditivo, não quebra leitor antigo.
    assert_equal "auto", metric["type"]
    assert_equal false,  metric["from_cache"]
  end
end
