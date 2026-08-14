# frozen_string_literal: true

require "test_helper"

class FakeChatResponse
  attr_reader :content

  def initialize(content)
    @content = content
  end
end

class FakeChat
  attr_reader :instructions, :temperature, :params, :asked_prompts

  def initialize(response_content)
    @response_content = response_content
    @asked_prompts = []
  end

  def with_instructions(inst)
    @instructions = inst
    self
  end

  def with_temperature(temp)
    @temperature = temp
    self
  end

  def with_params(params)
    @params = params
    self
  end

  def ask(prompt)
    @asked_prompts << prompt
    if @response_content.is_a?(Proc)
      FakeChatResponse.new(@response_content.call(prompt))
    else
      FakeChatResponse.new(@response_content)
    end
  end
end

class SentimentClassifierTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    SentimentDailyQuota.delete_all
    @target = SentimentTarget.create!(name: "Cleitin Classifier", query: "cleitin")
    @run = @target.sentiment_runs.create!(
      status: "collected",
      frozen_spec: { "name" => "Cleitin Classifier" },
      started_at: Time.zone.parse("2026-08-10 12:00:00")
    )
    3.times do |i|
      @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "ext_#{i}",
        text: "Frase de teste #{i} com palavras suficientes para o classificador",
        collected_at: Time.current
      )
    end
  end

  test "lote de 100 vira 1 requisição e salva labels com sucesso" do
    valid_json = {
      predictions: [
        { id: 0, sentiment: "positive" },
        { id: 1, sentiment: "negative" },
        { id: 2, sentiment: "neutral" }
      ]
    }.to_json

    fake_chat = FakeChat.new(valid_json)
    RubyLLM.stubs(:chat).with(model: Research::Sentiment::Classifier::PRIMARY_MODEL).returns(fake_chat)

    Research::Sentiment::Classifier.classify(@run)
    @run.reload

    assert_equal 3, @run.classified_count
    assert_equal 0, @run.unparsed_count
    assert_equal Research::Sentiment::Classifier::PRIMARY_MODEL, @run.model_id
    assert_equal true, @run.snapshot_pinned
    assert_equal 3, @run.sentiment_labels.count
  end

  test "escada de modelos falha totalmente e levanta AllModelsFailed com alerta admin" do
    RubyLLM.stubs(:chat).raises(StandardError.new("LLM offline"))
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ "id" => "guild_test" }])
    DiscordApiClient.stubs(:create_text_channel).returns({ "id" => "admin_channel_test" })
    DiscordApiClient.expects(:send_message).once

    assert_raises(Research::Sentiment::AllModelsFailed) do
      Research::Sentiment::Classifier.classify(@run)
    end
  end

  test "escada de modelos falha totalmente e levanta AllModelsFailed mesmo com SENTIMENT_ALLOW_PAID=true" do
    ENV["SENTIMENT_ALLOW_PAID"] = "true"
    RubyLLM.stubs(:chat).raises(StandardError.new("LLM offline"))

    DiscordApiClient.stubs(:get_bot_guilds).returns([{ "id" => "guild_test" }])
    DiscordApiClient.stubs(:create_text_channel).returns({ "id" => "admin_channel_test" })
    DiscordApiClient.expects(:send_message).once

    assert_raises(Research::Sentiment::AllModelsFailed) do
      Research::Sentiment::Classifier.classify(@run)
    end
  ensure
    ENV.delete("SENTIMENT_ALLOW_PAID")
  end

  test "falha do modelo primário promove para secundário com snapshot_pinned false" do
    # 200 frases = 2 lotes
    100.times do |i|
      @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "batch2_ext_#{i}",
        text: "Frase do lote dois #{i} suficiente",
        collected_at: Time.current
      )
    end

    valid_json = {
      predictions: [
        { id: 0, sentiment: "positive" }
      ]
    }.to_json

    # Modelo primário funciona no lote 1 e falha no lote 2; secundário assume lote 2
    primary_call_count = 0
    primary_chat = FakeChat.new(lambda { |_p|
      primary_call_count += 1
      raise StandardError, "Lote 2 falhou no primario" if primary_call_count > 1
      valid_json
    })

    secondary_chat = FakeChat.new(valid_json)

    RubyLLM.stubs(:chat).with(model: Research::Sentiment::Classifier::PRIMARY_MODEL).returns(primary_chat)
    RubyLLM.stubs(:chat).with(model: Research::Sentiment::Classifier::SECONDARY_MODEL).returns(secondary_chat)

    Research::Sentiment::Classifier.classify(@run)
    @run.reload

    assert_equal false, @run.snapshot_pinned
    assert_includes @run.model_id, Research::Sentiment::Classifier::PRIMARY_MODEL
    assert_includes @run.model_id, Research::Sentiment::Classifier::SECONDARY_MODEL

    # MessageBuilder exibe modelos distintos
    data = { collected_count: 103, rejected_count: 0, period_balance: { balance: 1.0 } }
    msg = Sentiment::MessageBuilder.build(@run, data)
    assert_includes msg, "modelos usados: gemma, nemotron"
  end

  test "valida estritamente IDs e ignora ausentes, duplicados ou fora da faixa sem inferir indice 0" do
    # id ausente, id duplicado (0), id fora da faixa (999)
    malformed_json = {
      predictions: [
        { sentiment: "positive" }, # id ausente -> NAO deve rotular frase 0
        { id: 0, sentiment: "negative" }, # id 0 valido -> rotula frase 0 como negative
        { id: 0, sentiment: "positive" }, # id 0 duplicado -> ignorado
        { id: 999, sentiment: "neutral" }, # fora da faixa -> ignorado
        { id: 1, sentiment: "positive" }  # id 1 valido -> rotula frase 1
      ]
    }.to_json

    fake_chat = FakeChat.new(malformed_json)
    RubyLLM.stubs(:chat).returns(fake_chat)

    Research::Sentiment::Classifier.classify(@run)
    @run.reload

    assert_equal 2, @run.classified_count
    assert_equal 1, @run.unparsed_count

    label_0 = SentimentLabel.find_by(phrase_id: @run.sentiment_phrases.first.id)
    assert_equal "negative", label_0.label # deve ser negative (do id 0), NUNCA positive (do id ausente)
  end

  test "cota diária excedida na tabela SentimentDailyQuota dispara QuotaExceededError e persiste contador" do
    quota = SentimentDailyQuota.create!(day: Date.current, count: 150)

    DiscordApiClient.stubs(:get_bot_guilds).returns([{ "id" => "guild_test" }])
    DiscordApiClient.stubs(:create_text_channel).returns({ "id" => "admin_channel_test" })
    DiscordApiClient.expects(:send_message).once

    assert_raises(Research::Sentiment::QuotaExceededError) do
      Research::Sentiment::Classifier.classify(@run)
    end

    assert_equal 150, quota.reload.count
  end

  test "controle de cota diária é atômico e seguro sob concorrência simultânea de 8 threads" do
    original_limit = ENV["SENTIMENT_DAILY_LIMIT"]
    ENV["SENTIMENT_DAILY_LIMIT"] = "5"

    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    begin
    n_threads = 8
    ready = Queue.new
    release = Queue.new
    mutex = Mutex.new
    successes = 0
    overflows = 0
    unexpected_exceptions = []

    threads = Array.new(n_threads) do
      Thread.new do
        ready.push(:ready) # Sinaliza que a thread está pronta na barreira
        release.pop       # Aguarda o sinal de liberação para disparo simultâneo
        ActiveRecord::Base.connection_pool.with_connection do
          # WAL + busy_timeout faz escritas concorrentes esperarem em vez de falhar com locked
          ActiveRecord::Base.connection.execute("PRAGMA busy_timeout = 10000")
          Research::Sentiment::Classifier.check_and_track_quota!
          mutex.synchronize { successes += 1 }
        rescue Research::Sentiment::QuotaExceededError
          mutex.synchronize { overflows += 1 }
        rescue StandardError => e
          mutex.synchronize { unexpected_exceptions << e }
        end
      end
    end

    # Espera todas as 8 threads estarem prontas antes de liberar o disparo simultâneo
    n_threads.times { ready.pop }
    # Libera todas as threads simultaneamente
    n_threads.times { release.push(:go) }
    threads.each(&:join)

      assert_empty unexpected_exceptions, "Nenhuma exceção inesperada (RecordNotUnique/BusyException) deve ocorrer: #{unexpected_exceptions.map(&:inspect)}"
      assert_equal 5, successes, "Exatamente 5 chamadas devem ter sucesso"
      assert_equal 3, overflows, "Exatamente 3 chamadas devem exceder a cota com QuotaExceededError"

      quota_record = SentimentDailyQuota.find_by(day: Date.current)
      assert_not_nil quota_record, "Registro de cota diária deve existir para a data de hoje"
      assert_equal 5, quota_record.count, "Contador final da cota deve ser exatamente 5"
    ensure
      if original_limit.nil?
        ENV.delete("SENTIMENT_DAILY_LIMIT")
      else
        ENV["SENTIMENT_DAILY_LIMIT"] = original_limit
      end
    end
  end
end

