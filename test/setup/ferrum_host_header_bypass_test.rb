require "test_helper"
require "webmock"
require_relative "../support/fake_chrome_dns"

class FerrumHostHeaderBypassTest < ActiveSupport::TestCase
  # IPs de mentira: o nome do serviço resolve para um v6 (que o resolvedor devolve
  # PRIMEIRO) e um v4. O handshake WebSocket tem de sair pelo v4.
  CHROME_V4 = "172.26.0.9"
  CHROME_V6 = "fd00::c"

  setup do
    @chrome_host = "chrome"
    @chrome_port = 9222
    ENV["CHROME_HOST"] = @chrome_host
    ENV["CHROME_PORT"] = @chrome_port.to_s
    FakeChromeDns.install(@chrome_host => [CHROME_V6, CHROME_V4])
  end

  teardown do
    FakeChromeDns.uninstall
    ENV.delete("CHROME_HOST")
    ENV.delete("CHROME_PORT")
  end

  def stub_version(ws_url)
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: { "webSocketDebuggerUrl" => ws_url }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  # Chrome 151 recusa o handshake WS com `Host` = nome de container (500 →
  # Ferrum::DeadBrowserError); 147 e 151 aceitam IP. Ver RELATORIO-CHROME-151.md.
  test "ws_url sai com o IPv4 do servico chrome, nunca com o nome do container" do
    stub_version("ws://localhost/devtools/browser/abc123") # formato REAL devolvido pelo Chrome (sem porta)

    ws_url = FerumConfig.discover_stealth_ws_url

    assert_equal "ws://#{CHROME_V4}:#{@chrome_port}/devtools/browser/abc123", ws_url
    assert_equal CHROME_V4, URI(ws_url).host
    assert_not_includes ws_url, @chrome_host
  end

  test "ws_url fixa IPv4 mesmo quando o resolvedor devolve IPv6 primeiro" do
    # pré-condição do cenário: sem família pedida, o DNS falso devolve o v6 antes
    assert Addrinfo.getaddrinfo(@chrome_host, nil).first.ipv6?, "cenário exige v6 primeiro"
    assert_equal CHROME_V6, Socket.getaddrinfo(@chrome_host, nil).first[3], "cenário exige v6 primeiro"
    stub_version("ws://127.0.0.1:9222/devtools/browser/abc123")

    host = URI(FerumConfig.discover_stealth_ws_url).host

    assert_equal CHROME_V4, host
    assert_not_includes host, ":"
  end

  test "discover_stealth_ws_url levanta quando o servico so tem IPv6 (nao cai no nome)" do
    FakeChromeDns.install(@chrome_host => [CHROME_V6])
    stub_version("ws://localhost/devtools/browser/abc123")

    assert_raises(RuntimeError) { FerumConfig.discover_stealth_ws_url }
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
    assert_includes ws_url, CHROME_V4
  end

  test "discover_stealth_ws_url should replace localhost with the resolved IPv4 of CHROME_HOST" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://localhost:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    ws_url = FerumConfig.discover_stealth_ws_url

    assert_includes ws_url, "ws://#{CHROME_V4}:#{@chrome_port}/"
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
    assert_equal 12, options[:protocol_timeout]
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

