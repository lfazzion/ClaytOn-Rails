# frozen_string_literal: true

class FridayIdeationJob < ApplicationJob
  include DigestChannel

  queue_as :default

  # C2a (campanha 1409, veredito perito seção C2 — S2-01/S2-04): política
  # declarada de "novidade". O mesmo item NUNCA repete no mesmo
  # digest_type + canal (estado em DigestItemDelivery, tabela própria — nunca
  # em ExternalCatalog). A seleção é por janela de recência crescente:
  #   30d → 60d → 90d (teto). Esgotado o teto sem novidade, o bloco exibe um
  #   aviso explícito de que não há novidade — nunca repetição em silêncio.
  #
  # DECISÃO DE POLÍTICA (fallback): a ampliação de janela (30→60→90) e o
  #   aviso são a política documentada pelo veredito do perito; se o dono
  #   preferir outra (ex. avisar antes de ampliar, ou teto de N semanas),
  #   RECENT_WINDOWS e NO_NOVELTY_NOTICE são os únicos pontos a mudar.
  DIGEST_TYPE = 'friday_ideation'.freeze
  RECENT_WINDOWS = [30, 60, 90].freeze
  CATALOG_BLOCK_LIMIT = 5
  NO_NOVELTY_NOTICE = '- Sem novidade esta semana: os catálogos populares recentes deste canal já foram mostrados. Novos destaques entram quando houver itens novos no catálogo.'

  def perform
    channel_id = ensure_digest_channel
    return unless channel_id

    catalog_items = select_recent_catalog_items(channel_id)
    message = build_ideation_digest(catalog_items)
    chunks = DiscordMessageChunker.chunk(message)
    begin
      chunks.each do |chunk|
        DiscordApiClient.send_message(channel_id, chunk)
      end
      # C2a: registra a entrega SÓ no caminho feliz — DEPOIS de todos os
      # chunks terem saído bem. Se um chunk 404 (canal obsoleto) ou outro
      # erro interromper o envio, a exception cai no rescue e o registro
      # NÃO roda: os itens permanecem "não enviados" e a próxima execução
      # (já com o canal recuperado) tenta novamente. Marcar antes do envio
      # trocava repetição por perda silenciosa (veredito perito, risco C2).
      record_catalog_delivery(channel_id, catalog_items)
    rescue RuntimeError => e
      # ACHADO E (rodada 2, sol 13/08): canal obsoleto no cache de 30 dias.
      # Rodada 3 (sol 13/08): se um chunk POSTERIOR falhar com 404, reenviar
      # do início duplicaria os já entregues — só o canal é recuperado e o
      # ENVIO não é repetido (o job encerra; o próximo ciclo reenvia tudo
      # com o canal novo e o Discord deduplica/encadeia).
      if e.message.include?('404') || e.message.match?(/unknown channel/i)
        recover_digest_channel(channel_id)
        Rails.logger.warn "[FridayIdeationJob] Canal #{channel_id} inválido (404); cache invalidado. Mensagem NÃO reenviada nem registrada nesta execução para evitar duplicação/perda silenciosa."
      else
        raise
      end
    end
    Rails.logger.info "[FridayIdeationJob] Digest de ideias enviado para canal #{channel_id} (#{catalog_items.size} catálogos populares recentes)"
  end

  private

  # C2a: seleção de novidade. Exclui itens já enviados para este digest+canal
  # e varre janelas de recência crescentes (30→60→90d). Retorna os itens a
  # incluir no bloco (limite CATALOG_BLOCK_LIMIT). Vazio = todas as janelas
  # esgotadas (fallback: aviso explícito no digest, ver build_ideation_digest).
  def select_recent_catalog_items(channel_id)
    already_sent = DigestItemDelivery.sent_item_keys(digest_type: DIGEST_TYPE, channel_id: channel_id)
    RECENT_WINDOWS.each do |days|
      items = ExternalCatalog.recent_popular(days: days, exclude_keys: already_sent).limit(CATALOG_BLOCK_LIMIT).to_a
      return items if items.any?
    end
    []
  end

  # C2a: estado de envio em tabela própria (DigestItemDelivery), gravado
  # após o envio ter saído bem. A marca é (digest_type, channel, item_key)
  # — idempotente pelo índice único; duas execuções concorrentes do mesmo
  # digest+canal não duplicam (a segunda criação é recusada).
  def record_catalog_delivery(channel_id, items)
    return if items.empty?

    now = Time.current
    items.each do |item|
      DigestItemDelivery.mark_sent!(digest_type: DIGEST_TYPE, channel_id: channel_id,
                                    item_type: DigestItemDelivery::ITEM_TYPE_CATALOG,
                                    item_key: item.key, sent_at: now)
    end
  end

  def build_ideation_digest(catalog_items)
    lines = ["**💡 Ideias da Semana — #{Date.current.strftime('%d/%m/%Y')}**"]
    lines << ''

    upcoming_events = Event.upcoming.where('start_date <= ?', 7.days.from_now).limit(5)
    if upcoming_events.any?
      lines << '**Eventos da próxima semana:**'
      upcoming_events.each do |e|
        lines << "- **#{e.title}** (#{e.event_type}) — #{e.start_date&.strftime('%d/%m')}"
      end
      lines << ''
    end

    if catalog_items.any?
      lines << '**Catálogos populares recentes:**'
      catalog_items.each do |c|
        lines << "- **#{c.title}** (#{c.source}/#{c.media_type})"
      end
    else
      # C2a: fallback declarado — sem novidade dentro do teto de janela
      # (90d). Aviso explícito: nunca repete item já enviado em silêncio.
      lines << '**Catálogos populares recentes:**'
      lines << NO_NOVELTY_NOTICE
    end
    lines << ''

    recent_articles = NewsArticle.recent(7).limit(5)
    if recent_articles.any?
      lines << '**Artigos recentes:**'
      recent_articles.each do |a|
        lines << "- **#{a.title}** — #{a.source}"
      end
      lines << ''
    end

    prompt = Llm::PromptLoader.load('ideation_digest', context: lines.join("\n"))
    response = AiRouter.complete(prompt, context: :background)

    formatted_suggestions = IdeationResponseFormatter.format(response.content)
    if formatted_suggestions.present?
      lines << '**Sugestões de conteúdo:**'
      lines << formatted_suggestions
    end

    lines.join("\n")
  end
end