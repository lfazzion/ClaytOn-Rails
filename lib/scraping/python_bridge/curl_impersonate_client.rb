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

      # 429/503/403 com exit 0 vêm como JSON no stdout — o script os classifica
      # explicitamente. Rate-limit (429) é o único que dispara RateLimitError;
      # 403 (blocked) e 503 (unavailable) não são retryable, mas não devem
      # sumir silenciosamente — loga o motivo real antes de retornar nil.
      error_kind = classify_exit(stdout, stderr)
      raise RateLimitHandler.handle_error(
        StandardError.new(stderr.presence || stdout),
        retry_count: 0
      ) if error_kind == :rate_limit

      unless status.success?
        Rails.logger.error "[CurlImpersonateClient] Falha (exit #{status.exitstatus}): #{stderr}"
        return nil
      end

      return nil if stdout.strip.empty?

      parsed = JSON.parse(stdout.strip)
      log_non_rate_limit_error(error_kind, parsed)
      return nil unless parsed["success"]
      parsed
    rescue JSON::ParserError => e
      Rails.logger.error "[CurlImpersonateClient] JSON inválido: #{e.message}"
      nil
    end

    # Classifica a saída do script Python: :rate_limit, :blocked, :unavailable,
    # :error (não-HTTP) ou nil. Lê stderr primeiro (o script grava erros de
    # processo lá), depois o JSON do stdout para erros HTTP conhecidos.
    def classify_exit(stdout, stderr)
      # Texto explícito de bloqueio no stderr = rate limit (mesmos padrões do
      # RateLimitHandler: captcha/blocked/cloudflare). 403/503 como STATUS no
      # stdout JSON são :blocked/:unavailable (não rate limit, DECISÃO 5).
      return :rate_limit if ["429", "rate_limit", "captcha", "blocked", "cloudflare"].any? { |p| stderr.downcase.include?(p) }

      begin
        parsed = JSON.parse(stdout.strip)
        error = parsed["error"]
        return :rate_limit if error.to_s.start_with?("rate_limit_")
        return :blocked if error.to_s == "blocked_403"
        return :unavailable if error.to_s == "unavailable_503"
        return :error if error.present? && !parsed["success"]
      rescue JSON::ParserError
        # stdout não é JSON — ignora, deixa o caller decidir.
      end

      nil
    end

    def rate_limit?(stdout, stderr)
      classify_exit(stdout, stderr) == :rate_limit
    end

    def log_non_rate_limit_error(kind, parsed)
      return if kind.nil?
      Rails.logger.error "[CurlImpersonateClient] #{kind} (status #{parsed['status_code']}): #{parsed['error']}"
    end
  end
end
