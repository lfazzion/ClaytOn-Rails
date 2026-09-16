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

  # C2c: digest_type PRÓPRIO — a supressão é por (digest_type, canal), e
  # "friday_ideation" é o estado do digest semanal do FridayIdeationJob;
  # reutilizá-lo faria um digest silenciar o outro (a entrega de um não
  # pode apagar a de outro). O mesmo item pode circular nos dois sem que
  # um iniba o outro.
  DIGEST_TYPE = "last30days_topic".freeze

  # C2c: item_type próprio — a mesma item_key registrada por outro contrato
  # (ex.: ITEM_TYPE_CATALOG do friday) não suprime este digest.
  ITEM_TYPE = "last30days_topic_item".freeze

  # C2c: serializa uma execução por TÓPICO no worker do Solid Queue —
  # mesmo remédio do bloqueador r2 do FridayIdeationJob (C2a-r5): duas
  # execuções paralelas do mesmo tópico selecionariam e enviariam os
  # mesmos itens antes de qualquer uma registrar a entrega (o efeito
  # externo no Discord é irreversível; o índice único só protege a marca
  # posterior). Escopo por tópico (não por tópico+canal): os keys de
  # entrega são escopados por tópico e a consulta sent_item_keys já
  # filtra por canal — rodar o mesmo tópico em dois canais em paralelo
  # duplicaria itens em um dos dois antes da marca. key é Proc lido dos
  # argumentos do job (instance_exec, como o group padrão); on_conflict
  # padrão (:block) aguarda a execução em andamento em vez de descartar
  # a 2ª.
  limits_concurrency key: ->(topic_id, _channel_id = {}) { "last30days_topic/#{topic_id}" }, to: 1

  # channel_id é resolvido UMA vez pelo Last30DaysDigestJob e passado como
  # argumento (Achado 8). Pode ser nil se não houver canal configurado.
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

    # C2c: supressão de repetição via mecanismo C2a (DigestItemDelivery) —
    # itens JÁ ENTREGUES para este digest_type + canal NÃO repetem (nem no
    # 2º item de um cluster que sobreviveu à filtragem, e nem em tópicos
    # distintos — item_key escopada por tópico, ver record_delivery). A
    # janela temporal do digest (fontes só retornam itens dos últimos 30
    # dias: HN created_at_i>now-30d, GitHub created:>=now-30d; Polymarket
    # sem filtro) é o que controla a REAPARIÇÃO: um item lançado há 40 dias
    # que já foi enviado não volta, e se uma fonte sem filtro (Polymarket)
    # o deixasse ressurgir, a supressão permanente (sem filtro por sent_at,
    # política C2a documentada na migration e no DigestItemDelivery)
    # mantém fora — nunca repetição em silêncio.
    sent_keys = DigestItemDelivery.sent_item_keys(digest_type: DIGEST_TYPE, channel_id: channel_id,
                                                  item_type: ITEM_TYPE)

    # Compatibilidade Achado 6 da janela 7d: TopicDelivery continua gravada
    # (janela curta de dedupe do digest), e a supressão PERMANENTE agora vem
    # da DigestItemDelivery — nunca do catálogo.
    recent_keys = TopicDelivery.where(topic_id: topic.id)
                               .where("sent_at >= ?", 7.days.ago)
                               .pluck(:url_key)
                               .to_set

    filtered_clusters = clusters.filter_map do |cluster|
      items = Array(cluster["items"])
      new_items = items.reject do |item|
        uk = extract_url_key(item)
        rejected = recent_keys.include?(uk)
        rejected ||= uk.present? && sent_keys.include?(delivery_item_key(topic, uk))
        rejected
      end

      next nil if new_items.empty?

      cluster.merge("items" => new_items)
    end

    if filtered_clusters.empty?
      Rails.logger.info "[Last30DaysTopicJob] Todos os itens para tópico #{topic.name} foram deduplicados"
      return { topic_id: topic.id, clusters: [], sent: false }
    end

    # Achado 4: montar a mensagem PRIMEIRO para saber quais keys foram
    # realmente renderizadas (limitadas por MAX_CLUSTERS × MAX_ITEMS_PER_
    # CLUSTER). Só então registrar a entrega dos itens que aparecem na
    # mensagem — espelhando o FridayIdeationJob (C2a).
    result = Last30Days::MessageBuilder.build(clusters: filtered_clusters, topic_name: topic.name)
    message = result[:text]
    rendered_keys = result[:url_keys]

    now = Time.current
    rendered_keys.each do |uk|
      td = TopicDelivery.find_or_initialize_by(topic_id: topic.id, url_key: uk)
      td.sent_at = now
      td.save!
    rescue ActiveRecord::RecordNotUnique
      # Concorrência: outro worker gravou antes; tenta atualizar
      TopicDelivery.where(topic_id: topic.id, url_key: uk).update_all(sent_at: now)
    end

    begin
      send_message_chunks(channel_id, message)
      # C2c: registra a entrega SÓ no caminho feliz — DEPOIS de todos os
      # chunks terem saído bem (padrão FridayIdeationJob/C2a: marcar antes
      # do envio trocava repetição por perda silenciosa).
      record_delivery(channel_id, topic, rendered_keys)
    rescue RuntimeError => e
      # O envio falhou (ex.: canal obsoleto): a entrega NÃO é registrada —
      # os itens continuam elegíveis e a próxima execução reenvia, sem
      # reenviar antes do que já saiu.
      Rails.logger.warn "[Last30DaysTopicJob] Envio falhou para tópico #{topic.name} canal #{channel_id}: #{e.message}"
      raise
    end
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

  # C2c: chave estável de entrega — ESCOPADA POR TÓPICO: o mesmo link
  # pode aparecer em tópicos distintos e é relevante para cada um; sem o
  # escopo, a entrega de um tópico silenciaria os demais (o item_key puro
  # seria a chave do digest inteiro, igual ao friday).
  def delivery_item_key(topic, url_key)
    "topic_#{topic.id}:#{url_key}"
  end

  # C2c: estado de envio em DigestItemDelivery (tabela própria, nunca em
  # tabela de catálogo), gravado após o envio ter saído bem. Idempotente
  # pelo índice único (digest_type, channel_id, item_type, item_key): uma
  # execução concorrente que venceu a corrida de envio marca primeiro; a
  # segunda criação é recusada (limite de concorrentia acima minimiza a
  # janela, e a chave escopada por tópico impede disputa entre tópicos).
  def record_delivery(channel_id, topic, rendered_keys)
    return if rendered_keys.empty?

    now = Time.current
    rendered_keys.each do |uk|
      begin
        DigestItemDelivery.mark_sent!(digest_type: DIGEST_TYPE, channel_id: channel_id,
                                      item_type: ITEM_TYPE,
                                      item_key: delivery_item_key(topic, uk), sent_at: now)
      rescue ActiveRecord::RecordInvalid => e
        # Índice único: outro worker gravou esta entrega primeiro (concorrência
        # residual). Marca válida e idempotente — loga e segue.
        Rails.logger.warn "[Last30DaysTopicJob] Entrega #{delivery_item_key(topic, uk)} já registrada (concorrência): #{e.message}"
      end
    end
  end

  def send_message_chunks(channel_id, message)
    # Achado 5 (PR #36): chunking delegado ao helper único
    # DiscordMessageChunker (Zeitwerk carrega app/services; SEM require_relative,
    # que quebraria o eager_load — lição da noite). Cada chunk vira um envio.
    DiscordMessageChunker.chunk(message).each do |chunk|
      DiscordApiClient.send_message(channel_id, chunk)
    end
  end
end
