# frozen_string_literal: true

require "yaml"

module Fetcher
  module TtlPolicy
    LIVE_TTL    = 60
    NEWS_TTL    = 3_600       # 1h
    DOCS_TTL    = 604_800     # 7d
    DEFAULT_TTL = 900         # 15min

    DOCS_HOSTS = %w[
      github.com
      rubydoc.info
      docs.rubyonrails.org
      developer.mozilla.org
      wikipedia.org
    ].freeze

    DOCS_SUFFIXES = %w[
      .readthedocs.io
    ].freeze

    NEWS_PATH_REGEX = %r{\A/(news/|\d{4}/\d{2}/)}

    class << self
      def for(host:, path:)
        host = host.to_s.downcase
        return LIVE_TTL if live_host?(host)
        return DOCS_TTL if docs_host?(host)
        return NEWS_TTL if news_path?(path)

        DEFAULT_TTL
      end

      def live_host?(host)
        live_hosts.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
      end

      def docs_host?(host)
        return true if DOCS_HOSTS.any? { |base| host == base || host.end_with?(".#{base}") }

        DOCS_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
      end

      def news_path?(path)
        return false if path.nil? || path.empty?

        NEWS_PATH_REGEX.match?(path)
      end

      def live_hosts
        @live_hosts ||= load_live_hosts
      end

      def reset!
        @live_hosts = nil
      end

      private

      def load_live_hosts
        path = Rails.root.join("config/live_hosts.yml")
        return [] unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        Array(data["live_hosts"]).map(&:to_s).map(&:downcase)
      end
    end
  end
end
