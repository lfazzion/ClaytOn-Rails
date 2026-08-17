# frozen_string_literal: true

# Testes PUROS do http_post do SearchApiRouter (Defeito 1: retryable marking).
# Cobrem: HTTP 500..599 → retryable=true; 4xx → retryable=false; timeout → retryable.
# Sem Rails/docker: stub mínimo de Rails + stub de Net::HTTP.new.

require "minitest/autorun"
require "net/http"
require "json"
require "date"

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

unless defined?(Rails::PureMemoryCacheStore)
  module Rails
    class PureMemoryCacheStore
      def initialize
        @data = {}
      end

      def read(key)
        @data[key]
      end

      def write(key, value, **_options)
        @data[key] = value
      end

      def clear
        @data.clear
      end
    end
  end
end

unless Rails.respond_to?(:cache) && Rails.cache
  def Rails.cache
    @pure_cache_instance ||= Rails::PureMemoryCacheStore.new
  end
end

require "active_record"
unless defined?(ApplicationRecord)
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end

require_relative "../../app/services/search_api_router"

# Mock HTTP response que responde a code, body, is_a?, []
class FakeHttpResponse
  def initialize(code, body = nil, success: nil, headers: {})
    @code = code
    @body = body
    @success = success
    @headers = headers || {}
  end
  attr_reader :code
  def body
    @body
  end
  def [](key)
    found_key = @headers.keys.find { |k| k.to_s.casecmp?(key.to_s) }
    found_key ? @headers[found_key] : nil
  end
  def is_a?(klass)
    if klass == Net::HTTPSuccess
      @success.nil? ? @code.to_s.start_with?("2") : @success
    else
      klass == Net::HTTPResponse
    end
  end
  def read_body
    @body
  end
end

