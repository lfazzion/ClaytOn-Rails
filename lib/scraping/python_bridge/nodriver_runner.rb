# frozen_string_literal: true

require 'json'
require_relative 'sidecar_client'

module ScrapingServices
  class NodriverRunner
    PYTHON_SCRIPT_PATH = Rails.root.join('scripts/python')
    NODRIVER_SCRIPT = 'nodriver_instagram.py'
    TIMEOUT = 180

    class << self
      def scrape_instagram_profile(username, proxy: nil)
        script, args = build_command('profile', username, proxy: proxy)
        result = execute(script, args)
        return nil if result.nil?

        result.deep_symbolize_keys
      end

      def scrape_instagram_posts(username, limit: 12, proxy: nil)
        script, args = build_command('posts', username, limit: limit, proxy: proxy)
        result = execute(script, args)
        return [] if result.nil?

        result.map { |post| post.deep_symbolize_keys }
      end

      def scrape_twitter_profile(username, proxy: nil)
        script, args = build_command('profile', username, platform: 'twitter', proxy: proxy)
        result = execute(script, args)
        return nil if result.nil?

        result.deep_symbolize_keys
      end

      # Busca uma URL arbitrária via Nodriver (fallback Python para domínios hard-blocked).
      # Retorna hash { title:, url:, content:, html_bytes: } ou nil em falha.
      # Chamado por `Fetcher::PageFetcher` quando host está em `config/hard_domains.yml`.
      def fetch_page(url, proxy: nil)
        args = [url]
        args += ['--proxy', proxy] if proxy

        result = execute('nodriver_fetch.py', args)
        return nil if result.nil?

        result.deep_symbolize_keys
      end

      private

      # Retorna [script, args] — o script roda no sidecar, não neste container.
      def build_command(mode, username, limit: nil, platform: nil, proxy: nil)
        script = platform == 'twitter' ? 'nodriver_twitter.py' : NODRIVER_SCRIPT

        args = [username, '--mode', mode]
        args += ['--limit', limit.to_s] if limit
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
          Rails.logger.error "[NodriverRunner] Falha (exit #{status.exitstatus}): #{stderr}"
          return nil
        end

        return nil if stdout.strip.empty?

        JSON.parse(stdout.strip)
      rescue JSON::ParserError => e
        Rails.logger.error "[NodriverRunner] JSON inválido: #{e.message}"
        nil
      end

      def rate_limit?(stderr)
        patterns = ['429', 'Blocked', 'Captcha', 'rate limit', '403 Forbidden']
        patterns.any? { |p| stderr.include?(p) }
      end
    end
  end
end
