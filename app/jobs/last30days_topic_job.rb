# frozen_string_literal: true

require_relative "../services/last30days/message_builder"
require_relative "../../lib/research/scorer"
require_relative "../../lib/research/fusion"
require_relative "../../lib/research/cluster"
require_relative "../../lib/fetcher/channels/hackernews"
require_relative "../../lib/fetcher/channels/github"
require_relative "../../lib/fetcher/channels/polymarket"

class Last30DaysTopicJob < ApplicationJob

  queue_as :default

  # channel_id é resolvido UMA vez pelo Last30DaysDigestJob e passado como argumento
  # (Achado 8). Pode ser nil se não houver canal configurado.
  def perform(topic_id, channel_id)
    topic = Topic.find(topic_id)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.info "[Last30DaysTopicJob] Tópico #{topic_id} não encontrado"
    return { sent: false }
  else
    process_topic(topic, channel_id)
  end

  private

  def process_topic(topic, channel_id)
    # Achado 6: resolver channel_id ANTES de qualquer gravação.
    # Se nil → não há como entregar; abortar sem gravar nada.
    if channel_id.nil?
      Rails.logger.info "[Last30DaysTopicJob] Sem canal configurado para tópico #{topic.name}, abortando"
      return { topic_id: topic.id, clusters: [], sent: false }
    end

    hn_items = fetch_source("hackernews") { Fetcher::Channels::Hackernews.search(query: topic.name, limit: 10) }
    gh_items = fetch_source("github") { Fetcher::Channels::Github.search(query: topic.name, limit: 10) }
    pm_items = fetch_source("polymarket") { Fetcher::Channels::Polymarket.search(query: topic.name, limit: 10) }

    hn_sorted = hn_items.present? ? Research::Scorer.sort(hn_items, query: topic.name) : []
    gh_sorted = gh_items.present? ? Research::Scorer.sort(gh_items, query: topic.name) : []
    pm_sorted = pm_items.present? ? Research::Scorer.sort(pm_items, query: topic.name) : []

    streams = {
      "hackernews" => hn_sorted,
      "github" => gh_sorted,
      "polymarket" => pm_sorted
    }

    candidates = Research::Fusion.fuse(streams: streams, pool_limit: 30)
    if candidates.empty?
      Rails.logger.info "[Last30DaysTopicJob] Nenhum candidato encontrado para tópico #{topic.name}"
      return { topic_id: topic.id, clusters: [], sent: false }
    end

    clusters = Research::Cluster.cluster(candidates, intent: "opinion")

    recent_keys = TopicDelivery.where(topic_id: topic.id)
                               .where("sent_at >= ?", 7.days.ago)
                               .pluck(:url_key)
                               .to_set

    filtered_clusters = clusters.filter_map do |cluster|
      items = Array(cluster["items"])
      new_items = items.reject do |item|
        uk = extract_url_key(item)
        recent_keys.include?(uk)
      end

      next nil if new_items.empty?

      cluster.merge("items" => new_items)
    end

    if filtered_clusters.empty?
      Rails.logger.info "[Last30DaysTopicJob] Todos os itens para tópico #{topic.name} foram deduplicados"
      return { topic_id: topic.id, clusters: [], sent: false }
    end

    # Achado 4: montar a mensagem PRIMEIRO para saber quais keys foram realmente
    # renderizadas (limitadas por MAX_CLUSTERS × MAX_ITEMS_PER_CLUSTER).
    # Só então gravar as TopicDelivery dos itens que aparecem na mensagem.
    result = Last30Days::MessageBuilder.build(clusters: filtered_clusters, topic_name: topic.name)
    message = result[:text]
    rendered_keys = result[:url_keys]

    # Achado 5: find_or_initialize_by + save! — atualiza sent_at SEMPRE,
    # não só no create (find_or_create_by! só executa o bloco no create).
    now = Time.current
    rendered_keys.each do |uk|
      td = TopicDelivery.find_or_initialize_by(topic_id: topic.id, url_key: uk)
      td.sent_at = now
      td.save!
    rescue ActiveRecord::RecordNotUnique
      # Concorrência: outro worker gravou antes; tenta atualizar
      TopicDelivery.where(topic_id: topic.id, url_key: uk).update_all(sent_at: now)
    end

    send_message_chunks(channel_id, message)
    Rails.logger.info "[Last30DaysTopicJob] Digest do tópico #{topic.name} enviado para canal #{channel_id}"

    { topic_id: topic.id, clusters: filtered_clusters, sent: true }
  end

  def fetch_source(name)
    yield || []
  rescue StandardError => e
    Rails.logger.error "[Last30DaysTopicJob] Erro na fonte #{name}: #{e.class} - #{e.message}"
    []
  end

  def extract_url_key(item)
    raw_url = item["url"].presence || item["key"].to_s
    Research::Fusion.normalize_url(raw_url)
  end

  def send_message_chunks(channel_id, message)
    if message.length <= 2000
      DiscordApiClient.send_message(channel_id, message)
    else
      chunks = chunk_text(message, limit: 1900)
      chunks.each do |chunk|
        DiscordApiClient.send_message(channel_id, chunk)
      end
    end
  end

  def chunk_text(text, limit: 1900)
    lines = text.split("\n")
    chunks = []
    current_chunk = []
    current_length = 0

    lines.each do |line|
      line_len = line.length + 1
      if current_length + line_len > limit && current_chunk.any?
        chunks << current_chunk.join("\n")
        current_chunk = [line]
        current_length = line_len
      else
        current_chunk << line
        current_length += line_len
      end
    end

    chunks << current_chunk.join("\n") if current_chunk.any?
    chunks
  end
end
