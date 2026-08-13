# frozen_string_literal: true

module Scraping
  class FetchPacer
    class LockTimeoutError < StandardError; end

    LOCK_TTL = 30
    # Margem sobre o maior intervalo de `range`: garante que o lock não expire
    # durante o pacing mesmo quando `range` produz uma espera > LOCK_TTL
    # (ex.: range: 31..31 dorme 31s). Ver ACHADO 2 (P2) da campanha laguna-fix.
    LOCK_TTL_MARGIN = 5
    WAIT_TIMEOUT = 30.0

    def self.wait(host, range: 8..20, timeout: WAIT_TIMEOUT)
      cache_key = "fetch_pacer:#{host}"
      lock_key = "fetch_pacer:lock:#{host}"
      token = SecureRandom.hex(8)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      acquired = false
      loop do
        if Rails.cache.write(lock_key, token, unless_exist: true, expires_in: lock_ttl(range: range))
          acquired = true
          break
        end

        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.05)
      end

      unless acquired
        raise LockTimeoutError, "Could not acquire fetch lock for #{host} within #{timeout}s"
      end

      begin
        now = Time.now.to_f
        last_fetch = Rails.cache.read(cache_key)
        sleep_duration = 0

        unless last_fetch.nil?
          elapsed = now - last_fetch.to_f
          interval = rand(range)
          if elapsed < interval
            sleep_duration = interval - elapsed
          end
        end

        pacer_sleep(sleep_duration) if sleep_duration > 0
        Rails.cache.write(cache_key, Time.now.to_f)
      ensure
        Rails.cache.delete(lock_key) if Rails.cache.read(lock_key) == token
      end
    end

    def self.pacer_sleep(duration)
      sleep(duration)
    end

    # TTL do lock dimensionado para cobrir o maior intervalo possível de `range`
    # mais uma margem operacional, evitando que o lock expire durante o pacing
    # quando `range` produz uma espera > LOCK_TTL (ACHADO 2 / P2).
    def self.lock_ttl(range:)
      interval_max = range.respond_to?(:max) ? (range.max || 0) : 0
      [interval_max, 0].max + LOCK_TTL_MARGIN
    end
  end
end
