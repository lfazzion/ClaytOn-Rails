# frozen_string_literal: true

require "test_helper"

class SentimentAnalysisJobTest < ActiveJob::TestCase
  setup do
    @target = SentimentTarget.create!(name: "Cleitin Job Test", query: "cleitin")
  end

  test "perform executa o pipeline completo de análise de sentimento e monta frozen_spec com janelas" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 10,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste de sentimento").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem de teste de sentimento").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_not_nil run.finished_at
    assert_not_nil run.frozen_spec["window_start"]
    assert_not_nil run.frozen_spec["window_end"]
  end

  test "canal digest nulo define status delivery_failed e erro no run sem perder o relatório silenciosamente" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 10,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns(nil)

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "delivery_failed", run.status
    assert_equal "canal digest indisponível", run.error
    assert_not_nil run.finished_at
  end

  test "job integrado roda com Collector real e fontes stubadas provando amostragem com frozen_spec completo" do
    now = Time.current.utc
    x_items = [
      { source: "x", external_id: "job_x1", permalink: "p1", author: "user1", text: "Post integrado sobre cleitin bot", posted_at: now - 1.hour }
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(x_items)

    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 1,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem integrada").once
    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem integrada").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_equal 1, run.sentiment_phrases.count
    assert_equal "job_x1", run.sentiment_phrases.first.external_id
    assert_not_nil run.frozen_spec["window_start"]
    assert_not_nil run.frozen_spec["window_end"]
  end

  test "AllModelsFailed no classifier faz job falhar com status failed mesmo se SENTIMENT_ALLOW_PAID=true" do
    ENV["SENTIMENT_ALLOW_PAID"] = "true"
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).raises(Research::Sentiment::AllModelsFailed.new("LLM offline"))

    job = SentimentAnalysisJob.new
    assert_raises(Research::Sentiment::AllModelsFailed) do
      job.perform(@target.id)
    end

    run = @target.sentiment_runs.last
    assert_equal "failed", run.status
    assert_includes run.error, "LLM offline"
  ensure
    ENV.delete("SENTIMENT_ALLOW_PAID")
  end

  test "quando todas as fontes falham na coleta, não publica relatório de zeros no canal digest e marca status de dados insuficientes" do
    Research::Sentiment::Sources::Reddit.stubs(:fetch).raises(Fetcher::Channels::Error.new("Reddit indisponível"))
    Research::Sentiment::Sources::X.stubs(:fetch).raises(Fetcher::Channels::Error.new("X indisponível"))

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_includes %w[insufficient_data empty failed], run.status
    assert_not_equal "completed", run.status
  end

  test "quando a coleta é legitimamente vazia (zero frases encontradas), não envia relatório de zeros no digest" do
    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns([])

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_includes %w[insufficient_data empty completed_empty], run.status
    assert_not_equal "completed", run.status
  end

  test "quando uma fonte falha e outra coleta com sucesso, completa o run com dados da fonte funcional" do
    now = Time.current.utc
    x_items = [
      { source: "x", external_id: "job_x_partial", permalink: "p1", author: "user1", text: "Post válido no X sobre cleitin bot", posted_at: now - 1.hour }
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).raises(Fetcher::Channels::Error.new("Reddit offline"))
    Research::Sentiment::Sources::X.stubs(:fetch).returns(x_items)

    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 1,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem com dados parciais").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem com dados parciais").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_equal 1, run.sentiment_phrases.count
  end

  # --- ACHADO N1: Recuperação de canal obsoleto não integrada ---

  test "quando canal em cache está obsoleto (404 no envio), recupera canal via recover_digest_channel e conclui envio no canal recuperado" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem recuperada").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("stale_channel_123")
    DiscordApiClient.expects(:send_message).with("stale_channel_123", "Mensagem recuperada")
      .raises(RuntimeError.new("Discord API error: 404 Not Found"))
    SentimentAnalysisJob.any_instance.expects(:recover_digest_channel).with("stale_channel_123")
      .returns("recovered_channel_456")
    DiscordApiClient.expects(:send_message).with("recovered_channel_456", "Mensagem recuperada").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_not_nil run.finished_at
  end

  test "quando canal digest está obsoleto e recover_digest_channel retorna nil, marca status delivery_failed" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem com canal obsoleto").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("stale_channel_123")
    DiscordApiClient.expects(:send_message).with("stale_channel_123", "Mensagem com canal obsoleto")
      .raises(RuntimeError.new("Discord API error: 404 Not Found"))
    SentimentAnalysisJob.any_instance.expects(:recover_digest_channel).with("stale_channel_123").returns(nil)

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "delivery_failed", run.status
    assert_includes run.error, "canal digest indisponível"
    assert_not_nil run.finished_at
  end

  # --- ACHADO N2: Entrega parcial sem idempotência ---

  test "fluxo normal de entrega marca o run como entregue (delivered_at preenchido)" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste de sentimento").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem de teste de sentimento").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert run.respond_to?(:delivered_at) && run.delivered_at.present?, "run deve possuir e preencher delivered_at após entrega com sucesso"
  end

  test "re-execução de run já marcado como entregue não re-envia mensagens no Discord (idempotência de entrega)" do
    run = @target.sentiment_runs.create!(
      status: "completed",
      started_at: Time.current,
      frozen_spec: { "target_id" => @target.id }
    )
    if run.respond_to?(:delivered_at=)
      run.update!(delivered_at: Time.current)
    else
      run.define_singleton_method(:delivered_at) { Time.current }
    end

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    result_run = job.perform(@target.id, run.id)

    assert_equal "completed", result_run.status
    assert_not_nil result_run.delivered_at
  end
end

