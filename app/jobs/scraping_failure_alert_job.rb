# frozen_string_literal: true

require_relative "../services/alert_throttler"

class ScrapingFailureAlertJob < ApplicationJob
  include AdminAlertChannel

  queue_as :critical

  def perform(scraper_name, profile_id, error_message, error_type)
    if AlertThrottler.throttle?(error_type)
      Rails.logger.warn "[ScrapingFailureAlertJob] Throttled: #{error_type}"
      return
    end

    channel_id = ensure_admin_channel
    unless channel_id
      Rails.logger.warn "[ScrapingFailureAlertJob] Canal admin não configurado"
      return
    end

    # reserve retorna:
    #   nil   -> throttling desabilitado (sem reserva; nada a liberar em falha)
    #   false -> cota excedida (aborta o envio, sem reserva)
    #   chave -> reserva aceita (liberar apenas se o envio falhar)
    reserved_key = AlertThrottler.reserve(error_type)
    if reserved_key == false
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
      raise
    end

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
