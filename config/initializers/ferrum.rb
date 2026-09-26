# frozen_string_literal: true

# config/initializers/ferrum.rb
#
# Resolve o problema de Host-header rejection do DevTools quando acessado via
# Docker network bridge. O Chrome só aceita `Host` = IP ou "localhost"
# ("Host header is specified and is not an IP address or localhost"):
#   - HTTP /json/version: rejeita nome de container no 147 E no 151 → injetamos
#     `Host: localhost`;
#   - handshake WebSocket: o 147 aceitava nome, o 151 rejeita → o ws_url sai
#     com o IPv4 do serviço (medido em 25/09/2026, RELATORIO-CHROME-151.md).
#
# Este initializer expõe o helper `FerumConfig.browser_options` que todos os
# scrapers devem usar ao instanciar `Ferrum::Browser`.

require 'net/http'
require 'json'
require 'socket'
require 'uri'

module FerumConfig
  CHROME_HOST = ENV.fetch('CHROME_HOST', 'chrome')
  CHROME_PORT = ENV.fetch('CHROME_PORT', '9222').to_i

  # Varre o endpoint HTTP do Chrome (/json/version) injetando `Host: localhost`
  # para burlar a validação de security-origin do Chrome 120+.
  # Retorna a URL WebSocket correta com hostname substituído pelo IP do container.
  #
  # @return [String] WebSocket debugger URL com host resolvido
  # @raise [RuntimeError] se o Chrome não responder ou não retornar ws URL
  def self.discover_stealth_ws_url
    uri = URI("http://#{CHROME_HOST}:#{CHROME_PORT}/json/version")

    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) do |http|
      req = Net::HTTP::Get.new(uri)
      req['Host'] = 'localhost' # <- bypass da validação de origin do Chrome 120+
      http.request(req)
    end

    raise "Chrome não respondeu (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

    payload      = JSON.parse(response.body)
    raw_ws_url   = payload['webSocketDebuggerUrl']

    raise 'webSocketDebuggerUrl ausente na resposta do Chrome' if raw_ws_url.nil?

    # O Chrome devolve `ws://localhost/...` (ou 127.0.0.1). O handshake WebSocket
    # tem de sair com o IPv4 do serviço, NUNCA com o nome do container: medido em
    # 25/09/2026 (RELATORIO-CHROME-151.md) — o 151 recusa `Host` por nome no
    # handshake (500 → Ferrum::DeadBrowserError); IP é aceito no 147 e no 151.
    ws_uri          = URI(raw_ws_url)
    ws_uri.host     = chrome_ipv4
    ws_uri.port     = CHROME_PORT

    ws_uri.to_s
  end

  # IPv4 do CHROME_HOST, pedido explicitamente como AF_INET: `getaddrinfo` sem
  # família pode devolver IPv6 primeiro, e esse não é o caminho medido.
  # Sem IPv4 levanta (o chamador cai no fallback) em vez de voltar ao nome.
  def self.chrome_ipv4
    Addrinfo.getaddrinfo(CHROME_HOST, nil, Socket::AF_INET, :STREAM).first.ip_address
  rescue SocketError => e
    raise "Sem IPv4 para o Chrome (#{CHROME_HOST}): #{e.message}"
  end

  # Opções padrão para instanciar Ferrum::Browser.
  # Uso: Ferrum::Browser.new(**FerumConfig.browser_options)
  def self.browser_options
    # timeout: 12 é o teto de um único comando CDP/wait e TEM de ser menor que
    # PageFetcher::GOTO_TIMEOUT (20s) e OVERALL_TIMEOUT (25s).
    stealth_opts = {
      ws_url: discover_stealth_ws_url,
      timeout: 12,
      protocol_timeout: 12,
      process_timeout: 30,
      headless: true,
      window_size: [1366, 768]
    }

    stealth_opts[:browser_options] = {
      'disable-blink-features' => 'AutomationControlled',
      'no-sandbox' => nil,
      'disable-dev-shm-usage' => nil,
      'disable-gpu' => nil,
      'disable-web-security' => nil
    }.compact

    stealth_opts[:browser_options]['--proxy-server'] = ENV['SCRAPING_PROXY'] if ENV['SCRAPING_PROXY'].present?

    stealth_opts
  rescue StandardError => e
    Rails.logger.error "[FerumConfig] Falha ao resolver WS URL do Chrome: #{e.message}"
    # Fallback: deixa o Ferrum tentar conectar diretamente (ambiente dev/test)
    {
      browser_path: ENV.fetch('CHROME_BIN', nil),
      timeout: 12,
      protocol_timeout: 12,
      headless: true
    }.compact
  end

  STEALTH_USER_AGENTS = [
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  ].freeze

  def self.random_user_agent
    STEALTH_USER_AGENTS.sample
  end

  def self.stealth_browser_options
    opts = browser_options
    opts[:browser_options]['--user-agent'] = random_user_agent
    opts
  end
end

