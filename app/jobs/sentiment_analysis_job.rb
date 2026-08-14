# frozen_string_literal: true

class SentimentAnalysisJob < ApplicationJob
  include DigestChannel

  queue_as :default

  def perform(target_id, run_id = nil)
    if run_id.present?
      run = SentimentRun.find_by(id: run_id)
      return run if run&.delivered_at.present?
    end

    target = SentimentTarget.find(target_id)

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
        send_chunks(run, channel_id, chunks)
        run.update!(status: "completed", delivered_at: Time.current, finished_at: Time.current)
        Rails.logger.info "[SentimentAnalysisJob] Análise concluída para alvo ##{target.id} (#{target.name})"
      rescue RuntimeError => e
        if e.message.include?("404") || e.message.match?(/unknown channel/i)
          recovered_id = recover_digest_channel(channel_id)
          if recovered_id.present?
            send_chunks(run, recovered_id, chunks)
            run.update!(status: "completed", delivered_at: Time.current, finished_at: Time.current)
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

  def send_chunks(run, channel_id, chunks)
    chunks.each_with_index do |chunk, idx|
      next if SentimentChunkDelivery.exists?(run_id: run.id, chunk_index: idx)

      delivery = nil
      begin
        delivery = SentimentChunkDelivery.create!(run_id: run.id, chunk_index: idx, delivered_at: Time.current)
      rescue ActiveRecord::RecordNotUnique
        next
      end

      begin
        DiscordApiClient.send_message(channel_id, chunk)
      rescue StandardError => e
        delivery.destroy rescue nil
        raise e
      end
    end
  end
end
