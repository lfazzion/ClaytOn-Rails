# frozen_string_literal: true

require "test_helper"

class SentimentCollectorTest < ActiveSupport::TestCase
  setup do
    @target = SentimentTarget.create!(
      name: "Cleitin Collector",
      query: "cleitin",
      sources: "reddit,x",
      window_days: 30,
      bucket: "week",
      max_phrases: 100
    )
    @run = @target.sentiment_runs.create!(status: "pending", frozen_spec: {})
  end

  test "grava frozen_spec com janelas antes do primeiro fetch quando incompleto" do
    reddit_items = [
      { source: "reddit", external_id: "r1", permalink: "https://reddit.com/r1", author: "u1", text: "Excelente bot de teste!", posted_at: Time.current }
    ]
    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns(reddit_items)
    Research::Sentiment::Sources::X.stubs(:fetch).returns([])

    assert @run.frozen_spec.blank?

    Research::Sentiment::Collector.collect(@run)

    @run.reload
    assert_not @run.frozen_spec.blank?
    assert_equal "Cleitin Collector", @run.frozen_spec["name"]
    assert_equal "cleitin", @run.frozen_spec["query"]
    assert_not_nil @run.frozen_spec["window_start"]
    assert_not_nil @run.frozen_spec["window_end"]

    @target.update!(query: "query_alterada", max_phrases: 10)
    assert_equal "cleitin", @run.frozen_spec["query"]
  end

  test "descarta frases com data fora da janela temporal de amostragem em rejected_count" do
    now = Time.current.utc
    w_start = now - 30.days
    w_end = now
    @run.update!(
      window_start: w_start,
      window_end: w_end,
      frozen_spec: @target.frozen_spec.merge("window_start" => w_start.iso8601, "window_end" => w_end.iso8601)
    )

    items = [
      { source: "x", external_id: "x_antigo", permalink: "p1", author: "a1", text: "Post antigo sobre cleitin bot", posted_at: now - 40.days },
      { source: "x", external_id: "x_futuro", permalink: "p2", author: "a2", text: "Post no futuro sobre cleitin bot", posted_at: now + 5.days },
      { source: "x", external_id: "x_dentro", permalink: "p3", author: "a3", text: "Post valido dentro da janela sobre cleitin", posted_at: now - 10.days }
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(items)

    Research::Sentiment::Collector.collect(@run)
    @run.reload

    assert_equal 1, @run.collected_count
    assert_equal 2, @run.rejected_count
  end

  test "coleta é idempotente e não duplica frases" do
    items = [
      { source: "x", external_id: "x100", permalink: "https://x.com/post100", author: "jack", text: "Post sobre cleitin excelente", posted_at: Time.current }
    ]
    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(items)

    Research::Sentiment::Collector.collect(@run)
    assert_equal 1, @run.sentiment_phrases.count

    Research::Sentiment::Collector.collect(@run)
    assert_equal 1, @run.sentiment_phrases.count
  end

  test "descarta frases com menos de 3 palavras ou mais de 500 caracteres" do
    items = [
      { source: "x", external_id: "x1", permalink: "p1", author: "a1", text: "Curto de+", posted_at: Time.current },
      { source: "x", external_id: "x2", permalink: "p2", author: "a2", text: "A " * 300, posted_at: Time.current },
      { source: "x", external_id: "x3", permalink: "p3", author: "a3", text: "Esta é uma frase válida com mais de três palavras sobre cleitin.", posted_at: Time.current }
    ]
    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(items)

    Research::Sentiment::Collector.collect(@run)
    @run.reload

    assert_equal 1, @run.collected_count
    assert_equal 2, @run.rejected_count
  end

  test "limita coleta por fonte e intercala fontes garantindo execução de ambas" do
    @target.update!(max_phrases: 4, sources: "reddit,x")
    now = Time.current.utc
    w_start = now - 30.days
    w_end = now
    @run.update!(
      window_start: w_start,
      window_end: w_end,
      frozen_spec: @target.frozen_spec.merge("window_start" => w_start.iso8601, "window_end" => w_end.iso8601)
    )

    reddit_items = 10.times.map do |i|
      { source: "reddit", external_id: "r_#{i}", permalink: "p_r_#{i}", author: "user_r", text: "Comentário no reddit numero #{i} sobre cleitin", posted_at: now - 1.day }
    end
    x_items = 10.times.map do |i|
      { source: "x", external_id: "x_#{i}", permalink: "p_x_#{i}", author: "user_x", text: "Tweet no X numero #{i} sobre cleitin bot", posted_at: now - 1.day }
    end

    Research::Sentiment::Sources::Reddit.expects(:fetch).with(query: "cleitin", limit: 2).returns(reddit_items.first(2))
    Research::Sentiment::Sources::X.expects(:fetch).with(query: "cleitin", limit: 2).returns(x_items.first(2))

    Research::Sentiment::Collector.collect(@run)
    @run.reload

    assert_equal 4, @run.collected_count
    sources_in_db = @run.sentiment_phrases.pluck(:source)
    assert_includes sources_in_db, "reddit"
    assert_includes sources_in_db, "x"
  end

  test "valida limites exatos de window_end efetivo no filtro temporal" do
    started_at = Time.parse("2026-08-10 12:00:00 UTC")
    w_start = started_at - 30.days
    effective_w_end = started_at + 1.minute # 12:01:00 UTC
    @run.update!(
      started_at: started_at,
      window_start: w_start,
      window_end: effective_w_end,
      frozen_spec: @target.frozen_spec.merge("window_start" => w_start.iso8601(9), "window_end" => effective_w_end.iso8601(9))
    )

    items = [
      { source: "x", external_id: "x_exact_start", permalink: "p1", author: "a1", text: "Post no inicio do run cleitin bot", posted_at: started_at }, # 12:00:00 -> entra
      { source: "x", external_id: "x_plus_1s", permalink: "p2", author: "a2", text: "Post 1s apos inicio cleitin bot", posted_at: started_at + 1.second }, # 12:00:01 -> entra (<= efetivo)
      { source: "x", external_id: "x_exact_60s", permalink: "p3", author: "a3", text: "Post no limite exato de 60s cleitin", posted_at: started_at + 60.seconds }, # 12:01:00 -> entra (limite exato)
      { source: "x", external_id: "x_over_61s", permalink: "p4", author: "a4", text: "Post em 61s apos inicio cleitin", posted_at: started_at + 61.seconds }  # 12:01:01 -> rejeitado (> efetivo)
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(items)

    Research::Sentiment::Collector.collect(@run)
    @run.reload

    assert_equal 3, @run.collected_count
    assert_equal 1, @run.rejected_count
    collected_ids = @run.sentiment_phrases.pluck(:external_id)
    assert_includes collected_ids, "x_exact_start"
    assert_includes collected_ids, "x_plus_1s"
    assert_includes collected_ids, "x_exact_60s"
    refute_includes collected_ids, "x_over_61s"
  end

  test "coleta com apenas uma fonte define teto por fonte igual a max_phrases sem quebrar o interleave" do
    @target.update!(max_phrases: 5, sources: "reddit")
    now = Time.current.utc
    w_start = now - 30.days
    w_end = now + 1.minute
    @run.update!(
      window_start: w_start,
      window_end: w_end,
      frozen_spec: @target.frozen_spec.merge("window_start" => w_start.iso8601, "window_end" => w_end.iso8601)
    )

    reddit_items = 5.times.map do |i|
      { source: "reddit", external_id: "r_single_#{i}", permalink: "p_#{i}", author: "user", text: "Comentário único reddit #{i} sobre cleitin", posted_at: now - 1.day }
    end

    Research::Sentiment::Sources::Reddit.expects(:fetch).with(query: "cleitin", limit: 5).returns(reddit_items)
    Research::Sentiment::Sources::X.expects(:fetch).never

    Research::Sentiment::Collector.collect(@run)
    @run.reload

    assert_equal 5, @run.collected_count
    assert_equal 5, @run.sentiment_phrases.count
    assert_equal ["reddit"], @run.sentiment_phrases.pluck(:source).uniq
  end
end
