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
        # ── ACHADO A (P1, sol 13/08 + rodada 2) ──
        # Quando o backend é SolidCache (produção), o unlock é ATÔMICO via
        # lock_and_write (FOR UPDATE): verifica o token sob lock e deleta na
        # mesma operação — sem a janela read→delete. Para outros stores
        # (teste FileStore) fica o compare-delete com janela mínima, que é o
        # melhor possível sem CAS.
        release_pacer_lock(lock_key, token)
      end
    end

    # Unlock distribuído do FetchPacer: só remove se ainda for o nosso token.
    def self.release_pacer_lock(lock_key, token)
      if Rails.cache.is_a?(SolidCache::Store)
        normalized = Rails.cache.send(:normalize_key, lock_key, nil)
        SolidCache::Entry.lock_and_write(normalized) do |raw|
          if raw && Rails.cache.send(:deserialize_entry, raw)&.value.to_s == token.to_s
            SolidCache::Entry.delete_by_key(normalized)
          end
          # IMPORTANTE (sol rodada 3, 13/08): bloco DEVE retornar nil — o
          # lock_and_write reescreve o valor quando truthy, e delete_by_key
          # retorna o count (Integer) — sem o nil, o lock seria recriado com
          # o inteiro em vez de liberado (verificado na gem 1.0.10).
          nil
        end
      else
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
      # ACHADO G (P3, sol 13/08): LOCK_TTL (30) é o PISO do TTL do lock — garante
      # que o lock nunca expire em menos de 30s, independentemente de range.max
      # (inclusive range vazio / range.max = 0). range.max + margem só eleva o
      # TTL acima do piso quando o intervalo de pacing é maior que 30s.
      interval_max = range.respond_to?(:max) ? (range.max || 0) : 0
      [interval_max, LOCK_TTL].max + LOCK_TTL_MARGIN
    end
  end
end
