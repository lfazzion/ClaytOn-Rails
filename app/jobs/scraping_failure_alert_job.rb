# frozen_string_literal: true

require_relative "../services/alert_throttler"

class ScrapingFailureAlertJob < ApplicationJob
  include AdminAlertChannel

  queue_as :critical
  def perform(scraper_name, profile_id, error_message, error_type)
    reserved_key = nil

    if AlertThrottler.throttle?(error_type)
      Rails.logger.warn "[ScrapingFailureAlertJob] Throttled: #{error_type}"
      return
    end

    channel_id = ensure_admin_channel
    unless channel_id
      Rails.logger.warn "[ScrapingFailureAlertJob] Canal admin não configurado"
      return
    end

    if (reserved_key = AlertThrottler.reserve(error_type))
      # reserved_key é a chave da janela reservada (retorno truthy)
    else
      Rails.logger.warn "[ScrapingFailureAlertJob] Quota excedida: #{error_type}"
      return
    end

    message = build_alert_message(scraper_name, profile_id, error_message, error_type)
    DiscordApiClient.send_message(channel_id, message)

    Rails.logger.info "[ScrapingFailureAlertJob] Alerta enviado para #{scraper_name}/#{profile_id}"
  rescue StandardError
    # Em caso de falha no envio, libera a reserva somente se ela foi efetivamente aceita.
    AlertThrottler.release(error_type, key: reserved_key) if reserved_key
    raise
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
