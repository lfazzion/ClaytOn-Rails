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
#
# ── O LOG distingue os desfechos (ressalva R2 do PR #203) ────────────────────
# `resolve(force: true)` pode: descobrir e gravar de verdade; perder a corrida
# do lock porque OUTRO PROCESSO está buscando; buscar e não achar o query id
# (caindo no PIN); ou explodir. O job usava `resolve`, que devolvia só a
# String, e logava "refresh concluído" em TODOS esses casos: uma execução que
# não descobriu nada sumia do log como sucesso, e quem lê o log depois não tinha
# como saber que o cache não foi atualizado. Agora o job usa
# `resolve_with_outcome` e cada desfecho tem nível e texto próprios:
# `info` só quando descobriu de verdade; todo o resto é `warn`, dizendo o que
# aconteceu e qual valor ficou no cache.
class RefreshXQueryIdsJob < ApplicationJob
  queue_as :default

  OPERATION = "SearchTimeline".freeze

  def perform
    resolver = Fetcher::XQueryIdResolver.new
    result = resolver.resolve_with_outcome(OPERATION, force: true)
    report(result)
  rescue StandardError => e
    Rails.logger.warn "[RefreshXQueryIdsJob] falha ao refresh #{OPERATION}: #{e.class}: #{e.message}"
  end

  private

  # Um desfecho por linha de log. O padrão da casa: falha ou limite sempre
  # ditos, nunca fallback silencioso. Quem ler o log tem de responder "o cache
  # foi atualizado?" sem precisar de acesso ao código.
  def report(result)
    case result.reason
    when :discovered
      Rails.logger.info "[RefreshXQueryIdsJob] #{OPERATION} descoberto e gravado: #{result.value}"
    when :lock_busy
      # A ressalva que este card fecha: com `force: true` o caminho perde a
      # corrida de verdade. Isto NÃO é sucesso — outro processo está
      # descobrindo, e este worker não descobriu nada.
      Rails.logger.warn "[RefreshXQueryIdsJob] #{OPERATION} nao discoverta por este worker: " \
                       "outro processo esta descobrindo (lock ocupado); " \
                       "cache servido com #{result.value}"
    when :fetching_in_progress
      Rails.logger.warn "[RefreshXQueryIdsJob] #{OPERATION} nao descoberta por este worker: " \
                       "outro fetch desta instancia ja estava em andamento; " \
                       "cache servido com #{result.value}"
    when :not_found
      # Buscou e não achou: gravou o PIN de última instância. Anunciar isso
      # como "concluído" esconderia que o X mudou o formato dos bundles.
      Rails.logger.warn "[RefreshXQueryIdsJob] #{OPERATION} nao encontrada nos bundles apos a busca: " \
                       "gravado PIN de ultima instancia #{result.value}"
    when :stale_cache
      Rails.logger.warn "[RefreshXQueryIdsJob] #{OPERATION} servida de cache stale; " \
                       "refresh disparado em background; valor #{result.value}"
    when :fresh_cache
      Rails.logger.info "[RefreshXQueryIdsJob] #{OPERATION} ainda fresca no cache; " \
                        "nenhuma busca necessaria; valor #{result.value}"
    when :failed
      Rails.logger.warn "[RefreshXQueryIdsJob] falha ao refresh #{OPERATION}: " \
                       "#{result.error&.class}: #{result.error&.message}; " \
                       "preservado ultimo valor conhecido #{result.value}"
    else
      # Um motivo novo que ninguém mapeou é exatamente o tipo de coisa que o
      # padrão "nunca silencioso" proíbe deixar passar. Dizer, não engolir.
      Rails.logger.warn "[RefreshXQueryIdsJob] desfecho nao mapeado de #{OPERATION}: " \
                       "reason=#{result.reason.inspect} valor=#{result.value}"
    end
  end
end
