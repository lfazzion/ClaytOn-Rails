# frozen_string_literal: true

require_relative "last30days_topic_job"

class Last30DaysDigestJob < ApplicationJob
  include DigestChannel

  queue_as :default

  def perform
    # Achado 8: resolver o canal UMA vez aqui (não em cada TopicJob).
    # Sem canal configurado → loga e não escalona nenhum job.
    # Cada TopicJob recebe o channel_id resolvido como argumento,
    # evitando que cada job tente criar um canal novo (30 canais/semana).
    channel_id = ensure_digest_channel

    if channel_id.nil?
      Rails.logger.info "[Last30DaysDigestJob] Sem canal digest configurado, abortando"
      return
    end

    count = 0
    Topic.active.find_each do |topic|
      wait_minutes = (topic.id * 37) % 45
      Last30DaysTopicJob.set(wait: wait_minutes.minutes).perform_later(topic.id, channel_id)
      count += 1
    end

    Rails.logger.info "[Last30DaysDigestJob] Enfileirados #{count} tópicos ativos para processamento"
  end
end
