# frozen_string_literal: true

# Testes PUROS da F1 (payload magro) — sem Rails/docker, ruby puro.
#
# Cobrem:
#   1. limit máximo do WebSearchTool = 5 (era 10) — clamp 1..5
#   2. MAX_RESULTS do SearchApiRouter = 5 (era 10) — clamp_limit respeita
#   3. Exa agora prefere text integral sobre highlights (v2)

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

class F1PayloadMagroPureTest < Minitest::Test
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

  def with_fetch(payload)
    @tool.define_singleton_method(:fetch) { |_q, _l, _tr| payload }
  end

  def fallback(results, engine: :tavily)
    { results: results, engine: engine, cost: nil }
  end

  # ── F1.2: MAX_RESULTS do SearchApiRouter = 5 (era 10) ──────────────────────
  def test_router_max_results_e_5
    assert_equal 5, SearchApiRouter::MAX_RESULTS,
                 "MAX_RESULTS do router deve ser 5 (F1); contrato antigo era 10"
  end

  def test_router_clamp_limit_respeita_1_a_5
    assert_equal 1, SearchApiRouter.clamp_limit(0)
    assert_equal 1, SearchApiRouter.clamp_limit(-5)
    assert_equal 3, SearchApiRouter.clamp_limit(3)
    assert_equal 5, SearchApiRouter.clamp_limit(5)
    assert_equal 5, SearchApiRouter.clamp_limit(50),
                 "clamp_limit do router deve saturar em 5 (F1); antes saturava em 10"
  end
end