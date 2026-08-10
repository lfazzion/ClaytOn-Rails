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
end
