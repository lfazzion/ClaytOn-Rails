# frozen_string_literal: true

module ScrapingServices
  class RateLimitError < StandardError
    attr_reader :retry_after, :original_error

    def initialize(message, retry_after: 6.hours, original_error: nil)
      super(message)
      @retry_after = retry_after
      @original_error = original_error
    end
  end

  class RateLimitHandler
    EXPLICIT_RATE_LIMIT_TEXT_PATTERNS = [
      /rate.?limit/i,
      /blocked/i,
      /captcha/i,
      /cloudflare/i,
      /datadome/i
    ].freeze

    SUSPICIOUS_PATTERNS = [
      /connection.?reset/i,
      /timeout/i,
      /empty.?response/i,
      /net::(read|open)_timeout/i
    ].freeze

    DEFAULT_BACKOFF = 6.hours
    HEAVY_BACKOFF   = 12.hours

    class << self
      def handle_error(error, context = {})
        raise error unless rate_limited?(error, context)

        retry_after = determine_backoff(error, context)
        raise RateLimitError.new(
          "Rate limit detectado: #{error.message}",
          retry_after: retry_after,
          original_error: error
        )
      end

      def rate_limited?(error, context = {})
        message = error.message.to_s
        return true if message.match?(/429/i)
        # ACHADO C (P2, sol 13/08): só classifica como rate limit quando o
        # header Retry-After é *válido e positivo*. Antes, qualquer valor não
        # vazio (inclusive "0" ou "garbage") virava RateLimitError, aplicando
        # 6h de bloqueio em parse inválido. Agora exigimos parse_retry_after
        # retornar um valor numérico > 0.
        return true if (context[:retry_after].present? && parse_retry_after(context[:retry_after]))
        return true if EXPLICIT_RATE_LIMIT_TEXT_PATTERNS.any? { |pattern| message.match?(pattern) }
        false
      end

      def determine_backoff(error, context = {})
        message = error.message.to_s

        if context[:retry_after].present?
          parsed = parse_retry_after(context[:retry_after])
          return parsed if parsed
        end

        return HEAVY_BACKOFF if suspicious_block?(error)
        return HEAVY_BACKOFF if (context[:retry_count] || 0) > 2
        return HEAVY_BACKOFF if message.match?(/cloudflare|datadome/i)
        return 2.hours       if message.match?(/429/i)
        return DEFAULT_BACKOFF if message.match?(/403|503/i)

        DEFAULT_BACKOFF
      end

      def suspicious_block?(error)
        message = error.message.to_s
        SUSPICIOUS_PATTERNS.any? { |pattern| message.match?(pattern) }
      end

      private

      def parse_retry_after(val)
        return nil if val.nil?

        if val.is_a?(Numeric)
          # ACHADO H (P2, sol rodada 2, 13/08): `Numeric` passava SEM a
          # validação de positividade — retry_after: 0, -1, NaN ou infinito
          # eram truthy e classificavam como rate limit. Exigir finito e > 0
          # também para numéricos.
          return nil if val.is_a?(Float) && (!val.finite? || val <= 0)
          return nil if val.is_a?(Integer) && val <= 0
          return val
        end

        num = val.to_f
        return nil if num <= 0

        num.to_i == num ? num.to_i : num
      rescue StandardError
        nil
      end
    end
  end
end
