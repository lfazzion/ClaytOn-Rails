# frozen_string_literal: true

# Mantém o query ID do X (Twitter) atualizado para SearchTimeline.
#
# O resolver (`Fetcher::XQueryIdResolver`) já implementa:
# - Cache persistente com soft-TTL de 24h
# - Lock de concorrência (um só processo descobre por operação)
# - Preservação do último valor em falha (retorna PIN em última instância)
# - Refresh assíncrono quando cache estiver stale (sem bloquear a chamada)
#
# Este job apenas dispara o refresh proativo a cada 6h, garantindo que o
# query ID não venha obsoleto caso nenhuma solicitação tenha forçado a
# atualização durante o dia.
class RefreshXQueryIdsJob < ApplicationJob
  queue_as :default

  OPERATION = "SearchTimeline".freeze

  def perform
    resolver = Fetcher::XQueryIdResolver.new
    resolver.resolve(OPERATION, force: true)
    Rails.logger.info "[RefreshXQueryIdsJob] refresh de #{OPERATION} concluído"
  rescue StandardError => e
    Rails.logger.warn "[RefreshXQueryIdsJob] falha ao refresh #{OPERATION}: #{e.class}: #{e.message}"
  end
end
