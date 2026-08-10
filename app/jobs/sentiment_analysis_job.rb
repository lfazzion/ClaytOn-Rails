# frozen_string_literal: true

class SentimentAnalysisJob < ApplicationJob
  include DigestChannel

  queue_as :default

  def perform(target_id)
    target = SentimentTarget.find(target_id)

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

    run.update!(status: "collecting")
    Research::Sentiment::Collector.collect(run)

    run.update!(status: "classifying")
    Research::Sentiment::Classifier.classify(run)

    run.update!(status: "aggregating")
    data = Research::Sentiment::Aggregator.aggregate(run)

    message = Sentiment::MessageBuilder.build(run, data)

    channel_id = ensure_digest_channel
    if channel_id.present?
      DiscordMessageChunker.chunk(message).each do |chunk|
        DiscordApiClient.send_message(channel_id, chunk)
      end
      run.update!(status: "completed", finished_at: Time.current)
      Rails.logger.info "[SentimentAnalysisJob] Análise concluída para alvo ##{target.id} (#{target.name})"
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
end
