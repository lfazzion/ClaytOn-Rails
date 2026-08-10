# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/hackernews"

class Fetcher::Channels::HackernewsTest < ActiveSupport::TestCase
  PUBLIC_IP = "93.184.216.34"

  setup do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns([PUBLIC_IP])
  end

  test "1. URL valida do canal devolve hash com markdown montado e metadata source hackernews" do
    payload = {
      "id" => 123456,
      "title" => "Ruby 4.0 Released",
      "author" => "matz",
      "points" => 500,
      "url" => "https://ruby-lang.org/en/news/4-0",
      "text" => "<p>Discussing the new features in Ruby 4.0.</p>",
      "children" => [
        { "author" => "dhh", "points" => 50, "text" => "<p>Great release!</p>" }
      ]
    }

    stub_request(:get, "https://hn.algolia.com/api/v1/items/123456")
      .to_return(status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })

    result = Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/item?id=123456")

    assert_not_nil result
    assert_equal "https://news.ycombinator.com/item?id=123456", result[:url]
    assert_equal "Ruby 4.0 Released", result[:title]
    assert_includes result[:content], "# Ruby 4.0 Released"
    assert_includes result[:content], "matz"
    assert_includes result[:content], "500 pontos"
    assert_includes result[:content], "Great release!"
    assert_equal "hackernews", result[:metadata]["source"]
    assert_equal "story", result[:metadata]["kind"]
    assert_equal "123456", result[:metadata]["item_id"]
    assert_nil result[:error]
  end

  test "2. URL de outro dominio devolve nil" do
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://example.com/item?id=123456")
  end

  test "3. URL do dominio mas de path nao suportado devolve nil" do
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/newest")
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/user?id=pg")
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/")
  end

  test "4. API responde erro (500 ou 403) levanta excecao nomeada herdando de Channels::Error" do
    stub_request(:get, "https://hn.algolia.com/api/v1/items/123456")
      .to_return(status: 500, body: "Server Error")

    err = assert_raises(Fetcher::Channels::Hackernews::ApiError) do
      Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/item?id=123456")
    end

    assert_kind_of Fetcher::Channels::Error, err
    assert_includes err.message, "500"
  end

  test "5. path não suportado (sem id) devolve nil" do
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/front")
    assert_nil Fetcher::Channels::Hackernews.call(url: "https://news.ycombinator.com/item?id=abc")
  end

  test "6. search com query vazia devolve []" do
    assert_equal [], Fetcher::Channels::Hackernews.search(query: "   ")
  end

  test "7. search retorna itens formatados com contrato congelado e external_url separado" do
    created_epoch = 1700000000
    iso_date = Time.at(created_epoch).utc.iso8601

    payload = {
      "hits" => [
        {
          "objectID" => "7890",
          "title" => "Rails 8.1 Released",
          "url" => "https://rubyonrails.org/news/8-1",
          "points" => 350,
          "num_comments" => 42,
          "author" => "dhh",
          "created_at_i" => created_epoch
        }
      ]
    }

    stub_request(:get, %r{\Ahttps://hn\.algolia\.com/api/v1/search\?})
      .to_return(status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })

    results = Fetcher::Channels::Hackernews.search(query: "rails")

    assert_equal 1, results.size
    item = results.first

    assert_equal "https://news.ycombinator.com/item?id=7890", item["url"]
    assert_equal "https://rubyonrails.org/news/8-1", item["external_url"]
    assert_equal "Rails 8.1 Released", item["title"]
    assert_equal "hackernews", item["source"]
    assert_equal 350, item["points"]
    assert_equal 42, item["comments"]
    refute item.key?("num_comments"), "Nao deve emitir num_comments; a chave deve ser comments"
    assert_equal "dhh", item["author"]
    assert_equal iso_date, item["created_at"]
  end

  test "8. search quando API responde 4xx levanta ApiError" do
    stub_request(:get, %r{\Ahttps://hn\.algolia\.com/api/v1/search\?})
      .to_return(status: 400, body: "Bad Request")

    err = assert_raises(Fetcher::Channels::Hackernews::ApiError) do
      Fetcher::Channels::Hackernews.search(query: "ruby")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "9. search quando rate limit local e excedido levanta RateLimited" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).with("hn.algolia.com", max: Fetcher::Channels::Hackernews::MAX_PER_WINDOW).returns(true)

    err = assert_raises(Fetcher::Channels::Hackernews::RateLimited) do
      Fetcher::Channels::Hackernews.search(query: "ruby")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end
end
