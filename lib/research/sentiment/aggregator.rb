# frozen_string_literal: true

require "date"

module Research
  module Sentiment
    class Aggregator
      SPARKLINE_CHARS = %w[  ▂ ▃ ▄ ▅ ▆ ▇ █].freeze
      MIN_BUCKET_SIZE = 30

      class << self
        def aggregate(run)
          new(run).aggregate
        end
        alias call aggregate
      end

      def initialize(run)
        @run = run
      end

      def aggregate
        spec = (@run.frozen_spec || {}).with_indifferent_access
        bucket_type = spec[:bucket].to_s == "day" ? "day" : "week"

        phrases = @run.sentiment_phrases.includes(:sentiment_labels).to_a
        labels_by_phrase_id = {}
        phrases.each do |p|
          lbl = p.sentiment_labels.select { |l| l.pass == 1 }.max_by(&:attempt)
          labels_by_phrase_id[p.id] = lbl.label if lbl
        end

        sem_data_count = 0
        total_pos = 0
        total_neg = 0
        total_neu = 0

        source_counts = Hash.new { |h, k| h[k] = { positive: 0, negative: 0, neutral: 0, total: 0 } }
        bucket_groups = Hash.new { |h, k| h[k] = { positive: 0, negative: 0, neutral: 0, total: 0, phrases: [] } }

        examples = { "positive" => nil, "negative" => nil, "neutral" => nil }

        phrases.each do |p|
          lbl = labels_by_phrase_id[p.id]
          next if lbl.blank?

          case lbl
          when "positive" then total_pos += 1
          when "negative" then total_neg += 1
          when "neutral"  then total_neu += 1
          end

          src = p.source.to_s.downcase
          source_counts[src][lbl.to_sym] += 1
          source_counts[src][:total] += 1

          if examples[lbl].nil?
            examples[lbl] = {
              text: p.text,
              permalink: p.permalink
            }
          end

          if p.posted_at.nil?
            sem_data_count += 1
          else
            b_key = if bucket_type == "day"
                      p.posted_at.to_date.iso8601
                    else
                      p.posted_at.to_date.beginning_of_week.iso8601
                    end
            bucket_groups[b_key][lbl.to_sym] += 1
            bucket_groups[b_key][:total] += 1
            bucket_groups[b_key][:phrases] << p
          end
        end

        total_classified = total_pos + total_neg + total_neu
        period_balance_val = total_classified > 0 ? ((total_pos - total_neg).to_f / total_classified).round(2) : 0.0

        sources_balance = {}
        source_counts.each do |src, counts|
          tot = counts[:total]
          bal = tot > 0 ? ((counts[:positive] - counts[:negative]).to_f / tot).round(2) : 0.0
          sources_balance[src] = {
            positive: counts[:positive],
            negative: counts[:negative],
            neutral: counts[:neutral],
            total: tot,
            balance: bal
          }
        end

        valid_curve = []
        insufficient_buckets = []

        sorted_bucket_keys = bucket_groups.keys.sort
        sorted_bucket_keys.each do |b_key|
          b_data = bucket_groups[b_key]
          tot = b_data[:total]
          if tot < MIN_BUCKET_SIZE
            insufficient_buckets << b_key
          else
            pos = b_data[:positive]
            neg = b_data[:negative]
            neu = b_data[:neutral]
            bal = ((pos - neg).to_f / tot).round(2)
            spark_char = sparkline_char(bal)

            valid_curve << {
              date: b_key,
              balance: bal,
              n: tot,
              positive: pos,
              negative: neg,
              neutral: neu,
              sparkline: spark_char
            }
          end
        end

        # Cálculo de ΔS entre buckets VÁLIDOS consecutivos
        max_delta_s = nil
        if valid_curve.size >= 2
          max_delta_val = -10.0
          valid_curve.each_cons(2) do |b1, b2|
            delta = (b2[:balance] - b1[:balance]).round(2)
            b2[:delta_s] = delta
            if delta.abs > max_delta_val
              max_delta_val = delta.abs
              max_delta_s = {
                from_date: b1[:date],
                to_date: b2[:date],
                delta: delta
              }
            end
          end
        end

        {
          spec: spec,
          period_balance: {
            positive: total_pos,
            negative: total_neg,
            neutral: total_neu,
            total: total_classified,
            balance: period_balance_val
          },
          sources_balance: sources_balance,
          curve: valid_curve,
          max_delta_s: max_delta_s,
          insufficient_buckets: insufficient_buckets,
          unparsed_count: @run.unparsed_count,
          sem_data_count: sem_data_count,
          rejected_count: @run.rejected_count,
          collected_count: @run.collected_count,
          model_id: @run.model_id,
          snapshot_pinned: @run.snapshot_pinned,
          tara: @run.tara,
          examples: examples
        }
      end

      private

      def sparkline_char(balance)
        # Transforma [-1.0, 1.0] em escala [0, 1]
        norm = ((balance + 1.0) / 2.0).clamp(0.0, 1.0)
        idx = (norm * (SPARKLINE_CHARS.size - 1)).round
        SPARKLINE_CHARS[idx]
      end
    end
  end
end
