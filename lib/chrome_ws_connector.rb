require 'net/http'
require 'json'
require 'socket'
require 'uri'

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

  # Troca o host devolvido pelo Chrome (`localhost`/127.0.0.1) pelo IPv4 do
  # serviço e fixa a porta — NUNCA o nome do container: o 151 recusa `Host` por
  # nome no handshake WebSocket (medido em 25/09/2026, RELATORIO-CHROME-151.md).
  # A porta é fixada porque o Chrome atrás do socat devolve `ws://localhost/...`
  # sem porta, o que levaria o cliente para a 80.
  def self.replace_host(url)
    uri = URI(url)
    uri.host = chrome_ipv4
    uri.port = CHROME_PORT
    uri.to_s
  end

  # IPv4 do CHROME_HOST, pedido como AF_INET: `getaddrinfo` sem família pode
  # devolver IPv6 primeiro, e esse não é o caminho medido.
  def self.chrome_ipv4
    Addrinfo.getaddrinfo(CHROME_HOST, nil, Socket::AF_INET, :STREAM).first.ip_address
  rescue SocketError => e
    raise Error, "No IPv4 address for Chrome host #{CHROME_HOST}: #{e.message}"
  end

  def self.chrome_host
    CHROME_HOST
  end

  def self.chrome_port
    CHROME_PORT
  end
end
