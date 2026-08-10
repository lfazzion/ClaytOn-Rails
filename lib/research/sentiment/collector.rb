# frozen_string_literal: true

require "digest"
require "time"

module Research
  module Sentiment
    class Collector
      MIN_WORDS = 3
      MAX_CHARS = 500

      class << self
        def collect(run)
          new(run).collect
        end
        alias call collect
      end

      def initialize(run)
        @run = run
        @target = run.sentiment_target
      end

      def collect
        ensure_frozen_spec!

        spec = @run.frozen_spec.with_indifferent_access
        query = spec[:query]
        sources = spec[:sources].to_s.split(",").map(&:strip).reject(&:empty?)
        max_phrases = (spec[:max_phrases] || 600).to_i
        per_source_limit = sources.any? ? (max_phrases.to_f / sources.size).ceil : max_phrases

        w_start = parse_time(spec[:window_start]) || @run.window_start
        w_end = parse_time(spec[:window_end]) || @run.window_end

        source_fetched = {}
        sources.each do |src_name|
          source_class = case src_name.downcase
                         when "reddit" then Sources::Reddit
                         when "x"      then Sources::X
                         end
          next unless source_class

          source_fetched[src_name] = source_class.fetch(query: query, limit: per_source_limit)
        end

        collected = 0
        rejected = 0
        source_counts = Hash.new(0)
        max_len = source_fetched.values.map(&:size).max || 0

        (0...max_len).each do |idx|
          sources.each do |src_name|
            items = source_fetched[src_name]
            next if items.nil? || idx >= items.size
            break if collected >= max_phrases
            next if source_counts[src_name] >= per_source_limit

            item = items[idx]
            posted_at = item[:posted_at]

            if posted_at.present? && w_start.present? && w_end.present?
              p_time = posted_at.is_a?(Time) ? posted_at.utc : Time.parse(posted_at.to_s).utc rescue nil
              if p_time && (p_time < w_start || p_time > w_end)
                rejected += 1
                next
              end
            end

            text = item[:text].to_s.strip
            words = text.split(/\s+/)

            if words.size < MIN_WORDS || text.length > MAX_CHARS
              rejected += 1
              next
            end

            # Checagem de relevância mínima usando o Research::Scorer se houver contexto
            relevance = Research::Scorer.score({ "title" => text, "text" => text }, query: query)
            if relevance.zero? && query.present? && query.length > 3
              rejected += 1
              next
            end

            ext_id = item[:external_id]
            phrase = SentimentPhrase.find_or_initialize_by(run_id: @run.id, external_id: ext_id)
            if phrase.new_record?
              phrase.assign_attributes(
                source: item[:source],
                permalink: item[:permalink],
                author: item[:author],
                text: text,
                posted_at: posted_at,
                collected_at: Time.current
              )
              phrase.save!
              collected += 1
              source_counts[src_name] += 1
            end
          end
        end

        @run.update!(
          collected_count: collected,
          rejected_count: rejected,
          status: "collected"
        )

        @run
      end

      private

      def ensure_frozen_spec!
        spec = (@run.frozen_spec || {}).with_indifferent_access
        return if spec.present? && spec[:window_start].present? && spec[:window_end].present?

        started_at = (@run.started_at || Time.current).utc
        w_start = started_at - @target.window_days.days
        # folga de 1 minuto no limite superior: o fim da janela é o instante do início do run + tolerância de skew de relógio/ordenação — declarado no spec para o relatório ser honesto
        w_end = started_at + 1.minute

        full_spec = {
          "target_id" => @target.id,
          "name" => @target.name,
          "query" => @target.query,
          "sources" => @target.sources,
          "window_days" => @target.window_days,
          "bucket" => @target.bucket,
          "max_phrases" => @target.max_phrases,
          "window_start" => w_start.iso8601(9),
          "window_end" => w_end.iso8601(9)
        }

        @run.update!(
          frozen_spec: full_spec,
          window_start: w_start,
          window_end: w_end
        )
      end

      def parse_time(val)
        return nil if val.blank?

        val.is_a?(Time) ? val.utc : Time.parse(val.to_s).utc
      rescue StandardError
        nil
      end
    end
  end
end
