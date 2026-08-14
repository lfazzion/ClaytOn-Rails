require "test_helper"
require "webmock"

class ChromeWsConnectorLibTest < ActiveSupport::TestCase
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

  test "chrome_ws_connector.rb should exist in lib" do
    assert File.exist?(Rails.root.join("lib", "chrome_ws_connector.rb"))
  end

  test "ChromeWsConnector module should be defined" do
    assert defined?(ChromeWsConnector)
  end

  test "ChromeWsConnector constants should be set from env" do
    assert_equal @chrome_host, ChromeWsConnector::CHROME_HOST
    assert_equal @chrome_port, ChromeWsConnector::CHROME_PORT
  end

  test "fetch_ws_url should inject Host: localhost header" do
    mock_response = {
      "webSocketDebuggerUrl" => "ws://127.0.0.1:9222/devtools/browser/abc123"
    }.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    ws_url = ChromeWsConnector.fetch_ws_url

    assert_includes ws_url, "ws://"
    assert_includes ws_url, "/devtools/browser/"
  end

  test "replace_host should substitute localhost with chrome host" do
    url = "ws://localhost:9222/devtools/browser/abc"
    result = ChromeWsConnector.replace_host(url)
    assert_equal "ws://chrome:9222/devtools/browser/abc", result
  end

  test "replace_host should substitute 127.0.0.1 with chrome host" do
    url = "ws://127.0.0.1:9222/devtools/browser/abc"
    result = ChromeWsConnector.replace_host(url)
    assert_equal "ws://chrome:9222/devtools/browser/abc", result
  end

  test "fetch_ws_url should raise Error on non-200 response" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 503)

    assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
  end

  test "fetch_ws_url should raise Error when WS URL missing" do
    mock_response = {}.to_json

    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: mock_response, headers: { "Content-Type" => "application/json" })

    assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
  end

  test "fetch_ws_url should raise Error on 200 with HTML response" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: "<!DOCTYPE html><html><body>Not JSON</body></html>", headers: { "Content-Type" => "text/html" })

    exception = assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
    assert_kind_of JSON::ParserError, exception.cause
  end

  test "fetch_ws_url should raise Error on 200 with empty response body" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: "", headers: { "Content-Type" => "application/json" })

    exception = assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
    assert_kind_of JSON::ParserError, exception.cause
  end

  test "fetch_ws_url should raise Error on 200 with malformed JSON" do
    stub_request(:get, "http://#{@chrome_host}:#{@chrome_port}/json/version")
      .with(headers: { "Host" => "localhost" })
      .to_return(status: 200, body: "{invalid json,,,", headers: { "Content-Type" => "application/json" })

    exception = assert_raises(ChromeWsConnector::Error) { ChromeWsConnector.fetch_ws_url }
    assert_kind_of JSON::ParserError, exception.cause
  end

  test "ChromeWsConnector::Error should be a StandardError" do
    assert ChromeWsConnector::Error < StandardError
  end
end
