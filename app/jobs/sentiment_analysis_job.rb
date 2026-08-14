# frozen_string_literal: true

class SentimentAnalysisJob < ApplicationJob
  include DigestChannel

  queue_as :default

  DELIVERY_LOCK_PREFIX = "sentiment_delivery_lock"
  DELIVERY_LOCK_TTL = 15

  def perform(target_id, run_id = nil)
    target = SentimentTarget.find(target_id)
    run = nil

    if run_id.present?
      found_run = SentimentRun.find_by(id: run_id)
      raise ArgumentError, "Run ##{run_id} não encontrado" if found_run.nil?
      if found_run.target_id != target.id
        raise ArgumentError, "Run ##{run_id} pertence ao alvo ##{found_run.target_id}, não ao alvo ##{target.id}"
      end
      return found_run if found_run.delivered_at.present?
      run = found_run
    end

    unless run
      started_at = Time.current.utc
      w_start = started_at - target.window_days.days
      # folga de 1 minuto no limite superior: o fim da janela é o instante do início do run + tolerância de skew de relógio/ordenação — declarado no spec para o relatório ser honesto
      w_end = started_at + 1.minute

      spec = target.frozen_spec.merge(
        "target_id" => target.id,
        "window_start" => w_start.iso8601(9),
        "window_end" => w_end.iso8601(9)
      )

      run = target.sentiment_runs.create!(
        status: "pending",
        started_at: started_at,
        frozen_spec: spec,
        window_start: w_start,
        window_end: w_end
      )
    end

    return run if run.delivered_at.present?

    run.update!(status: "collecting")
    Research::Sentiment::Collector.collect(run)

    run.reload
    if run.status == "insufficient_data"
      run.update!(finished_at: Time.current)
      Rails.logger.warn "[SentimentAnalysisJob] Coleta sem dados suficientes para alvo ##{target.id} (#{target.name})"
      return run
    end

    run.update!(status: "classifying")
    Research::Sentiment::Classifier.classify(run)

    run.update!(status: "aggregating")
    data = Research::Sentiment::Aggregator.aggregate(run)

    message = Sentiment::MessageBuilder.build(run, data)

    channel_id = ensure_digest_channel
    if channel_id.present?
      chunks = DiscordMessageChunker.chunk(message)
      begin
        deliver_chunks(run, channel_id, chunks, target)
      rescue RuntimeError => e
        if e.message.include?("404") || e.message.match?(/unknown channel/i)
          recovered_id = recover_digest_channel(channel_id)
          if recovered_id.present?
            deliver_chunks(run, recovered_id, chunks, target)
            Rails.logger.info "[SentimentAnalysisJob] Análise concluída no canal recuperado para alvo ##{target.id} (#{target.name})"
          else
            run.update!(status: "delivery_failed", error: "canal digest indisponível", finished_at: Time.current)
            Rails.logger.error "[SentimentAnalysisJob] Canal digest obsoleto e não recuperado para envio do relatório (run ##{run.id})"
          end
        else
          raise e
        end
      end
    else
      run.update!(status: "delivery_failed", error: "canal digest indisponível", finished_at: Time.current)
      Rails.logger.error "[SentimentAnalysisJob] Canal digest indisponível para envio do relatório (run ##{run.id})"
    end

    run
  rescue StandardError => e
    run&.update!(status: "failed", error: e.message, finished_at: Time.current)
    Rails.logger.error "[SentimentAnalysisJob] Falha no job: #{e.class}: #{e.message}"
    raise e
  end

  private

  def deliver_chunks(run, channel_id, chunks, target)
    run.reload
    return if run.delivered_at.present?

    token = SecureRandom.hex(8)
    return unless acquire_delivery_lock(run.id, token)

    begin
      run.reload
      return if run.delivered_at.present?

      chunks.each_with_index do |chunk, idx|
        next if SentimentChunkDelivery.exists?(run_id: run.id, chunk_index: idx)

        DiscordApiClient.send_message(channel_id, chunk)
        begin
          SentimentChunkDelivery.create!(run_id: run.id, chunk_index: idx, delivered_at: Time.current)
        rescue ActiveRecord::RecordNotUnique
          # Já registrado concorrentemente
        end
      end

      delivered_count = SentimentChunkDelivery.where(run_id: run.id).count
      if delivered_count >= chunks.size
        run.update!(status: "completed", delivered_at: Time.current, finished_at: Time.current)
        Rails.logger.info "[SentimentAnalysisJob] Análise concluída para alvo ##{target.id} (#{target.name})"
      end
    ensure
      release_delivery_lock(run.id, token)
    end
  end

  def acquire_delivery_lock(run_id, token)
    lock_key = "#{DELIVERY_LOCK_PREFIX}:#{run_id}"
    Rails.cache.write(lock_key, token, unless_exist: true, expires_in: DELIVERY_LOCK_TTL)
  end

  def release_delivery_lock(run_id, token)
    return unless token.present?

    lock_key = "#{DELIVERY_LOCK_PREFIX}:#{run_id}"
    if Rails.cache.is_a?(SolidCache::Store)
      normalized = Rails.cache.send(:normalize_key, lock_key, nil)
      SolidCache::Entry.lock_and_write(normalized) do |raw|
        if raw && Rails.cache.send(:deserialize_entry, raw)&.value.to_s == token.to_s
          SolidCache::Entry.delete_by_key(normalized)
        end
        nil
      end
    else
      Rails.cache.delete(lock_key) if Rails.cache.read(lock_key).to_s == token.to_s
    end
  end
end
