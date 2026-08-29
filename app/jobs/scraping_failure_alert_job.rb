# frozen_string_literal: true

require_relative "../services/alert_throttler"

class ScrapingFailureAlertJob < ApplicationJob
  include AdminAlertChannel

  queue_as :critical

  def perform(scraper_name, profile_id, error_message, error_type)
    # Deduplicação por transição de estado: alerta apenas no 1º incidente,
    # em mudança de erro/fingerprint, ou após recuperação.
    incident_token = AlertThrottler.reserve_incident(scraper_name, profile_id, error_type, error_message)
    unless incident_token
      Rails.logger.info "[ScrapingFailureAlertJob] Incidente repetido ou em andamento para #{scraper_name}/#{profile_id}: #{error_type}"
      return
    end

    reserved_key = nil
    delivered = false

    begin
      channel_id = ensure_admin_channel
      unless channel_id
        AlertThrottler.release_incident(scraper_name, profile_id, token: incident_token)
        Rails.logger.warn "[ScrapingFailureAlertJob] Canal admin não configurado"
        return
      end

      # reserve retorna:
      #   nil   -> throttling desabilitado (sem reserva; nada a liberar em falha)
      #   false -> cota excedida (aborta o envio, sem reserva)
      #   chave -> reserva aceita (liberar apenas se o envio falhar)
      reserved_key = AlertThrottler.reserve(error_type)
      if reserved_key == false
        AlertThrottler.release_incident(scraper_name, profile_id, token: incident_token)
        Rails.logger.warn "[ScrapingFailureAlertJob] Quota excedida: #{error_type}"
        return
      end

      message = build_alert_message(scraper_name, profile_id, error_message, error_type)

      # Envio ao Discord: apenas falhas anteriores ou durante o envio liberam a cota horária
      DiscordApiClient.send_message(channel_id, message)
      delivered = true

      # Consolida o incidente como entregue com sucesso após o envio
      AlertThrottler.consolidate_incident(scraper_name, profile_id, error_type, error_message, token: incident_token)

      Rails.logger.info "[ScrapingFailureAlertJob] Alerta enviado para #{scraper_name}/#{profile_id}"
    rescue StandardError => e
      if delivered
        # Política explícita pós-envio: A mensagem já foi aceita pelo Discord, portanto a cota horária
        # NÃO é devolvida e nenhum retry cego deve re-enviar.
        # Liberamos o lock do proprietário para evitar que jobs futuros fiquem bloqueados.
        # Risco residual: sem outbox transacional entre Discord e Cache, a não persistência do estado
        # pode gerar alerta duplicado no próximo ciclo de erro.
        AlertThrottler.release_incident(scraper_name, profile_id, token: incident_token) rescue nil
        Rails.logger.error "[ScrapingFailureAlertJob] Erro pós-envio ao consolidar incidente para #{scraper_name}/#{profile_id}: #{e.message}"
      else
        # Falhas anteriores à entrega: rollback da cota horária (se reservada) e liberação do lock
        AlertThrottler.release(error_type, key: reserved_key) if reserved_key.is_a?(String)
        AlertThrottler.release_incident(scraper_name, profile_id, token: incident_token)
      end
      raise
    end
  end

  private

  def build_alert_message(scraper_name, profile_id, error_message, error_type)
    timestamp = Time.current.in_time_zone("America/Sao_Paulo").strftime("%Y-%m-%d %H:%M:%S")
    <<~MSG
      🚨 **Alerta de Falha de Scraping**
      ```
      Plataforma: #{scraper_name}
      Perfil ID:   #{profile_id}
      Tipo Erro:   #{error_type}
      Mensagem:    #{error_message[0..200]}
      Timestamp:   #{timestamp}
      ```
    MSG
  end
end
