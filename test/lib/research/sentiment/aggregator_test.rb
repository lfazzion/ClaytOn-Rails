# frozen_string_literal: true

require "test_helper"

class SentimentAggregatorTest < ActiveSupport::TestCase
  setup do
    @target = SentimentTarget.create!(name: "Cleitin Aggregator", query: "cleitin", bucket: "week")
    @run = @target.sentiment_runs.create!(
      status: "classified",
      frozen_spec: { "name" => "Cleitin Aggregator", "bucket" => "week", "sources" => "reddit,x" }
    )
  end

  test "bucket com n=29 vira insuficiente e não entra no ΔS" do
    # Semana 1 (n=30): 20 pos, 10 neg -> balance +0.33
    w1_date = Time.utc(2026, 8, 3, 12, 0, 0)
    30.times do |i|
      p = @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "w1_#{i}",
        text: "Frase w1 #{i}",
        posted_at: w1_date,
        collected_at: Time.current
      )
      p.sentiment_labels.create!(run_id: @run.id, pass: 1, attempt: 1, label: i < 20 ? "positive" : "negative")
    end

    # Semana 2 (n=29 - insuficiente): 20 pos, 9 neg
    w2_date = Time.utc(2026, 8, 10, 12, 0, 0)
    29.times do |i|
      p = @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "w2_#{i}",
        text: "Frase w2 #{i}",
        posted_at: w2_date,
        collected_at: Time.current
      )
      p.sentiment_labels.create!(run_id: @run.id, pass: 1, attempt: 1, label: "positive")
    end

    data = Research::Sentiment::Aggregator.aggregate(@run)

    assert_equal 1, data[:curve].size
    assert_includes data[:insufficient_buckets], w2_date.to_date.beginning_of_week.iso8601
    assert_nil data[:max_delta_s]
  end

  test "comentário sem data fica posted_at nil e entra no saldo do período, não na curva" do
    # Frase sem data
    p_nodate = @run.sentiment_phrases.create!(
      source: "reddit",
      external_id: "nodate_1",
      text: "Frase sem data",
      posted_at: nil,
      collected_at: Time.current
    )
    p_nodate.sentiment_labels.create!(run_id: @run.id, pass: 1, attempt: 1, label: "positive")

    data = Research::Sentiment::Aggregator.aggregate(@run)

    assert_equal 1, data[:sem_data_count]
    assert_equal 0, data[:curve].size
    assert_equal 1, data[:period_balance][:total]
    assert_equal 1.0, data[:period_balance][:balance]
  end

  test "calcula ΔS apenas entre buckets válidos consecutivos" do
    w1_date = Time.utc(2026, 8, 3, 12, 0, 0)
    30.times do |i|
      p = @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "w1_#{i}",
        text: "Frase w1 #{i}",
        posted_at: w1_date,
        collected_at: Time.current
      )
      p.sentiment_labels.create!(run_id: @run.id, pass: 1, attempt: 1, label: i < 20 ? "positive" : "negative")
    end

    w2_date = Time.utc(2026, 8, 10, 12, 0, 0)
    30.times do |i|
      p = @run.sentiment_phrases.create!(
        source: "reddit",
        external_id: "w2_#{i}",
        text: "Frase w2 #{i}",
        posted_at: w2_date,
        collected_at: Time.current
      )
      p.sentiment_labels.create!(run_id: @run.id, pass: 1, attempt: 1, label: i < 5 ? "positive" : "negative")
    end

    data = Research::Sentiment::Aggregator.aggregate(@run)

    assert_equal 2, data[:curve].size
    assert_not_nil data[:max_delta_s]
    assert_in_delta(-1.0, data[:max_delta_s][:delta], 0.1)
  end
end
