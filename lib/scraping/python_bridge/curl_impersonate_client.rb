# frozen_string_literal: true

require 'json'
require_relative 'sidecar_client'

module ScrapingServices
  class CurlImpersonateClient
    SCRIPT_PATH = Rails.root.join('scripts/python/curl_impersonate.py')
    TIMEOUT = SidecarClient::DEFAULT_TIMEOUT

    IMPERSONATE_PROFILES = %i[chrome safari firefox chrome_android edge].freeze

    attr_reader :profile, :proxy

    def initialize(profile: :chrome, proxy: nil)
      @profile = IMPERSONATE_PROFILES.include?(profile) ? profile : :chrome
      @proxy = proxy
    end

    def get(url, headers: {})
      request(url, method: 'GET', headers: headers)
    end

    def post(url, body: nil, headers: {})
      request(url, method: 'POST', body: body, headers: headers)
    end

    private

    def request(url, method:, headers: {}, body: nil)
      command = build_command(url, method: method, headers: headers, body: body)
      script, args = split_command(command)
      execute(script, args)
    end

    # Mantém o formato `cmd` (vetor com 'python3', '-u', SCRIPT_PATH, url, ...) por
    # causa dos testes que fazem `assert_includes cmd, 'safari'` etc. — o que
    # importa é o array de strings, não o executor. O `split_command` traduz
    # para o par (script, args) que o SidecarClient espera.
    def build_command(url, method:, headers: {}, body: nil)
      cmd = ['python3', '-u', SCRIPT_PATH.to_s, url, '--method', method, '--profile', @profile.to_s]

      cmd += ['--proxy', @proxy] if @proxy

      headers.each do |key, val|
        cmd += ['--header', "#{key}:#{val}"]
      end

      cmd += ['--body', body] if body

      cmd
    end

    def split_command(cmd)
      # O comando local era ['python3', '-u', SCRIPT_PATH, url, --opcoes...].
      # O sidecar recebe só o nome do script python e os argumentos a partir do URL.
      script = File.basename(SCRIPT_PATH.to_s)
      # encontra o índice do URL (primeiro argumento que não é flag e não é o caminho)
      url_index = cmd.index { |a| !a.start_with?('-') && a != SCRIPT_PATH.to_s && a != 'python3' && a != '-u' }
      args = url_index ? cmd[(url_index)..] : []
      [script, args]
    end

    def execute(script, args)
      stdout, stderr, status = SidecarClient.capture(script: script, args: args, timeout: TIMEOUT)

      if rate_limit?(stdout, stderr)
        raise RateLimitHandler.handle_error(
          StandardError.new(stderr.presence || stdout),
          retry_count: 0
        )
      end

      unless status.success?
        Rails.logger.error "[CurlImpersonateClient] Falha (exit #{status.exitstatus}): #{stderr}"
        return nil
      end

      return nil if stdout.strip.empty?

      parsed = JSON.parse(stdout.strip)
      return nil unless parsed['success']

      parsed
    rescue JSON::ParserError => e
      Rails.logger.error "[CurlImpersonateClient] JSON inválido: #{e.message}"
      nil
    end

    def rate_limit?(stdout, stderr)
      return true if ['429', 'Blocked', 'Captcha', 'rate limit', '403 Forbidden'].any? { |p| stderr.include?(p) }

      begin
        parsed = JSON.parse(stdout.strip)
        return true if parsed['error']&.include?('rate_limit')
      rescue JSON::ParserError
        # stdout não é JSON, ignorar
      end

      false
    end
  end
end
