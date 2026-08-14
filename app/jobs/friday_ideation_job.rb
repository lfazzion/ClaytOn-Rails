# frozen_string_literal: true

class FridayIdeationJob < ApplicationJob
  include DigestChannel

  queue_as :default

  def perform
    channel_id = ensure_digest_channel
    return unless channel_id

    message = build_ideation_digest
    DiscordMessageChunker.chunk(message).each do |chunk|
      DiscordApiClient.send_message(channel_id, chunk)
    end

    Rails.logger.info "[FridayIdeationJob] Digest de ideias enviado para canal #{channel_id}"
  rescue RuntimeError => e
    # ACHADO E (rodada 2, sol 13/08): canal obsoleto no cache de 30 dias.
    # Recupera (valida existência; 404 invalida o cache e re-resolve) e
    # reenvia UMA vez com o canal novo; outro erro propaga.
    if e.message.include?('404') || e.message.match?(/unknown channel/i)
      novo_channel = recover_digest_channel(channel_id)
      DiscordMessageChunker.chunk(message).each do |chunk|
        DiscordApiClient.send_message(novo_channel, chunk)
      end
    else
      raise
    end
  end

  private

  def build_ideation_digest
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

    popular_catalogs = ExternalCatalog.popular.limit(5)
    if popular_catalogs.any?
      lines << '**Catálogos populares recentes:**'
      popular_catalogs.each do |c|
        lines << "- **#{c.title}** (#{c.source}/#{c.media_type})"
      end
      lines << ''
    end

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

    lines << '**Sugestões de conteúdo:**'
    lines << response.content.to_s

    lines.join("\n")
  end
end
