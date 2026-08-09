# frozen_string_literal: true

require 'json'
require 'net/http'
require 'timeout'
require 'uri'

module ScrapingServices
  # Cliente HTTP do sidecar `python-scraper`.
  #
  # As bibliotecas de scraping evasivo (nodriver, camoufox, curl_cffi, playwright)
  # só existem na imagem docker/Dockerfile.python. Rodar `Open3.capture3(['python3',
  # ...])` de dentro do app/jobs levanta ModuleNotFoundError — os módulos não estão
  # lá. Este cliente executa o script no container que tem as libs.
  #
  # Devolve a mesma tripla de `Open3.capture3` — [stdout, stderr, status] — para que
  # as pontes existentes não precisem mudar a lógica de parsing/rate-limit.
  #
  # `docker exec` a partir do Rails foi descartado de propósito: exigiria montar o
  # socket do Docker no app, o que transforma qualquer RCE no Rails em controle do
  # daemon inteiro.
  class SidecarClient
    DEFAULT_BASE_URL = 'http://python-scraper:8080'
    DEFAULT_TIMEOUT  = 180
    CONNECT_TIMEOUT  = 5
    # Margem sobre o timeout do script para o sidecar responder o JSON de timeout.
    RESPONSE_MARGIN  = 10

    Status = Struct.new(:exitstatus) do
      def success?
        exitstatus.to_i.zero?
      end
    end

    class << self
      # Retorna [stdout, stderr, status] — compatível com Open3.capture3.
      def capture(script:, args: [], timeout: DEFAULT_TIMEOUT)
        response = post_run(script: script, args: args, timeout: timeout)
        unpack(script, response)
      rescue Net::OpenTimeout
        # Sidecar que não aceita conexão é INDISPONIBILIDADE, não timeout de
        # script: sobe em CONNECT_TIMEOUT (5s) e seria logado como "timeout de
        # 190s" se caísse no rescue Timeout::Error abaixo (Net::OpenTimeout é
        # subclasse de Timeout::Error). Trata como falha de scraping.
        Rails.logger.error "[SidecarClient] #{script} indisponível (Net::OpenTimeout após #{CONNECT_TIMEOUT}s)"
        failure("sidecar indisponível (não aceitou conexão após #{CONNECT_TIMEOUT}s)")
      rescue Timeout::Error
        # Timeout autoritativo (script estourou o teto do sidecar): propaga.
        # Nenhuma job resgata Timeout::Error hoje — quem chamar decide.
        Rails.logger.error "[SidecarClient] timeout de #{timeout + RESPONSE_MARGIN}s em #{script}"
        raise
      rescue StandardError => e
        Rails.logger.error "[SidecarClient] #{script} falhou: #{e.class}: #{e.message}"
        failure("sidecar indisponível (#{e.class}: #{e.message})")
      end

      def base_url
        ENV['PYTHON_SCRAPER_URL'].presence || DEFAULT_BASE_URL
      end

      def token
        ENV['PYTHON_SCRAPER_TOKEN'].presence
      end

      private

      def post_run(script:, args:, timeout:)
        uri = URI.join("#{base_url}/", 'run')
        body = JSON.generate(script: script, args: Array(args).map(&:to_s), timeout: timeout)

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{token}" if token
        request.body = body

        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = CONNECT_TIMEOUT
        http.read_timeout = timeout + RESPONSE_MARGIN

        # O timeout autoritativo é daqui, não do sidecar.
        Timeout.timeout(timeout + RESPONSE_MARGIN) { http.request(request) }
      end

      def unpack(script, response)
        parsed = parse_json(response.body)

        unless response.is_a?(Net::HTTPSuccess)
          message = parsed.is_a?(Hash) ? parsed['error'].to_s : response.body.to_s
          return failure("sidecar respondeu #{response.code} para #{script}: #{message}")
        end

        return failure("resposta do sidecar não é JSON (#{script})") unless parsed.is_a?(Hash)

        stdout = parsed['stdout'].to_s
        stderr = parsed['stderr'].to_s
        exit_code = parsed['timed_out'] ? 124 : parsed['exit_code']

        [stdout, stderr, Status.new(exit_code.nil? ? 1 : exit_code.to_i)]
      end

      def parse_json(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end

      def failure(message)
        Rails.logger.error "[SidecarClient] #{message}"
        ['', message, Status.new(1)]
      end
    end
  end
end
