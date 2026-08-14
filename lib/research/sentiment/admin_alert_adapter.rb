# frozen_string_literal: true

require "date"

module Research
  module Sentiment
    # Adapter que expõe os métodos do concern AdminAlertChannel (de instância,
    # pensado para jobs) a contextos onde um job não existe — como o
    # Classifier, que é uma classe plana em lib/.
    #
    # O `include AdminAlertChannel if defined?(AdminAlertChannel)` no Classifier
    # não é confiável: o concern mora em app/jobs/concerns/ e pode não estar
    # autoloadado na definição de classe do Classifier, fazendo com que o
    # include seja pulado e o envio real nunca aconteça. Este adapter garante
    # o include de forma explícita e centraliza o envio para DiscordApiClient.
    class AdminAlertAdapter
      include AdminAlertChannel

      def initialize(run = nil)
        @run = run
      end

      # Envia um alerta de falha para o canal admin via DiscordApiClient.
      # Retorna true se a mensagem foi enviada, false caso contrário.
      def alert(msg)
        channel_id = ensure_admin_channel
        return false unless channel_id.present?

        DiscordMessageChunker.chunk(msg).each do |chunk|
          DiscordApiClient.send_message(channel_id, chunk)
        end
        true
      rescue StandardError => e
        Rails.logger.error "[Research::Sentiment::AdminAlertAdapter] Erro ao enviar alerta admin: #{e.message}"
        false
      end
    end
  end
end
