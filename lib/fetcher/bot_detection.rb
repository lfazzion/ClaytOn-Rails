# frozen_string_literal: true

module Fetcher
  module BotDetection
    CACHE_PREFIX = "page_fetch:cooldown"

    BLOCK_TITLES = [
      "just a moment",
      "attention required",
      "access denied"
    ].freeze

    BLOCK_BODY_MARKERS = %w[
      cf-turnstile
      cf-chl-bypass
      __cf_chl_
    ].freeze

    BLOCK_URL_MARKERS = %w[
      /cdn-cgi/challenge-platform/
    ].freeze

    class << self
      def blocked?(page)
        status = safe(page, :status)
        return true if status == 403 || status == 429

        title = safe(page, :title).to_s.downcase
        return true if BLOCK_TITLES.any? { |m| title.include?(m) }

        body = safe(page, :body).to_s
        return true if BLOCK_BODY_MARKERS.any? { |m| body.include?(m) }

        url = safe(page, :current_url).to_s
        return true if BLOCK_URL_MARKERS.any? { |m| url.include?(m) }

        false
      end

      def cooldown!(host, reason:)
        host = normalize(host)
        ttl = rand((6 * 3600)..(12 * 3600))
        now = Time.current
        payload = {
          blocked_at: now,
          expires_at: now + ttl,
          reason: reason.to_s
        }
        Rails.cache.write(key(host), payload, expires_in: ttl)
        payload
      end

      def cooldown_for(host)
        Rails.cache.read(key(normalize(host)))
      end

      def cooldown?(host)
        !cooldown_for(host).nil?
      end

      def clear!(host)
        Rails.cache.delete(key(normalize(host)))
      end

      private

      def key(host)
        "#{CACHE_PREFIX}:#{host}"
      end

      def normalize(host)
        host.to_s.strip.downcase
      end

      def safe(page, method)
        page.respond_to?(method) ? page.public_send(method) : nil
      rescue StandardError
        nil
      end
    end
  end
end
