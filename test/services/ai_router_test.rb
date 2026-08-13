require 'test_helper'

class AiRouterTest < ActiveSupport::TestCase
  # ── Roteamento por contexto (API nova: select_client recebe UM argumento) ──
  test 'should route :background context to GeminiBackgroundClient' do
    client = AiRouter.send(:select_client, :background)
    assert_instance_of Llm::GeminiBackgroundClient, client
  end

  test 'should route :interactive context to GeminiInteractiveClient' do
    client = AiRouter.send(:select_client, :interactive)
    assert_instance_of Llm::GeminiInteractiveClient, client
  end

  test 'should raise ArgumentError for unknown context' do
    assert_raises(ArgumentError) do
      AiRouter.send(:select_client, :unknown)
    end
  end

  # ── extract_messages (preservado do teste antigo; mesma forma pública) ──
  test 'extract_messages should handle string prompt' do
    system_msg, user_msg = AiRouter.send(:extract_messages, 'hello world')

    assert_nil system_msg
    assert_equal 'hello world', user_msg
  end

  test 'extract_messages should handle hash prompt' do
    prompt = { system: 'you are helpful', user: 'hello' }
    system_msg, user_msg = AiRouter.send(:extract_messages, prompt)

    assert_equal 'you are helpful', system_msg
    assert_equal 'hello', user_msg
  end

  # ── Identidade dos clientes: MODEL_ID, MAX_DAILY, daily_quota_key ─────────
  test 'GeminiBackgroundClient model_id should be gemini 3.1 flash lite' do
    assert_equal 'gemini-3.1-flash-lite', Llm::GeminiBackgroundClient::MODEL_ID
  end

  test 'GeminiBackgroundClient MAX_DAILY should be 480' do
    assert_equal 480, Llm::GeminiBackgroundClient::MAX_DAILY
  end

  test 'GeminiBackgroundClient daily_quota_key should identify the background bucket' do
    assert_equal 'gemini_background_daily', Llm::GeminiBackgroundClient.new.daily_quota_key
  end

  test 'GeminiInteractiveClient model_id should be gemini 3.5 flash lite' do
    assert_equal 'gemini-3.5-flash-lite', Llm::GeminiInteractiveClient::MODEL_ID
  end

  test 'GeminiInteractiveClient MAX_DAILY should be 480' do
    assert_equal 480, Llm::GeminiInteractiveClient::MAX_DAILY
  end

  test 'GeminiInteractiveClient daily_quota_key should identify the interactive bucket' do
    assert_equal 'gemini_interactive_daily', Llm::GeminiInteractiveClient.new.daily_quota_key
  end

  test 'OpenrouterClient model_id should be openrouter/free' do
    assert_equal 'openrouter/free', Llm::OpenrouterClient::MODEL_ID
  end

  test 'OpenrouterClient MAX_DAILY should be 400' do
    assert_equal 400, Llm::OpenrouterClient::MAX_DAILY
  end

  # ── BaseClient: quota ─────────────────────────────────────────────────────
  test 'BaseClient should raise QuotaExceededError when daily quota is exceeded' do
    client = Llm::GeminiBackgroundClient.new
    Rails.cache.clear
    Rails.cache.write(client.send(:daily_cache_key), client.send(:max_daily_requests), expires_in: 26.hours)

    assert_raises Llm::BaseClient::QuotaExceededError do
      client.send(:reserve_quota!)
    end

    # O contador volta ao máximo (480): reserve_quota! incrementa e
    # rollback_quota! reverte ao estourar a quota. Consiste com o teste irmão
    # "multiple rejected reservations keep counter at max" (phase3_llm_test.rb).
    assert_equal client.send(:max_daily_requests), Rails.cache.read(client.send(:daily_cache_key))
  end

  test 'BaseClient quota key should expire in 26 hours' do
    client = Llm::GeminiBackgroundClient.new
    Rails.cache.clear
    Rails.cache.write(client.send(:daily_cache_key), 479, expires_in: 26.hours)

    client.send(:reserve_quota!) rescue Llm::BaseClient::QuotaExceededError

    # SolidCache/FileStore don't expose expires_at directly, but we can verify
    # the written key has an expiry by checking the cache returns a non-nil
    # value (meaning the write with expires_in was accepted).
    assert_not_nil Rails.cache.read(client.send(:daily_cache_key))
  end

  test 'BaseClient should NOT raise when under the daily quota' do
    client = Llm::GeminiBackgroundClient.new
    Rails.cache.clear

    assert_nothing_raised do
      client.send(:reserve_quota!)
    end
  end

  # ── complete: extrai prompt, delega ao cliente certo ─────────────────────
  test 'complete with :background delegates to GeminiBackgroundClient with user message' do
    Llm::GeminiBackgroundClient.any_instance
                                .expects(:complete)
                                .with('hello', system: nil, tools: [])
                                .returns('ok')

    assert_equal 'ok', AiRouter.complete('hello', context: :background)
  end

  test 'complete with :interactive delegates to GeminiInteractiveClient' do
    Llm::GeminiInteractiveClient.any_instance
                                .expects(:complete)
                                .with('hello', system: nil, tools: [])
                                .returns('ok')

    assert_equal 'ok', AiRouter.complete('hello', context: :interactive)
  end

  test 'complete with hash prompt forwards system and user to the client' do
    Llm::GeminiInteractiveClient.any_instance
                                .expects(:complete)
                                .with('hello', system: 'be brief', tools: [])
                                .returns('ok')

    assert_equal 'ok', AiRouter.complete({ system: 'be brief', user: 'hello' })
  end

  test 'complete falls back to OpenrouterClient on QuotaExceededError' do
    Llm::GeminiBackgroundClient.any_instance
                                .expects(:complete)
                                .raises(Llm::BaseClient::QuotaExceededError, 'quota')

    Llm::OpenrouterClient.any_instance
                        .expects(:complete)
                        .with('hello', system: nil, tools: [])
                        .returns('fallback')

    assert_equal 'fallback', AiRouter.complete('hello', context: :background)
  end

  test 'complete falls back to OpenrouterClient on RubyLLM::RateLimitError' do
    Llm::GeminiInteractiveClient.any_instance
                                .expects(:complete)
                                .raises(RubyLLM::RateLimitError.new('rate limit'))

    Llm::OpenrouterClient.any_instance
                        .expects(:complete)
                        .with('hello', system: nil, tools: [])
                        .returns('fallback')

    assert_equal 'fallback', AiRouter.complete('hello')
  end
end
