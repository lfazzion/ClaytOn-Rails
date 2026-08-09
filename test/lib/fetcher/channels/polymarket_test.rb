# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/polymarket"

class Fetcher::Channels::PolymarketTest < ActiveSupport::TestCase
  PUBLIC_IP = "93.184.216.34"

  setup do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns([PUBLIC_IP])
  end

  test "1. URL valida de evento devolve hash com markdown montado e metadata source polymarket" do
    payload = [
      {
        "id" => "evt123",
        "title" => "US Presidential Election 2028",
        "description" => "Markets for the 2028 US Presidential Election.",
        "slug" => "us-presidential-election-2028",
        "volume" => 5000000.0,
        "liquidity" => 1500000.0,
        "markets" => [
          {
            "question" => "Who will win the election?",
            "outcomes" => ["Candidate A", "Candidate B"],
            "outcomePrices" => ["0.55", "0.45"],
            "volume" => 2500000.0
          }
        ]
      }
    ]

    stub_request(:get, "https://gamma-api.polymarket.com/events?slug=us-presidential-election-2028")
      .to_return(status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })

    result = Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/event/us-presidential-election-2028")

    assert_not_nil result
    assert_equal "https://polymarket.com/event/us-presidential-election-2028", result[:url]
    assert_equal "US Presidential Election 2028", result[:title]
    assert_includes result[:content], "# US Presidential Election 2028"
    assert_includes result[:content], "Candidate A: 55.0%"
    assert_includes result[:content], "Candidate B: 45.0%"
    assert_equal "polymarket", result[:metadata]["source"]
    assert_equal "event", result[:metadata]["kind"]
    assert_equal "us-presidential-election-2028", result[:metadata]["slug"]
    assert_nil result[:error]
  end

  test "2. URL de outro dominio devolve nil" do
    assert_nil Fetcher::Channels::Polymarket.call(url: "https://predictit.org/event/us-2028")
  end

  test "3. URL do dominio mas de path nao suportado devolve nil" do
    assert_nil Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/")
    assert_nil Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/activity")
  end

  test "4. API responde erro (500 ou 403) levanta excecao nomeada herdando de Channels::Error" do
    stub_request(:get, "https://gamma-api.polymarket.com/events?slug=us-2028")
      .to_return(status: 500, body: "Internal Server Error")

    err = assert_raises(Fetcher::Channels::Polymarket::ApiError) do
      Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/event/us-2028")
    end

    assert_kind_of Fetcher::Channels::Error, err
    assert_includes err.message, "500"
  end

  test "5. API devolve lista vazia levanta EventNotFound (não nil silencioso)" do
    stub_request(:get, "https://gamma-api.polymarket.com/events?slug=not-found")
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

    err = assert_raises(Fetcher::Channels::Polymarket::EventNotFound) do
      Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/event/not-found")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "6. JSON inválido levanta InvalidResponse (não cai em nil)" do
    stub_request(:get, "https://gamma-api.polymarket.com/events?slug=quebrado")
      .to_return(status: 200, body: "isto nao e json", headers: { "Content-Type" => "application/json" })

    err = assert_raises(Fetcher::Channels::Polymarket::InvalidResponse) do
      Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/event/quebrado")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "7. path /market/ devolve nil (Gamma events só responde slug de evento)" do
    assert_nil Fetcher::Channels::Polymarket.call(url: "https://polymarket.com/market/us-2028-biden")
  end
end
