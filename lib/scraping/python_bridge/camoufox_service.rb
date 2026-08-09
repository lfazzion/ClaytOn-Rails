# frozen_string_literal: true

require 'json'
require_relative 'sidecar_client'

module ScrapingServices
  class CamoufoxService
    CAMOUFOX_SCRIPT = 'camoufox_scrape.py'
    TIMEOUT = SidecarClient::DEFAULT_TIMEOUT

    class << self
      def scrape_url(url, proxy: nil)
        script, args = build_command(url, proxy)
        result = execute(script, args)
        return nil if result.nil?

        result.deep_symbolize_keys
      end

      def scrape_batch(urls, proxy: nil)
        urls.map do |url|
          data = scrape_url(url, proxy: proxy)
          { url: url, data: data }
        end
      end

      private

      # Retorna [script, args] — o script roda no sidecar, não neste container.
      def build_command(url, proxy)
        script = CAMOUFOX_SCRIPT
        args = [url]
        args += ['--proxy', proxy] if proxy
        [script, args]
      end

      def execute(script, args)
        stdout, stderr, status = SidecarClient.capture(script: script, args: args, timeout: TIMEOUT)

        if rate_limit?(stderr)
          raise RateLimitHandler.handle_error(
            StandardError.new(stderr),
            retry_count: 0
          )
        end

        unless status.success?
          Rails.logger.error "[CamoufoxService] Falha (exit #{status.exitstatus}): #{stderr}"
          return nil
        end

        return nil if stdout.strip.empty?

        JSON.parse(stdout.strip)
      rescue JSON::ParserError => e
        Rails.logger.error "[CamoufoxService] JSON inválido: #{e.message}"
        nil
      end

      def rate_limit?(stderr)
        patterns = ['429', 'Blocked', 'Captcha', 'rate limit', '403 Forbidden']
        patterns.any? { |p| stderr.include?(p) }
      end
    end
  end
end
