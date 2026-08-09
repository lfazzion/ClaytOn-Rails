# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/bot_detection"

class Fetcher::BotDetectionTest < ActiveSupport::TestCase
  FakePage = Struct.new(:status, :title, :body, :current_url, keyword_init: true) do
    def initialize(status: 200, title: "Example", body: "<html><body>ok</body></html>", current_url: "https://example.com/")
      super
    end
  end

  setup do
    Rails.cache.clear
  end

  test "status 403 é detectado como block" do
    page = FakePage.new(status: 403)
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "status 429 é detectado como block" do
    page = FakePage.new(status: 429)
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "título 'Just a moment...' é detectado (Cloudflare)" do
    page = FakePage.new(status: 200, title: "Just a moment...")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "título 'Attention Required' é detectado" do
    page = FakePage.new(status: 200, title: "Attention Required! | Cloudflare")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "título 'Access denied' é detectado" do
    page = FakePage.new(status: 200, title: "Access denied")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "body com cf-turnstile é detectado" do
    page = FakePage.new(status: 200, body: "<div class='cf-turnstile'></div>")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "body com cf-chl-bypass é detectado" do
    page = FakePage.new(status: 200, body: "<script>window.cf-chl-bypass</script>")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "URL com /cdn-cgi/challenge-platform/ é detectada" do
    page = FakePage.new(current_url: "https://example.com/cdn-cgi/challenge-platform/h/g/orchestrate/jsch/v1")
    assert Fetcher::BotDetection.blocked?(page)
  end

  test "página normal 200 não é detectada" do
    page = FakePage.new
    assert_not Fetcher::BotDetection.blocked?(page)
  end

  test "cooldown! grava no cache com TTL entre 6h e 12h" do
    Fetcher::BotDetection.cooldown!("example.com", reason: "403")

    entry = Fetcher::BotDetection.cooldown_for("example.com")
    assert_not_nil entry
    assert_equal "403", entry[:reason]
    assert_kind_of Time, entry[:blocked_at]
    assert_kind_of Time, entry[:expires_at]
    remaining = entry[:expires_at] - Time.current
    assert_operator remaining, :>=, 6.hours.to_i - 60
    assert_operator remaining, :<=, 12.hours.to_i + 60
  end

  test "cooldown_for retorna nil para host sem cooldown" do
    assert_nil Fetcher::BotDetection.cooldown_for("limpo.example.com")
  end

  test "clear! remove cooldown do cache" do
    Fetcher::BotDetection.cooldown!("example.com", reason: "429")
    assert_not_nil Fetcher::BotDetection.cooldown_for("example.com")

    Fetcher::BotDetection.clear!("example.com")
    assert_nil Fetcher::BotDetection.cooldown_for("example.com")
  end

  test "cooldown?/cooldown_for normaliza host (downcase)" do
    Fetcher::BotDetection.cooldown!("EXAMPLE.com", reason: "403")
    assert_not_nil Fetcher::BotDetection.cooldown_for("example.com")
    assert_not_nil Fetcher::BotDetection.cooldown_for("Example.COM")
  end
end
