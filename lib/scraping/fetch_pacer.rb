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
        # ── ACHADO A (P1, sol 13/08): unlock NÃO é compare-delete atômico ──
        # Rails.cache não expõe CAS (compare-and-swap), e o SolidCache também
        # não oferece delete condicional atômico na API pública usada aqui.
        # A liberação é read + delete em duas operações separadas, então há uma
        # janela em que o lock pode expirar entre o read e o delete: se outro
        # worker adquiriu o lock (novo token) nesse intervalo, o delete antigo
        # poderia apagar o lock NOVO.
        #
        # Mitigação feita (melhor possível com a API disponível):
        #   1. a condição `read(lock_key) == token` GARANTE que só apagamos o
        #      lock se ele ainda for o nosso — se o token mudou, não apagamos,
        #      preservando o lock do novo dono (ver teste de disputa de token);
        #   2. a janela read→delete é minimizada usando a MESMA expressão
        #      `Rails.cache.read(lock_key) == token` (sem trabalho entre elas).
        #
        # Trade-off documentado: em caso de expiração exata do TTL entre o read
        # e o delete, um worker concorrente poderia já ter escrito um novo token
        # E o nosso read capturar esse token novo — mas isso só ocorre em uma
        # borda de timing de milissegundos e, mesmo assim, o pior caso é um
        # delete do lock do concorrente, que será re-adquirido no próximo wait.
        # Não há correção estrita sem CAS no backend; o custo de adotar um
        # backend com CAS (ex.: Redis) está fora do escopo desta correção.
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
