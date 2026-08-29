# frozen_string_literal: true

class AlertThrottler
  ALERT_LIMIT = 10
  WINDOW = 1.hour
  INCIDENT_PREFIX = "scraping_incident"
  INCIDENT_TTL = 30.days

  class << self
    def throttle?(alert_type)
      return false if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = current_key(alert_type)
      count = Rails.cache.read(key).to_i
      count >= ALERT_LIMIT
    end

    # Tenta reservar atomicamente uma cota de alerta para o tipo informado.
    # Inicializa a chave com write(until_exist) quando necessário, repete o
    # increment se outro processo venceu a inicialização, permite apenas
    # valores até ALERT_LIMIT. Retorna a CHAVE da janela reservada (String
    # truthy) se a reserva foi aceita, false se o limite foi excedido, ou nil
    # quando o throttling está desabilitado (sem reserva a liberar).
    def reserve(alert_type)
      return nil if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = current_key(alert_type)

      # Inicializa a chave atomicamente: se outro processo criou entre nós,
      # write com unless_exist falha e repetimos o increment.
      Rails.cache.write(key, 0, unless_exist: true, expires_in: WINDOW)
      count = Rails.cache.increment(key, 1)

      if count > ALERT_LIMIT
        # Reserva excedeu o limite: rollback da incrementação na MESMA janela
        Rails.cache.decrement(key, 1)
        return false
      end

      # Retorna a CHAVE da reserva (truthy): o release precisa liberar exatamente
      # esta janela, não a do horário atual — se a hora virar entre reserve e
      # release, recalcular decrementaria o bucket novo e corromperia a cota
      # (achado P1 do sol, 13/08).
      key
    end

    # Libera uma reserva já aceita (usado quando o envio falha). Recebe a chave
    # devolvida por reserve; sem chave, recalcula (compatibilidade).
    # ACHADO B (13/08) + rodadas 2-4 (sol): o read→condição→decrement era
    # TOCTOU. Rodada 4: aplicado o padrão aceito nos outros locks —
    # SolidCache::Entry.lock_and_write (FOR UPDATE) com retorno nil quando o
    # decremento acontece (se a chave não existe, bloco retorna nil e nada é
    # gravado); fallback compare-delete para FileStore (testes). Contador
    # nunca persiste negativo.
    def release(alert_type, key: nil)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      chave = key || current_key(alert_type)

      if Rails.cache.is_a?(SolidCache::Store)
        normalized = Rails.cache.send(:normalize_key, chave, nil)
        SolidCache::Entry.lock_and_write(normalized) do |raw|
          next nil unless raw

          valor = Rails.cache.send(:deserialize_entry, raw)&.value
          next nil unless valor.is_a?(Numeric) && valor > 0

          novo = valor - 1
          novo = 0 if novo < 0

          Rails.cache.send(
            :serialize_entry,
            ActiveSupport::Cache::Entry.new(novo, expires_in: WINDOW)
          )
        end
      else
        Rails.cache.delete(chave) if Rails.cache.read(chave).to_i <= 0
        return unless Rails.cache.exist?(chave)

        novo = Rails.cache.decrement(chave, 1, expires_in: WINDOW)
        Rails.cache.write(chave, 0, expires_in: WINDOW) if novo && novo < 0
      end
    end

    # Decrementa a contagem do contador (usado quando o envio falha e o
    # chamador prefere o modelo record/decrement em vez de reserve/release).
    # Mantido por compatibilidade com os achados R3-1/R3-7, que descreveram
    # record()/decrement() como incremento/decremento atômicos.
    def decrement(alert_type)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = current_key(alert_type)
      Rails.cache.decrement(key, 1, expires_in: WINDOW)
    end

    # ACHADO C (13/08): o increment+write quando nil NÃO é atômico (dois
    # processos podem ler nil e ambos escrever 1, perdendo uma contagem).
    # Correção: inicializar com write(unless_exist) ANTES do increment, como
    # reserva da chave, para garantir que o increment sempre atue sobre uma
    # chave existente.
    def record(alert_type)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = current_key(alert_type)
      Rails.cache.write(key, 0, unless_exist: true, expires_in: WINDOW)
      count = Rails.cache.increment(key, 1, expires_in: WINDOW)
      Rails.cache.write(key, 1, expires_in: WINDOW) if count.nil?
    end

    def reset(alert_type)
      key = current_key(alert_type)
      Rails.cache.delete(key)
    end

    # --- Deduplicação por transição de incidente (Frente C) ---

    def incident_key(scraper_name, profile_id)
      "#{INCIDENT_PREFIX}:#{scraper_name}:#{profile_id}"
    end

    def incident_lock_key(scraper_name, profile_id)
      "#{INCIDENT_PREFIX}_lock:#{scraper_name}:#{profile_id}"
    end

    # Normaliza a mensagem de erro para que variações não essenciais (timestamps,
    # datas, ponteiros hex, UUIDs) gerem o mesmo fingerprint estável.
    def normalize_fingerprint(message)
      return "" if message.nil?

      msg = message.to_s.dup
      # Remove timestamps ISO/SQL completos (ex: 2026-08-29 09:00:00, 2026-08-29T09:00:00Z)
      msg.gsub!(/\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/, "")
      # Remove datas simples (ex: 2026-08-29)
      msg.gsub!(/\b\d{4}-\d{2}-\d{2}\b/, "")
      # Remove endereços hex/ponteiros de objetos (ex: 0x00007f9b8c012348)
      msg.gsub!(/\b0x[0-9a-fA-F]+\b/, "")
      # Remove UUIDs
      msg.gsub!(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/, "")
      # Colapsa múltiplos espaços e remove bordas
      msg.strip.gsub(/\s+/, " ")
    end

    # Retorna o estado atual do incidente persistido no cache ou nil se nenhum.
    def incident_state(scraper_name, profile_id)
      key = incident_key(scraper_name, profile_id)
      val = Rails.cache.read(key)
      return nil unless val.is_a?(Hash)

      {
        error_type: (val[:error_type] || val["error_type"]).to_s,
        fingerprint: (val[:fingerprint] || val["fingerprint"]).to_s
      }
    end

    # Verifica se há transição de estado que justifique envio de alerta:
    # - Primeiro incidente (sem estado anterior)
    # - Mudança de error_type ou fingerprint
    # - Retorna false quando for repetição idêntica do mesmo erro
    def transition?(scraper_name, profile_id, error_type, error_message)
      state = incident_state(scraper_name, profile_id)
      return true if state.nil?

      fp = normalize_fingerprint(error_message)
      state[:error_type] != error_type.to_s || state[:fingerprint] != fp
    end

    # Tenta reservar atomicamente o envio para uma transição de incidente.
    # Usa lock atômico no cache para garantir que no máximo um job envie
    # em cenários de concorrência.
    def reserve_incident(scraper_name, profile_id, error_type, error_message)
      return false unless transition?(scraper_name, profile_id, error_type, error_message)

      lock = incident_lock_key(scraper_name, profile_id)
      acquired = Rails.cache.write(lock, "1", unless_exist: true, expires_in: 5.minutes)
      return false unless acquired

      # Re-checa após adquirir lock para evitar race condition TOCTOU
      unless transition?(scraper_name, profile_id, error_type, error_message)
        release_incident(scraper_name, profile_id)
        return false
      end

      true
    end

    # Libera o lock de processamento do incidente (usado em falha de envio ou abort)
    def release_incident(scraper_name, profile_id)
      lock = incident_lock_key(scraper_name, profile_id)
      Rails.cache.delete(lock)
    end

    # Consolida o incidente como entregue com sucesso e libera o lock.
    def consolidate_incident(scraper_name, profile_id, error_type, error_message)
      fp = normalize_fingerprint(error_message)
      data = { error_type: error_type.to_s, fingerprint: fp }
      Rails.cache.write(incident_key(scraper_name, profile_id), data, expires_in: INCIDENT_TTL)
      release_incident(scraper_name, profile_id)
    end

    # Resolve o incidente quando a coleta for bem-sucedida (limpa chave).
    def resolve_incident(scraper_name, profile_id)
      Rails.cache.delete(incident_key(scraper_name, profile_id))
      release_incident(scraper_name, profile_id)
    end

    private

    # Chave que inclui o bucket temporal (hora atual) para isolar janelas.
    # O rollback/release/decrement só afetam a janela em que a reserva foi feita.
    def current_key(alert_type)
      bucket = Time.current.to_i / WINDOW.to_i
      "alert_throttle:#{alert_type}:#{bucket}"
    end
  end
end
