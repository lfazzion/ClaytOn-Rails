# frozen_string_literal: true

class AlertThrottler
  ALERT_LIMIT = 10
  WINDOW = 1.hour

  class << self
    def throttle?(alert_type)
      return false if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = "alert_throttle:#{alert_type}"
      count = Rails.cache.read(key).to_i
      count >= ALERT_LIMIT
    end

    # Tenta reservar atomicamente uma cota de alerta para o tipo informado.
    # Inicializa a chave com write(until_exist) quando necessário, repete o
    # increment se outro processo venceu a inicialização, permite apenas
    # valores até ALERT_LIMIT. Retorna true se a reserva foi aceita, false se
    # o limite foi excedido.
    #
    # Quando o throttling está desabilitado (ENV["ALERT_THROTTLE_ENABLED"] !=
    # "true"), retorna true — a ausência de throttling significa que todas as
    # reservas são aceitas (sem controle de cota). Isso evita que o chamador
    # confunda "throttling desabilitado" com "cota excedida".
    def reserve(alert_type)
      return true if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = "alert_throttle:#{alert_type}"

      # Inicializa a chave atomicamente: se outro processo criou entre nós,
      # write com unless_exist falha e repetimos o increment.
      Rails.cache.write(key, 0, unless_exist: true, expires_in: WINDOW)
      count = Rails.cache.increment(key, 1)

      if count > ALERT_LIMIT
        # Reserva excedeu o limite: rollback da incrementação
        Rails.cache.decrement(key, 1)
        return false
      end

      true
    end

    # Libera uma reserva já aceita (usado quando o envio falha).
    def release(alert_type)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = "alert_throttle:#{alert_type}"
      Rails.cache.decrement(key, 1)
    end

    # Decrementa a contagem do contador (usado quando o envio falha e o
    # chamador prefere o modelo record/decrement em vez de reserve/release).
    # Mantido por compatibilidade com os achados R3-1/R3-7, que descreveram
    # record()/decrement() como incremento/decremento atômicos.
    def decrement(alert_type)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = "alert_throttle:#{alert_type}"
      Rails.cache.decrement(key, 1, expires_in: WINDOW)
    end

    def record(alert_type)
      return if ENV["ALERT_THROTTLE_ENABLED"] != "true"

      key = "alert_throttle:#{alert_type}"
      count = Rails.cache.increment(key, 1, expires_in: WINDOW)
      Rails.cache.write(key, 1, expires_in: WINDOW) if count.nil?
    end

    def reset(alert_type)
      key = "alert_throttle:#{alert_type}"
      Rails.cache.delete(key)
    end
  end
end
