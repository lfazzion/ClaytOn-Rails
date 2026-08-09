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
      args = build_command(url, method: method, headers: headers, body: body)
      execute(File.basename(SCRIPT_PATH.to_s), args)
    end

    # Monta o vetor de argumentos que o sidecar recebe (a partir da URL). Sem o
    # prefixo morto 'python3 -u SCRIPT_PATH': o sidecar já roda o script pelo
    # nome, e este vetor É o contrato real (o split_command foi removido — os
    # testes afirmam exatamente sobre estes elementos).
    def build_command(url, method:, headers: {}, body: nil)
      args = [url, '--method', method, '--profile', @profile.to_s]

      args += ['--proxy', @proxy] if @proxy

      headers.each do |key, val|
        args += ['--header', "#{key}:#{val}"]
      end

      args += ['--body', body] if body

      args
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
