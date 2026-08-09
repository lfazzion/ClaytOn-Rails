# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/ttl_policy"

class Fetcher::TtlPolicyTest < ActiveSupport::TestCase
  test "live host retorna 60 segundos" do
    assert_equal 60, Fetcher::TtlPolicy.for(host: "www.coingecko.com", path: "/pt/moedas/bitcoin")
  end

  test "live host casa por sufixo (subdomínio)" do
    assert_equal 60, Fetcher::TtlPolicy.for(host: "api.coinmarketcap.com", path: "/v1/ticker")
  end

  test "docs host retorna 7 dias" do
    assert_equal 7.days.to_i, Fetcher::TtlPolicy.for(host: "github.com", path: "/rails/rails")
  end

  test "docs host developer.mozilla.org retorna 7 dias" do
    assert_equal 7.days.to_i, Fetcher::TtlPolicy.for(host: "developer.mozilla.org", path: "/en-US/docs/Web")
  end

  test "readthedocs subdomain retorna 7 dias" do
    assert_equal 7.days.to_i, Fetcher::TtlPolicy.for(host: "ferrum.readthedocs.io", path: "/latest")
  end

  test "URL de news pelo path retorna 1 hora" do
    assert_equal 1.hour.to_i, Fetcher::TtlPolicy.for(host: "example.com", path: "/news/breaking")
  end

  test "URL com path tipo data /YYYY/MM/ retorna 1 hora" do
    assert_equal 1.hour.to_i, Fetcher::TtlPolicy.for(host: "example.com", path: "/2026/04/some-article")
  end

  test "default retorna 15 minutos para URLs desconhecidas" do
    assert_equal 15.minutes.to_i, Fetcher::TtlPolicy.for(host: "example.com", path: "/about")
  end

  test "live tem prioridade sobre docs (ambos nunca se sobrepõem mas testa ordem)" do
    # Se um hipotético host aparecesse nas duas listas, live vence
    assert_equal 60, Fetcher::TtlPolicy.for(host: "www.coingecko.com", path: "/news/article")
  end
end
