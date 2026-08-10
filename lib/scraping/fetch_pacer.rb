# frozen_string_literal: true

module Scraping
  class FetchPacer
    def self.wait(host, range: 8..20)
      cache_key = "fetch_pacer:#{host}"
      last_fetch = Rails.cache.read(cache_key)
      now = Time.now.to_f

      if last_fetch.nil?
        Rails.cache.write(cache_key, now)
        return
      end

      elapsed = now - last_fetch.to_f
      interval = rand(range)

      if elapsed >= interval
        Rails.cache.write(cache_key, now)
      else
        to_sleep = interval - elapsed
        pacer_sleep(to_sleep)
        Rails.cache.write(cache_key, Time.now.to_f)
      end
    end

    def self.pacer_sleep(duration)
      sleep(duration)
    end
  end
end
