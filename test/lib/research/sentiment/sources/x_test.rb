# frozen_string_literal: true

require "test_helper"

class SentimentSourcesXTest < ActiveSupport::TestCase
  test "fetch coleta posts do X para query de busca" do
    raw_posts = [
      {
        "url" => "https://x.com/user1/status/123456789",
        "text" => "Tweet sobre cleitin bot extremamente relevante",
        "author" => "user1",
        "created_at" => "2026-08-10T12:00:00Z"
      }
    ]

    Fetcher::Channels::X.expects(:search).with(query: "cleitin", limit: 10).returns(raw_posts)

    items = Research::Sentiment::Sources::X.fetch(query: "cleitin", limit: 10)

    assert_equal 1, items.size
    assert_equal "x", items.first[:source]
    assert_equal "123456789", items.first[:external_id]
    assert_equal "user1", items.first[:author]
    assert_equal "Tweet sobre cleitin bot extremamente relevante", items.first[:text]
    assert_not_nil items.first[:posted_at]
  end

  test "fetch com @usuario utiliza timeline do X" do
    raw_posts = [
      {
        "url" => "https://x.com/cleitin/status/987654321",
        "text" => "Post oficial da conta do cleitin bot",
        "screen_name" => "cleitin",
        "created_at" => "2026-08-10T14:00:00Z"
      }
    ]

    Fetcher::Channels::X.expects(:timeline).with(user: "cleitin", limit: 5).returns(raw_posts)

    items = Research::Sentiment::Sources::X.fetch(query: "@cleitin", limit: 5)

    assert_equal 1, items.size
    assert_equal "x", items.first[:source]
    assert_equal "cleitin", items.first[:author]
  end

  test "não achata exceção RateLimited do canal X em lista vazia e propaga o erro" do
    Fetcher::Channels::X.expects(:search).raises(Fetcher::Channels::X::RateLimited.new("[search]"))

    assert_raises(Fetcher::Channels::X::RateLimited) do
      Research::Sentiment::Sources::X.fetch(query: "cleitin", limit: 10)
    end
  end

  test "não achata erro genérico do canal X em lista vazia e propaga o erro" do
    Fetcher::Channels::X.expects(:search).raises(Fetcher::Channels::Error.new("503 Service Unavailable"))

    assert_raises(Fetcher::Channels::Error) do
      Research::Sentiment::Sources::X.fetch(query: "cleitin", limit: 10)
    end
  end
end
