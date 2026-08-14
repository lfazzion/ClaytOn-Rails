# frozen_string_literal: true

require "json"
require "set"

module Research
  module Sentiment


    class Classifier
      BATCH_SIZE = 100
      ALLOWED_LABELS = %w[positive negative neutral].freeze
      PROMPT_VERSION = "1.0"

      PRIMARY_MODEL   = "google/gemma-4-26b-a4b-it:free"
      SECONDARY_MODEL = "nvidia/nemotron-3-nano-30b-a3b:free"
      ROUTER_MODEL    = "openrouter/free"
      NOUS_MODEL      = "tencent/hy3:free"

      LADDER = [
        { id: PRIMARY_MODEL, pinned: true },
        { id: SECONDARY_MODEL, pinned: true },
        { id: ROUTER_MODEL, pinned: false },
        { id: NOUS_MODEL, pinned: false }
      ].freeze

      class << self
        def classify(run)
          new(run).classify
        end
        alias call classify

        def check_and_track_quota!(run = nil)
          new(run).send(:check_and_track_quota!)
        end
      end

      def initialize(run)
        @run = run
      end

      def classify
        phrases = @run.sentiment_phrases.to_a
        return @run if phrases.empty?

        Llm::ModelRegistry.register_custom_models! if defined?(Llm::ModelRegistry)

        started_at_str = (@run.started_at || Time.current).in_time_zone("America/Sao_Paulo").to_s
        batches = phrases.each_slice(BATCH_SIZE).to_a
        classified_total = 0
        unparsed_total = 0

        ladder_idx = 0
        snapshot_pinned = true
        used_models_set = Set.new

        batches.each_with_index do |batch, b_idx|
          batch_payload = batch.each_with_index.map do |p, idx|
            { id: idx, text: p.text }
          end.to_json

          prompt_data = Llm::PromptLoader.load(
            "sentiment_classify",
            started_at: started_at_str,
            batch_items: batch_payload
          )

          predictions_map = nil
          model_info = nil

          while ladder_idx < LADDER.size
            model_info = LADDER[ladder_idx]
            snapshot_pinned = false unless model_info[:pinned]

            raw_res = execute_model(model_info[:id], prompt_data[:system], prompt_data[:user])
            predictions_map = parse_and_validate_predictions(raw_res, batch.size) if raw_res.present?

            if predictions_map.nil?
              # Retry 1 time with current model
              raw_retry = execute_model(model_info[:id], prompt_data[:system], prompt_data[:user])
              predictions_map = parse_and_validate_predictions(raw_retry, batch.size) if raw_retry.present?
            end

            break if predictions_map.present?

            # Model failed on this batch after retry -> promote to next model in ladder
            ladder_idx += 1
            snapshot_pinned = false
          end

          if predictions_map.nil?
            # Ladder exhausted
            # fallback pago é fase futura (decisão do dono 10/08: proibido) — a escada gratuita esgotada sempre para e alerta
            target_name = @run.sentiment_target&.name || @run.target_id
            alert_admin_failure("pipeline de sentimento: todos os modelos gratuitos falharam — run ##{@run.id} alvo #{target_name} precisa de atenção")
            raise AllModelsFailed, "pipeline de sentimento: todos os modelos gratuitos falharam — run ##{@run.id}"
          else
            current_model_id = model_info[:id]
            used_models_set.add(current_model_id)

            batch.each_with_index do |phrase, idx|
              label_val = predictions_map[idx]
              if label_val.present? && ALLOWED_LABELS.include?(label_val)
                SentimentLabel.create!(
                  phrase_id: phrase.id,
                  run_id: @run.id,
                  pass: 1,
                  attempt: 1,
                  label: label_val,
                  confidence: 1.0,
                  model_id: current_model_id,
                  prompt_version: PROMPT_VERSION,
                  batch_index: b_idx
                )
                classified_total += 1
              else
                unparsed_total += 1
              end
            end
          end
        end

        snapshot_pinned = false if used_models_set.size > 1
        model_id_str = used_models_set.to_a.join(", ").presence || PRIMARY_MODEL

        @run.update!(
          classified_count: classified_total,
          unparsed_count: unparsed_total,
          model_id: model_id_str,
          snapshot_pinned: snapshot_pinned,
          status: "classified"
        )

        @run
      end

      private

      def execute_model(model_id, system_prompt, user_prompt)
        check_and_track_quota!
        invoke_llm(model_id, system_prompt, user_prompt)
      rescue QuotaExceededError
        raise
      rescue StandardError => e
        Rails.logger.warn "[Research::Sentiment::Classifier] Modelo #{model_id} falhou: #{e.message}"
        nil
      end

      def check_and_track_quota!
        limit = (ENV["SENTIMENT_DAILY_LIMIT"].presence || 150).to_i
        day = Date.current
        now = Time.current
        SentimentDailyQuota.insert_all(
          [{ day: day, count: 0, created_at: now, updated_at: now }],
          unique_by: :day
        )

        updated = SentimentDailyQuota.where(day: day).where("count < ?", limit).update_all("count = count + 1")

        if updated == 1
          true
        else
          target_name = @run&.sentiment_target&.name || @run&.target_id
          alert_admin_failure("pipeline de sentimento: cota diária excedida (#{limit}/#{limit}) — run ##{@run&.id} alvo #{target_name} precisa de atenção")
          raise QuotaExceededError, "Cota diária de requisições de sentimento atingida (#{limit}/#{limit})"
        end
      end

      def invoke_llm(model_id, system_prompt, user_prompt)
        chat = RubyLLM.chat(model: model_id)
        chat.with_instructions(system_prompt) if system_prompt.present?
        chat.with_temperature(0) if chat.respond_to?(:with_temperature)
        chat.with_params(response_format: { type: "json_object" }) if chat.respond_to?(:with_params)

        response = chat.ask(user_prompt)
        response.respond_to?(:content) ? response.content : response.to_s
      end

      def parse_and_validate_predictions(raw_response, batch_size)
        return nil if raw_response.blank?

        parsed = JSON.parse(raw_response.to_s)
        predictions = if parsed.is_a?(Hash)
                        parsed["predictions"] || parsed["items"] || parsed["data"]
                      elsif parsed.is_a?(Array)
                        parsed
                      end
        return nil unless predictions.is_a?(Array)

        map = {}
        seen_ids = Set.new

        predictions.each do |item|
          next unless item.is_a?(Hash)

          raw_id = item["id"]
          next unless raw_id.is_a?(Integer)
          next unless raw_id >= 0 && raw_id < batch_size
          next if seen_ids.include?(raw_id)

          lbl = item["sentiment"].to_s.strip.downcase
          next unless ALLOWED_LABELS.include?(lbl)

          seen_ids.add(raw_id)
          map[raw_id] = lbl
        end

        return nil if map.empty?

        map
      rescue JSON::ParserError
        nil
      end

      def alert_admin_failure(msg)
        AdminAlertAdapter.new(@run).alert(msg)
        Rails.logger.error "[Research::Sentiment::Classifier] ALERTA ADMIN: #{msg}"
      rescue StandardError => e
        Rails.logger.error "[Research::Sentiment::Classifier] Erro ao enviar alerta admin: #{e.message}"
      end
    end
  end
end
