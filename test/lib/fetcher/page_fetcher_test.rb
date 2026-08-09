# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/page_fetcher"

class Fetcher::PageFetcherTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8"])
    Fetcher::PageFetcher.reset_browser!
  end

  def raw_result(overrides = {})
    {
      title: "T",
      final_url: "https://example.com/",
      readability_text: "Sample readability content about the topic. " * 20,
      body_text: "Sample readability content about the topic. " * 20,
      html: "<html><body><p>test</p></body></html>"
    }.merge(overrides)
  end

  test "fetch bem-sucedido retorna payload formatado" do
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(raw_result)
    result = Fetcher::PageFetcher.call("https://example.com/")
    assert_kind_of String, result[:title]
    assert_equal "https://example.com/", result[:url]
    assert_operator result[:char_count], :>, 0
    assert_in_delta 0, result[:cache_age_seconds], 1
    assert_kind_of Time, result[:fetched_at]
  end

  test "segunda chamada bate no cache e tem cache_age > 0" do
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(raw_result).once
    Fetcher::PageFetcher.call("https://example.com/cached")
    travel 30.seconds do
      second = Fetcher::PageFetcher.call("https://example.com/cached")
      assert_operator second[:cache_age_seconds], :>=, 29
    end
  end

  test "URL com scheme inválido levanta SsrfGuard::Blocked" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::PageFetcher.call("ftp://example.com/")
    end
  end

  test "cooldown ativo bloqueia fetch" do
    Fetcher::BotDetection.cooldown!("example.com", reason: "403")
    Fetcher::PageFetcher.any_instance.expects(:fetch_via_ferrum).never
    assert_raises(Fetcher::PageFetcher::HostInCooldown) do
      Fetcher::PageFetcher.call("https://example.com/")
    end
  end

  test "rate limit: 6a chamada no mesmo host levanta RateLimited" do
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(raw_result)
    5.times { |i| Fetcher::PageFetcher.call("https://example.com/path#{i}") }
    assert_raises(Fetcher::PageFetcher::RateLimited) do
      Fetcher::PageFetcher.call("https://example.com/path-overflow")
    end
  end

  test "hard domain delega para NodriverRunner e não invoca Ferrum" do
    Fetcher::PageFetcher.stubs(:hard_domains).returns(["blocked-site.example"])
    Fetcher::PageFetcher.any_instance.expects(:fetch_via_ferrum).never
    ScrapingServices::NodriverRunner.expects(:fetch_page).with("https://blocked-site.example/").returns(
      { title: "T", url: "https://blocked-site.example/", content: "python content here", html_bytes: 500 }
    )
    result = Fetcher::PageFetcher.call("https://blocked-site.example/")
    assert_includes result[:content], "python"
  end

  test "bot block detectado pós-fetch grava cooldown e levanta BotBlocked" do
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(
      raw_result(title: "Just a moment...", body_text: "cf-turnstile")
    )
    assert_raises(Fetcher::PageFetcher::BotBlocked) do
      Fetcher::PageFetcher.call("https://example.com/blocked")
    end
    assert Fetcher::BotDetection.cooldown?("example.com")
  end

  test "live host usa TTL de 60s no cache" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8"])
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(raw_result)
    Fetcher::PageFetcher.call("https://www.coingecko.com/pt/moedas/bitcoin")
    key = Rails.cache.instance_variable_get(:@data) # memory store in test
    # validação indireta: não podemos ver TTL direto, mas após 70s o cache deve expirar
    travel 70.seconds do
      Fetcher::PageFetcher.any_instance.expects(:fetch_via_ferrum).returns(raw_result).once
      Fetcher::PageFetcher.call("https://www.coingecko.com/pt/moedas/bitcoin")
    end
  end

  test "URL normalizada na cache key: utm_* e fragment são removidos" do
    Fetcher::PageFetcher.any_instance.stubs(:fetch_via_ferrum).returns(raw_result).once
    Fetcher::PageFetcher.call("https://example.com/artigo?utm_source=x&id=5#frag")
    # 2a URL com utm diferente deve bater cache
    result = Fetcher::PageFetcher.call("https://example.com/artigo?id=5&utm_campaign=y")
    assert_operator result[:cache_age_seconds], :>=, 0
  end
end
