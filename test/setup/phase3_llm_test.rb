# frozen_string_literal: true

require 'test_helper'

class Phase3LlmTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end
  teardown do
    Rails.cache.clear
  end

  def client
    @client ||= Llm::GeminiBackgroundClient.new
  end

  def cache_key
    client.send(:daily_cache_key)
  end

  test 'reserve_quota! below limit succeeds and returns count' do
    assert_nothing_raised do
      result = client.send(:reserve_quota!)
      assert_equal 1, result
    end
  end

  test 'reserve_quota! at limit succeeds (count equals max)' do
    max = client.max_daily_requests
    # Pre-write to ensure file_store locks correctly (lock_file only locks
    # when the file already exists). This mirrors production SolidCache
    # behaviour where increment is natively atomic.
    Rails.cache.write(cache_key, max - 1, expires_in: 26.hours)

    result = client.send(:reserve_quota!)
    assert_equal max, result
  end

  test 'reserve_quota! above limit raises QuotaExceededError' do
    max = client.max_daily_requests
    Rails.cache.write(cache_key, max, expires_in: 26.hours)

    assert_raises Llm::BaseClient::QuotaExceededError do
      client.send(:reserve_quota!)
    end
  end

  test 'concurrent reserves: between N attempts for quota M, exactly M succeed (reservations only)' do
    max = 5
    # Override max_daily_requests on the instance to a small number for
    # a deterministic concurrency test.
    client.define_singleton_method(:max_daily_requests) { max }

    # file_store does not provide true atomic CAS increment — use MemoryStore
    # which guarantees atomic increment/decrement via in-process locking.
    # This mirrors production SolidCache behaviour where increment is
    # natively atomic.
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(cache_key, 0, expires_in: 26.hours)

    total = max * 2
    success_count = 0
    mutex = Mutex.new
    started = Queue.new

    threads = Array.new(total) do
      t = Thread.new do
        started << true
        begin
          client.send(:reserve_quota!)
          mutex.synchronize { success_count += 1 }
        rescue Llm::BaseClient::QuotaExceededError
          # rejected — expected
        end
      end
      t.abort_on_exception = true
      t
    end

    # Release all threads simultaneously via the queue barrier
    total.times { started.pop }
    threads.each(&:join)

    # Restore original cache store
    Rails.cache = original_store

    assert_equal max, success_count,
      "expected exactly #{max} reservations to succeed, got #{success_count}"
  end

  test 'complete rolls back quota when RubyLLM.chat raises non-rate-limit error (preparação)' do
    # Start at 0 so a single reservation succeeds
    Rails.cache.write(cache_key, 0, expires_in: 26.hours)

    # Stub RubyLLM.chat to raise a non-rate-limit error (e.g. network timeout)
    error = StandardError.new('network timeout')
    RubyLLM.stubs(:chat).raises(error)

    # Override max_daily_requests so reserve_quota! succeeds at count=0->1
    client.define_singleton_method(:max_daily_requests) { 5 }

    assert_raises(StandardError) { client.complete('hello') }

    # Quota should have been rolled back: count back to 0
    assert_equal 0, Rails.cache.read(cache_key)
  end

  test 'complete does NOT roll back quota when chat.ask raises (requisição já enviada ao provedor)' do
    # P1 do sol (13/08): falha DEPOIS do envio (timeout/parse do ask) NÃO reverte
    # a reserva — o provedor já contou a chamada mesmo sem resposta útil.
    Rails.cache.write(cache_key, 0, expires_in: 26.hours)

    chat_stub = stub('chat')
    chat_stub.stubs(:ask).raises(StandardError.new('timeout after send'))
    RubyLLM.stubs(:chat).returns(chat_stub)
    client.define_singleton_method(:max_daily_requests) { 5 }

    assert_raises(StandardError) { client.complete('hello') }

    assert_equal 1, Rails.cache.read(cache_key),
                 'quota consumida quando a requisição saiu para o provedor'
  end

  test 'complete does NOT roll back quota when QuotaExceededError is raised' do
    # Pre-write so reserve_quota! immediately hits the limit
    max = client.max_daily_requests
    Rails.cache.write(cache_key, max, expires_in: 26.hours)

    RubyLLM.stubs(:chat)

    assert_raises(Llm::BaseClient::QuotaExceededError) do
      client.complete('hello')
    end

    # Count should remain at max (not rolled back) since QuotaExceededError
    # is raised inside reserve_quota! before RubyLLM.chat is called
    assert_equal max, Rails.cache.read(cache_key)
  end

  test 'complete rolls back quota on RubyLLM::RateLimitError' do
    Rails.cache.write(cache_key, 0, expires_in: 26.hours)

    RubyLLM.stubs(:chat).raises(RubyLLM::RateLimitError.new('rate limited'))

    client.define_singleton_method(:max_daily_requests) { 5 }

    assert_raises(RubyLLM::RateLimitError) { client.complete('hello') }

    # Quota should be rolled back so AiRouter can fall back to another provider
    assert_equal 0, Rails.cache.read(cache_key)
  end

  test 'multiple rejected reservations keep counter at max without inflating' do
    max = client.max_daily_requests
    Rails.cache.write(cache_key, max, expires_in: 26.hours)

    5.times do
      assert_raises(Llm::BaseClient::QuotaExceededError) do
        client.send(:reserve_quota!)
      end
    end

    assert_equal max, Rails.cache.read(cache_key)
  end

  # ── ACHADO B (P1, sol 13/08): se AMBAS as chamadas a Rails.cache.increment
  # retornarem nil, reserve_quota! retornava nil e o provedor era chamado SEM
  # reserva (bypass silencioso da quota). Deve levantar erro explícito ANTES
  # de criar qualquer chat. ──
  test 'reserve_quota! raises when both increment attempts return nil (no silent quota bypass)' do
    # Simula o backend de cache respondendo nil em AMBAS as tentativas de
    # increment (ex.: backend sem CAS/sem suporte a increment).
    Rails.cache.stubs(:increment).returns(nil)

    assert_raises(RuntimeError) { client.send(:reserve_quota!) }
  end
