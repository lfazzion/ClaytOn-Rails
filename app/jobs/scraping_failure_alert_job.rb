# frozen_string_literal: true

require_relative "../services/alert_throttler"

class ScrapingFailureAlertJob < ApplicationJob
  include AdminAlertChannel

  queue_as :critical

  def perform(scraper_name, profile_id, error_message, error_type)
    # Deduplicação por transição de estado: alerta apenas no 1º incidente,
    # em mudança de erro/fingerprint, ou após recuperação.
    incident_reserved = AlertThrottler.reserve_incident(scraper_name, profile_id, error_type, error_message)
    unless incident_reserved
      Rails.logger.info "[ScrapingFailureAlertJob] Incidente repetido ou em andamento para #{scraper_name}/#{profile_id}: #{error_type}"
      return
    end

    channel_id = ensure_admin_channel
    unless channel_id
      AlertThrottler.release_incident(scraper_name, profile_id)
      Rails.logger.warn "[ScrapingFailureAlertJob] Canal admin não configurado"
      return
    end

    # reserve retorna:
    #   nil   -> throttling desabilitado (sem reserva; nada a liberar em falha)
    #   false -> cota excedida (aborta o envio, sem reserva)
    #   chave -> reserva aceita (liberar apenas se o envio falhar)
    reserved_key = AlertThrottler.reserve(error_type)
    if reserved_key == false
      AlertThrottler.release_incident(scraper_name, profile_id)
      Rails.logger.warn "[ScrapingFailureAlertJob] Quota excedida: #{error_type}"
      return
    end

    message = build_alert_message(scraper_name, profile_id, error_message, error_type)

    # ACHADO A (13/08): apenas falhas NO envio liberam a reserva. O log
    # pós-envio fica FORA do rescue, então uma falha nele não libera a reserva
    # do alerta já entregue — caso contrário um retry reenviaria o alerta.
    begin
      DiscordApiClient.send_message(channel_id, message)
    rescue StandardError
      AlertThrottler.release(error_type, key: reserved_key) if reserved_key.is_a?(String)
      AlertThrottler.release_incident(scraper_name, profile_id)
      raise
    end

    # Consolida o incidente como entregue com sucesso apenas após o envio
    AlertThrottler.consolidate_incident(scraper_name, profile_id, error_type, error_message)

    Rails.logger.info "[ScrapingFailureAlertJob] Alerta enviado para #{scraper_name}/#{profile_id}"
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
