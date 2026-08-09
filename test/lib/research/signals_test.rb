# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/research/signals"

class ResearchSignalsTest < ActiveSupport::TestCase
  test "log1p lida com nil, zero e negativos" do
    assert_equal 0.0, Research::Signals.log1p(nil)
    assert_equal 0.0, Research::Signals.log1p(0)
    assert_equal 0.0, Research::Signals.log1p(-10)
    assert Research::Signals.log1p(10) > 2.0
  end

  test "engagement_raw calcula pesos para reddit, youtube e hackernews" do
    eng_reddit = { "score" => 100, "num_comments" => 20 }
    raw_reddit = Research::Signals.engagement_raw("reddit", eng_reddit)
    assert raw_reddit > 0

    eng_yt = { "views" => 1000, "likes" => 100 }
    raw_yt = Research::Signals.engagement_raw("youtube", eng_yt)
    assert raw_yt > 0

    eng_hn = { "points" => 50, "comments" => 10 }
    raw_hn = Research::Signals.engagement_raw("hackernews", eng_hn)
    assert raw_hn > 0
  end

  test "engagement_raw devolve nil se nao houver campos de engajamento" do
    assert_nil Research::Signals.engagement_raw("reddit", {})
    assert_nil Research::Signals.engagement_raw("youtube", nil)
  end

  test "freshness calcula decaimento linear ate 30 dias" do
    agora = Time.now.utc
    assert_in_delta 1.0, Research::Signals.freshness(agora, reference: agora), 0.01
    assert_in_delta 0.5, Research::Signals.freshness(agora - (15 * 86400), reference: agora), 0.05
    assert_equal 0.0, Research::Signals.freshness(agora - (31 * 86400), reference: agora)
    # Data ausente é NEUTRO (0.5), não frescor máximo — item sem data não pode
    # superar item datado de hoje (achado de revisão).
    assert_equal 0.5, Research::Signals.freshness(nil)
    # Data INVÁLIDA também é neutra (parsing falhou = não sabemos a idade).
    assert_equal 0.5, Research::Signals.freshness("data-que-nao-existe-9999", reference: agora)
  end

  test "retweets do canal X é aceito como alias de reposts" do
    eng_x = { "retweets" => 1_000_000 }
    raw = Research::Signals.engagement_raw("x", eng_x)

    refute_nil raw, "retweets deve alimentar o campo reposts via FIELD_ALIASES"
    assert raw > 0
  end

  test "source_quality usa tabela com fallback 0.6" do
    assert_equal 0.85, Research::Signals.source_quality("youtube")
    assert_equal 0.6, Research::Signals.source_quality("reddit")
    assert_equal 0.6, Research::Signals.source_quality("desconhecida")
  end
end
