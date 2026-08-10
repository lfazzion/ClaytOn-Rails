# frozen_string_literal: true

require "digest"
require "time"

module Research
  module Sentiment
    module Sources
      class Reddit
        MAX_THREADS = 5
        DEFAULT_LIMIT = 600

        class << self
          def fetch(query:, limit: DEFAULT_LIMIT)
            threads = Fetcher::Channels::Reddit.search(query: query, limit: MAX_THREADS)
            return [] if threads.blank?

            phrases = []

            real_fetches = 0
            threads.each do |t|
              url = t["url"]
              next if url.blank?

              if real_fetches > 0 && !Rails.env.test?
                sleep 35
              end
              real_fetches += 1

              begin
                data = Fetcher::Channels::Reddit.thread_comments(url: url)
                next if data.nil? || data["comments"].blank?

                data["comments"].each do |c|
                  text = c["body"].to_s.strip
                  next if text.blank?

                  ext_id = Digest::SHA256.hexdigest("#{url}#{(c['author'] || 'anon')}#{text}")[0..31]

                  phrases << {
                    source: "reddit",
                    external_id: ext_id,
                    permalink: url,
                    author: c["author"].presence,
                    text: text,
                    posted_at: parse_time(c["posted_at"])
                  }

                  break if phrases.size >= limit
                end
              rescue Fetcher::Channels::Reddit::RateLimited => e
                Rails.logger.warn "[Research::Sentiment::Sources::Reddit] Rate limited no Reddit: #{e.message}"
                break
              rescue Fetcher::Channels::Reddit::PageFailed => e
                Rails.logger.warn "[Research::Sentiment::Sources::Reddit] Falha ao ler comentários da thread: #{e.message}"
                next
              end

              break if phrases.size >= limit
            end

            phrases
          rescue Fetcher::Channels::Reddit::Error => e
            Rails.logger.warn "[Research::Sentiment::Sources::Reddit] Erro no canal Reddit: #{e.message}"
            []
          end

          private

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
