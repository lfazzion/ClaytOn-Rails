require 'net/http'
require 'json'

module ChromeWsConnector
  CHROME_HOST = ENV.fetch('CHROME_HOST', 'chrome')
  CHROME_PORT = ENV.fetch('CHROME_PORT', '9222').to_i

  class Error < StandardError; end

  def self.fetch_ws_url
    uri = URI("http://#{CHROME_HOST}:#{CHROME_PORT}/json/version")

    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Get.new(uri)
    request["Host"] = "localhost"

    response = http.request(request)

    raise Error, "Failed to connect to Chrome: #{response.code}" unless response.code == "200"

    data = begin
             JSON.parse(response.body)
           rescue JSON::ParserError => e
             raise Error, "Invalid response body (not valid JSON): #{response.body.inspect}", cause: e
           end
    ws_url = data["webSocketDebuggerUrl"]

    raise Error, "No WebSocket URL found in response" unless ws_url

    replace_host(ws_url)
  end

  def self.replace_host(url)
    url.gsub(/127\.0\.0\.1|localhost/, CHROME_HOST)
  end

  def self.chrome_host
    CHROME_HOST
  end

  def self.chrome_port
    CHROME_PORT
  end
end
