# frozen_string_literal: true

require "digest"
require "time"

module Research
  module Sentiment
    module Sources
      class X
        DEFAULT_LIMIT = 600

        class << self
          def fetch(query:, limit: DEFAULT_LIMIT)
            q = query.to_s.strip
            return [] if q.empty?

            raw_items = if q.start_with?("@")
                          user = q.delete_prefix("@")
                          Fetcher::Channels::X.timeline(user: user, limit: limit)
                        else
                          Fetcher::Channels::X.search(query: q, limit: limit)
                        end

            return [] if raw_items.blank?

            raw_items.map do |item|
              text = item["text"].to_s.strip
              url = item["url"]
              post_id = extract_status_id(url) || Digest::SHA256.hexdigest("#{url}#{text}")[0..31]

              {
                source: "x",
                external_id: post_id,
                permalink: url,
                author: item["author"] || item["screen_name"],
                text: text,
                posted_at: parse_time(item["created_at"])
              }
            end
          end

          private

          def extract_status_id(url)
            url.to_s[%r{/status/(\d+)}, 1]
          end

          def parse_time(str)
            return nil if str.blank?

            Time.iso8601(str.to_s).utc
          rescue ArgumentError, TypeError
            nil
          end
        end
      end
    end
  end
end
