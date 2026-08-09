# frozen_string_literal: true

begin
  require "readability"
rescue LoadError
  # ruby-readability opcional; fallback degrada pra body plain.
end

module Fetcher
  module ReadabilityInjector
    MIN_READABILITY_LENGTH = 500
    DEFAULT_MAX_CHARS = 8_000
    MIN_BODY_FOR_LIVE = 20
    READABILITY_JS_PATH = Rails.root.join("vendor/javascript/readability.min.js")
    READABILITY_JS = File.exist?(READABILITY_JS_PATH) ? File.read(READABILITY_JS_PATH) : ""

    class << self
      def extract(readability_text:, body_text:, fallback_html:, live: false, max_chars: DEFAULT_MAX_CHARS)
        readability_text = normalize_whitespace(readability_text)
        body_text        = normalize_whitespace(body_text)

        chosen = pick(readability_text: readability_text, body_text: body_text, live: live)

        if chosen.to_s.empty?
          ruby_fallback = extract_with_ruby_readability(fallback_html)
          chosen = normalize_whitespace(ruby_fallback)
        end

        truncate_to(chosen.to_s, max_chars)
      end

      private

      def pick(readability_text:, body_text:, live:)
        if live
          return body_text unless body_text.to_s.length < MIN_BODY_FOR_LIVE
          return readability_text if readability_text.to_s.length >= 1
        end

        return readability_text if readability_text.to_s.length >= MIN_READABILITY_LENGTH
        return body_text if body_text.to_s.length.positive?

        readability_text
      end

      def extract_with_ruby_readability(html)
        return "" if html.to_s.empty?
        return "" unless defined?(Readability::Document)

        doc = Readability::Document.new(html)
        content_html = doc.content.to_s
        content_html.gsub(/<[^>]+>/, " ")
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::ReadabilityInjector] ruby-readability falhou: #{e.class}: #{e.message}"
        ""
      end

      def normalize_whitespace(text)
        return "" if text.nil?

        text.to_s
            .gsub(/\t+/, " ")
            .gsub(/[ ]{2,}/, " ")
            .gsub(/\n{3,}/, "\n\n")
            .strip
      end

      def truncate_to(text, max_chars)
        char_count = text.length
        if char_count <= max_chars
          return { content: text, truncated: false, char_count: char_count }
        end

        window = text[0, max_chars]
        boundary = window.rindex("\n\n")
        clipped = if boundary && boundary > max_chars / 2
                    text[0, boundary + 2]
                  else
                    window
                  end
        { content: clipped, truncated: true, char_count: clipped.length }
      end
    end
  end
end
