# frozen_string_literal: true

class AlertThrottler
  ALERT_LIMIT = 10
  WINDOW = 1.hour

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
    # ACHADO B (13/08): só decrementa se a chave existe e o valor é > 0,
    # evitando recriar a chave com -1 (ex.: release duplicado num retry após já
    # ter liberado).
    def release(alert_type, key: nil)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      chave = key || current_key(alert_type)
      current = Rails.cache.read(chave)
      return if current.nil? || current.to_i <= 0

      Rails.cache.decrement(chave, 1)
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

    private

    # Chave que inclui o bucket temporal (hora atual) para isolar janelas.
    # O rollback/release/decrement só afetam a janela em que a reserva foi feita.
    def current_key(alert_type)
      bucket = Time.current.to_i / WINDOW.to_i
      "alert_throttle:#{alert_type}:#{bucket}"
    end
  end
end
