# frozen_string_literal: true

# config/initializers/ferrum.rb
#
# Resolve o problema de Host-header rejection no Chrome 120+ quando acessado
# via Docker network bridge. O Chrome expõe o debugger em 0.0.0.0:9222
# mas valida o header `Host:` — se ele não for "localhost", rejeita o WS handshake.
#
# Este initializer expõe o helper `FerumConfig.browser_options` que todos os
# scrapers devem usar ao instanciar `Ferrum::Browser`.

require 'net/http'
require 'json'
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

    # Substitui o hostname retornado pelo Chrome (pode ser o nome interno do
    # container ou 127.0.0.1) pelo CHROME_HOST configurado — necessário porque
    # em rede Docker o Ruby não resolve "localhost" para o container correto.
    ws_uri          = URI(raw_ws_url)
    ws_uri.host     = CHROME_HOST
    ws_uri.port     = CHROME_PORT

    ws_uri.to_s
  end

  # Opções padrão para instanciar Ferrum::Browser.
  # Uso: Ferrum::Browser.new(**FerumConfig.browser_options)
  def self.browser_options
    # timeout: 12 é o teto de um único comando CDP/wait e TEM de ser menor que
    # PageFetcher::GOTO_TIMEOUT (20s) e OVERALL_TIMEOUT (25s).
    stealth_opts = {
      ws_url: discover_stealth_ws_url,
      timeout: 12,
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
