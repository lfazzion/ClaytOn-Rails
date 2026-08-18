require "test_helper"
require "webmock"

class FerrumHostHeaderBypassTest < ActiveSupport::TestCase
  setup do
    @chrome_host = "chrome"
    @chrome_port = 9222
    ENV["CHROME_HOST"] = @chrome_host
    ENV["CHROME_PORT"] = @chrome_port.to_s
  end

  teardown do
    ENV.delete("CHROME_HOST")
    ENV.delete("CHROME_PORT")
  end

  test "ferrum initializer should exist" do
    assert File.exist?(Rails.root.join("config", "initializers", "ferrum.rb"))
  end

  test "FerumConfig module should be defined" do
    assert defined?(FerumConfig)
  end

  test "FerumConfig should use CHROME_HOST from env" do
    assert_equal @chrome_host, FerumConfig::CHROME_HOST
    assert_equal @chrome_port, FerumConfig::CHROME_PORT
  end

  test "discover_stealth_ws_url should inject Host: localhost header" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://127.0.0.1:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    ws_url = FerumConfig.discover_stealth_ws_url

    assert_includes ws_url, "ws://"
    assert_includes ws_url, "/devtools/browser/"
    assert_includes ws_url, "chrome"
  end

  test "discover_stealth_ws_url should replace localhost with CHROME_HOST" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://localhost:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    ws_url = FerumConfig.discover_stealth_ws_url

    assert_includes ws_url, "ws://chrome"
    assert_not_includes ws_url, "localhost"
  end

  test "discover_stealth_ws_url should raise on non-200 response" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 503)

    assert_raises(RuntimeError) { FerumConfig.discover_stealth_ws_url }
  end

  test "discover_stealth_ws_url should raise when no WS URL in response" do
    mock_response = {}.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    assert_raises(RuntimeError) { FerumConfig.discover_stealth_ws_url }
  end

  test "browser_options should include stealth ws_url and headless" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://127.0.0.1:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    options = FerumConfig.browser_options

    assert options.key?(:ws_url)
    assert_equal true, options[:headless]
    assert options[:timeout] > 0
  end

  test "browser_options fallback should work when Chrome unavailable" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_timeout

    options = FerumConfig.browser_options

    assert_kind_of Hash, options
    assert_equal true, options[:headless]
  end

  test "hierarquia de timeouts respeita invariante permanente da spec" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://127.0.0.1:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    ferrum_timeout = FerumConfig.browser_options[:timeout]
    goto_timeout = Fetcher::PageFetcher::GOTO_TIMEOUT
    overall_timeout = Fetcher::PageFetcher::OVERALL_TIMEOUT
    session_timeout = Fetcher::BrowserSession::OVERALL_TIMEOUT
    channel_timeout = Fetcher::ExtractService::CHANNEL_TIMEOUT
    total_per_url = Fetcher::ExtractService::TOTAL_PER_URL_TIMEOUT

    assert_operator ferrum_timeout, :>, 0
    assert_operator ferrum_timeout, :<, goto_timeout
    assert_operator goto_timeout, :<, overall_timeout
    assert_operator overall_timeout, :<, session_timeout
    assert_operator session_timeout, :<, channel_timeout
    assert_equal channel_timeout, total_per_url
    assert_operator total_per_url, :<, 90
  end
end