class SearchApiRouterHttpPostTest < Minitest::Test
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
    # Salva a implementação original de http_post e Rails.logger para restaurar no teardown.
    @original_http_post = SearchApiRouter.singleton_class.instance_method(:http_post)
    @original_rails_logger = Rails.singleton_class.instance_method(:logger) if Rails.respond_to?(:logger)
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }
  end

  def teardown
    SearchApiRouter.singleton_class.send(:define_method, :http_post, @original_http_post)
    if defined?(@original_rails_logger) && @original_rails_logger
      Rails.singleton_class.send(:define_method, :logger, @original_rails_logger)
      @original_rails_logger = nil
    end
    # Restaura Net::HTTP.new (caso algum teste tenha sobrescrito).
    if defined?(@original_net_http_new) && @original_net_http_new
      Net::HTTP.define_singleton_method(:new, @original_net_http_new)
      @original_net_http_new = nil
    end
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Net::HTTP.new retorna um mock cujo #request devolve a resposta stubada.
  def with_http_response(code, body = nil, success: nil, headers: {})
    fake_http = Object.new
    fake_response = FakeHttpResponse.new(code, body, success: success, headers: headers)
    fake_http.define_singleton_method(:request) { |req| fake_response }
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }

    @original_net_http_new = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) do |host, port|
      fake_http
    end

    yield
  ensure
    # teardown também restaura, mas garantimos aqui para não vazar para
    # outros testes em ordem aleatória.
    if @original_net_http_new
      Net::HTTP.define_singleton_method(:new, @original_net_http_new)
      @original_net_http_new = nil
    end
  end

  # ── (1) http_post: 500..599 → retryable=true ────────────────────────────────
  def test_http_post_500_marks_retryable_true
    with_http_response(500, '{"results":[]}') do
      res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
      assert_equal false, res[:ok], "500 não é sucesso"
      assert_equal true, res[:retryable], "500 deve ser retryable=true"
    end
  end

  def test_http_post_599_marks_retryable_true
    with_http_response(599, '{"results":[]}') do
      res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
      assert_equal false, res[:ok], "599 não é sucesso"
      assert_equal true, res[:retryable], "599 deve ser retryable=true"
    end
  end

  # ── (1) http_post: 4xx → retryable=false ─────────────────────────────────────
  def test_http_post_429_marks_retryable_false
    with_http_response(429, '{"results":[]}') do
      res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
      assert_equal false, res[:ok], "429 não é sucesso"
      assert_equal false, res[:retryable], "429 deve ser retryable=false"
    end
  end

  def test_http_post_400_marks_retryable_false
    with_http_response(400, '{}') do
      res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
      assert_equal false, res[:ok], "400 não é sucesso"
      assert_equal false, res[:retryable], "400 deve ser retryable=false"
    end
  end

  # ── (1) timeout → retryable=true ────────────────────────────────────────────
  def test_http_post_timeout_marks_retryable_true
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) do |req|
      raise Net::ReadTimeout.new("timeout")
    end

    orig = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) do |host, port|
      fake_http
    end

    res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
    assert_equal false, res[:ok]
    assert_equal true, res[:retryable], "timeout deve ser retryable=true"
  ensure
    Net::HTTP.define_singleton_method(:new, orig)
  end

  # ── (1) attempt: retry conta apenas uma chamada extra para 5xx ──────────────
  # O stub de http_post conta chamadas; 5xx deve disparar exatamente 1 retry.
  def test_attempt_5xx_faz_exatamente_1_retry
    call_count = 0
    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, time_filter|
      call_count += 1
      { ok: false, body: nil, reason: "HTTP 500", retryable: true }
    end

    result, _reason = SearchApiRouter.attempt(:tavily, "q", 5, nil, Date.today, score_threshold: 0.7)
    assert_nil result, "5xx retryável deve falhar após retry"
    assert_equal 2, call_count, "500 deve disparar exatamente 1 retry (2 chamadas)"
  end

  # ── (1) attempt: 4xx NÃO retry ─────────────────────────────────────────────
  def test_attempt_429_nao_retry
    call_count = 0
    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, time_filter|
      call_count += 1
      { ok: false, body: nil, reason: "HTTP 429", retryable: false }
    end

    result, _reason = SearchApiRouter.attempt(:tavily, "q", 5, nil, Date.today, score_threshold: 0.7)
    assert_nil result
    assert_equal 1, call_count, "429 não deve retry"
  end

  # ── (2) Retry-After: preserva 4xx/429 sem retry, extrai header e inclui no reason ─
  def test_http_post_429_com_retry_after_inclui_no_reason_e_permanece_retryable_false
    logged_messages = []
    logger = Object.new
    logger.define_singleton_method(:info) { |*| }
    logger.define_singleton_method(:warn) { |msg| logged_messages << msg }
    logger.define_singleton_method(:error) { |*| }

    orig_logger = Rails.singleton_class.instance_method(:logger) if Rails.respond_to?(:logger)
    Rails.define_singleton_method(:logger) { logger }

    begin
      with_http_response(429, '{"error":"rate_limited"}', headers: { "Retry-After" => "120" }) do
        res = SearchApiRouter.http_post(:tavily, "q", 5, nil)
        assert_equal false, res[:ok]
        assert_equal false, res[:retryable], "429 com Retry-After NÃO deve ser retryable"
        assert_match(/HTTP 429/, res[:reason])
        assert_match(/Retry-After:\s*120/i, res[:reason])
        assert logged_messages.any? { |m| m.include?("[SearchApiRouter]") && m.include?("120") }, "deve logar com prefixo [SearchApiRouter] e valor do Retry-After"
      end
    ensure
      Rails.singleton_class.send(:define_method, :logger, orig_logger) if orig_logger
    end
  end

  def test_http_post_com_retry_after_lowercase_inclui_no_reason
    with_http_response(429, '{}', headers: { "retry-after" => "45" }) do
      res = SearchApiRouter.http_post(:exa, "q", 5, nil)
      assert_equal false, res[:ok]
      assert_equal false, res[:retryable]
      assert_match(/45/, res[:reason])
      assert_match(/Retry-After:\s*45/i, res[:reason])
    end
  end

  def test_http_post_com_retry_after_uppercase_inclui_no_reason
    with_http_response(429, '{}', headers: { "RETRY-AFTER" => "60" }) do
      res = SearchApiRouter.http_post(:linkup, "q", 5, nil)
      assert_equal false, res[:ok]
      assert_equal false, res[:retryable]
      assert_match(/60/, res[:reason])
      assert_match(/Retry-After:\s*60/i, res[:reason])
    end
  end

  def test_rails_logger_restoration_and_isolation
    # Garante que Rails.logger é válido e não é um mock órfão que quebra métodos como info/warn/error
    assert Rails.respond_to?(:logger), "Rails deve responder a logger"
    refute_nil Rails.logger, "Rails.logger não deve ser nil"
    assert_respond_to Rails.logger, :info
    assert_respond_to Rails.logger, :warn
    assert_respond_to Rails.logger, :error
  end
end
