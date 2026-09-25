require "test_helper"
require "webmock"
require_relative "../../lib/chrome_ws_connector"
require_relative "../support/fake_chrome_dns"

class ChromeWsConnectorTest < ActiveSupport::TestCase
  # O nome do serviço resolve para v6 (devolvido PRIMEIRO) e v4; o ws_url tem de
  # sair com o v4. Ver RELATORIO-CHROME-151.md: 151 recusa Host por nome no WS.
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

  test "should fetch WebSocket URL successfully" do
    stub_version("ws://127.0.0.1:9222/devtools/browser/abc123")

    ws_url = ChromeWsConnector.fetch_ws_url

    assert_includes ws_url, "ws://"
    assert_includes ws_url, "/devtools/browser/"
  end

  test "fetch_ws_url sai com o IPv4 e a porta do servico, nunca com o nome do container" do
    # formato REAL do Chrome atrás do socat com `Host: localhost`: sem porta
    stub_version("ws://localhost/devtools/browser/abc123")

    ws_url = ChromeWsConnector.fetch_ws_url

    assert_equal "ws://#{CHROME_V4}:#{@chrome_port}/devtools/browser/abc123", ws_url
    assert_not_includes ws_url, @chrome_host
  end

  test "fetch_ws_url fixa IPv4 mesmo quando o resolvedor devolve IPv6 primeiro" do
    assert_equal CHROME_V6, Socket.getaddrinfo(@chrome_host, nil).first[3], "cenário exige v6 primeiro"
    stub_version("ws://localhost:9222/devtools/browser/abc123")

    host = URI(ChromeWsConnector.fetch_ws_url).host

    assert_equal CHROME_V4, host
  end

  test "fetch_ws_url levanta Error quando o servico so tem IPv6" do
    FakeChromeDns.install(@chrome_host => [CHROME_V6])
    stub_version("ws://localhost/devtools/browser/abc123")

    assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
  end

  test "should replace localhost with the chrome IPv4" do
    stub_version("ws://localhost:9222/devtools/browser/abc123")

    ws_url = ChromeWsConnector.fetch_ws_url

    assert_includes ws_url, "ws://#{CHROME_V4}:#{@chrome_port}/"
    assert_not_includes ws_url, "localhost"
  end

  test "should replace 127.0.0.1 with the chrome IPv4" do
    stub_version("ws://127.0.0.1:9222/devtools/browser/abc123")

    ws_url = ChromeWsConnector.fetch_ws_url

    assert_includes ws_url, "ws://#{CHROME_V4}:#{@chrome_port}/"
    assert_not_includes ws_url, "127.0.0.1"
  end

  test "should use default env values when not set" do
    ENV.delete("CHROME_HOST")
    ENV.delete("CHROME_PORT")

    assert_equal "chrome", ChromeWsConnector.chrome_host
    assert_equal 9222, ChromeWsConnector.chrome_port
  end

  test "should raise error when response is not 200" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 503, body: "Service Unavailable")

    assert_raises(ChromeWsConnector::Error) do
      ChromeWsConnector.fetch_ws_url
    end
  end

  test "should raise error when no WebSocket URL in response" do
    mock_response = {}.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    assert_raises(ChromeWsConnector::Error) do
      ChromeWsConnector.fetch_ws_url
    end
  end

  test "replace_host should correctly replace localhost" do
    url = "ws://localhost:9222/devtools/browser/abc"
    result = ChromeWsConnector.replace_host(url)

    assert_equal "ws://#{CHROME_V4}:9222/devtools/browser/abc", result
  end

  test "replace_host should correctly replace 127.0.0.1" do
    url = "ws://127.0.0.1:9222/devtools/browser/abc"
    result = ChromeWsConnector.replace_host(url)

    assert_equal "ws://#{CHROME_V4}:9222/devtools/browser/abc", result
  end

  test "replace_host poe a porta do servico quando o Chrome devolve a URL sem porta" do
    result = ChromeWsConnector.replace_host("ws://localhost/devtools/browser/abc")

    assert_equal "ws://#{CHROME_V4}:#{@chrome_port}/devtools/browser/abc", result
  end
end