end
require 'test_helper'

class Phase3InfrastructureTest < ActiveSupport::TestCase
  test 'all Phase 3 models should exist' do
    assert defined?(DiscoveredProfile), 'DiscoveredProfile model not found'
  end

  test 'all Phase 3 services should exist' do
    assert defined?(AiRouter), 'AiRouter service not found'
    assert defined?(Discovery::SocialGraphAnalyzer), 'SocialGraphAnalyzer not found'
    assert defined?(Discovery::ProfileClassifier), 'ProfileClassifier not found'
  end

  test 'all Phase 3 LLM clients should exist' do
    assert defined?(Llm::BaseClient), 'Llm::BaseClient not found'
    assert defined?(Llm::GeminiBackgroundClient), 'Llm::GeminiBackgroundClient not found'
    assert defined?(Llm::GeminiInteractiveClient), 'Llm::GeminiInteractiveClient not found'
    assert defined?(Llm::OpenrouterClient), 'Llm::OpenrouterClient not found'
    assert defined?(Llm::PromptLoader), 'Llm::PromptLoader not found'
  end

  test 'DiscoveryJob should exist and be an ApplicationJob' do
    assert defined?(DiscoveryJob), 'DiscoveryJob not found'
    assert DiscoveryJob < ApplicationJob, 'DiscoveryJob should inherit from ApplicationJob'
  end

  test 'discovered_profiles table should exist' do
    assert ActiveRecord::Base.connection.table_exists?(:discovered_profiles),
           'Table discovered_profiles should exist'
  end

  test 'discovered_profiles should have expected columns' do
    columns = ActiveRecord::Base.connection.columns(:discovered_profiles)
    column_names = columns.map(&:name)

    %w[id platform username bio profile_url classification classification_reason
       source_profile_id classified_at created_at updated_at].each do |col|
      assert_includes column_names, col, "Column #{col} missing from discovered_profiles"
    end
  end

  test 'discovered_profiles classification should have no default zero' do
    col = ActiveRecord::Base.connection.columns(:discovered_profiles)
                            .find { |c| c.name == 'classification' }
    assert_nil col.default, 'classification should have no default (nil means unclassified)'
  end

  test 'prompt files should exist' do
    %w[base discovery analysis].each do |name|
      file = Rails.root.join("config/prompts/system/#{name}.yml")
      assert file.exist?, "Prompt file #{name}.yml not found"
    end

    %w[rules time_injection].each do |name|
      file = Rails.root.join("config/prompts/partials/_#{name}.yml")
      assert file.exist?, "Partial file _#{name}.yml not found"
    end
  end

  test 'recurring.yml should contain discovery_job entry' do
    recurring = YAML.safe_load_file(Rails.root.join('config/recurring.yml'))
    production = recurring['production']

    assert production.key?('discovery_job'), 'discovery_job not found in recurring.yml'
    assert_equal 'DiscoveryJob', production['discovery_job']['class']
  end

  test 'ruby_llm initializer should exist' do
    file = Rails.root.join('config/initializers/ruby_llm.rb')
    assert file.exist?, 'ruby_llm initializer not found'
  end

  test 'scraping_modules initializer should require LLM modules' do
    content = File.read(Rails.root.join('config/initializers/scraping_modules.rb'))

    assert_includes content, 'llm/base_client'
    assert_includes content, 'llm/gemini_background_client'
    assert_includes content, 'llm/gemini_interactive_client'
    assert_includes content, 'llm/openrouter_client'
    assert_includes content, 'llm/prompt_loader'
  end

  test 'application.rb should ignore llm in autoload' do
    content = File.read(Rails.root.join('config/application.rb'))

    assert_includes content, 'llm'
  end
end
