# frozen_string_literal: true

require_relative "relevance"
require_relative "signals"

module Research
  # Composite Scorer (Fase 2)
  #
  # Combina relevância de texto, engajamento normalizado cross-platform,
  # qualidade da fonte e frescor temporal em um score composto entre 0.0 e 1.0.
  #
  # Fórmula do Score Composto:
  #   score = (0.45 * relevância + 0.35 * engajamento_norm + 0.20 * qualidade) * freshness
  #
  # Justificativa da Normalização Cross-Platform de Engajamento:
  #
  # engagement_raw já calcula o engajamento em escala logarítmica (soma ponderada de log1p).
  # Como cada plataforma possui escalas nativas muito distintas (ex: views no YouTube
  # chegam a milhões, enquanto scores no HackerNews chegam a centenas), utilizamos a
  # constante VOTE_LOG_REFERENCE[source] (ex: 7.6 para reddit, 10.3 para youtube) que
  # representa o teto logarítmico esperado de um post altamente engajado na plataforma.
  #
  # A normalização é calculada como:
  #   engajamento_norm = [1.0, raw / ref].min
  #
  # Isso garante que:
  # 1. O score fica estritamente no intervalo [0.0, 1.0].
  # 2. A comparação entre plataformas é justa: atingir a referência máxima da sua
  #    plataforma gera engajamento_norm = 1.0 em qualquer canal.
  # 3. Métrica ausente ou engagement_raw nil produz engajamento_norm = 0.0 (sem penalizar
  #    excessivamente o score final se a relevância e qualidade forem altas).
  class Scorer
    class << self
      def score(item, query:)
        return 0.0 unless item.is_a?(Hash)

        pq = query.is_a?(Relevance::PreparedQuery) ? query : Relevance::PreparedQuery.build(query)

        text = extract_text(item)
        relevance = text.blank? ? 0.0 : Relevance.token_overlap_relevance(pq, text)

        source = detect_source(item)
        eng_data = extract_engagement(item)
        raw_eng = Signals.engagement_raw(source, eng_data)

        eng_norm = if raw_eng.nil?
                     0.0
                   else
                     ref = Signals::VOTE_LOG_REFERENCE.fetch(source, Signals::VOTE_LOG_REFERENCE_DEFAULT)
                     [1.0, raw_eng / ref.to_f].min
                   end

        quality = Signals.source_quality(source)
        published_at = extract_published_at(item)
        fresh = Signals.freshness(published_at)

        composite = (0.45 * relevance + 0.35 * eng_norm + 0.20 * quality) * fresh
        composite.clamp(0.0, 1.0).round(2)
      rescue StandardError => e
        Rails.logger.error "[Research::Scorer] erro ao pontuar item: #{e.class}: #{e.message}"
        0.0
      end

      def sort(items, query:)
        return [] if items.nil?

        pq = query.is_a?(Relevance::PreparedQuery) ? query : Relevance::PreparedQuery.build(query)

        Array(items).map do |item|
          next item unless item.is_a?(Hash)

          scored = item.dup
          scored["score"] = score(item, query: pq)
          scored
        end.sort_by { |item| -(item.is_a?(Hash) ? (item["score"] || item[:score] || 0.0) : 0.0) }
      end

      private

      def extract_text(item)
        fields = %w[title text content selftext description]
        parts = fields.map { |f| fetch_val(item, f) }.compact_blank
        parts.join(" ")
      end

      def detect_source(item)
        src = fetch_val(item, "source") || fetch_val_nested(item, %w[metadata source])
        return src.to_s.strip.downcase if src.present?

        url = fetch_val(item, "url")
        return infer_source_from_url(url) if url.present?

        "web"
      end

      def infer_source_from_url(url_str)
        host = URI.parse(url_str.to_s).host.to_s.downcase
        if host.include?("youtube.com") || host.include?("youtu.be")
          "youtube"
        elsif host.include?("reddit.com")
          "reddit"
        elsif host.include?("x.com") || host.include?("twitter.com")
          "x"
        elsif host.include?("ycombinator.com")
          "hackernews"
        elsif host.include?("polymarket.com")
          "polymarket"
        elsif host.include?("github.com")
          "github"
        else
          "web"
        end
      rescue URI::InvalidURIError
        "web"
      end

      def extract_engagement(item)
        eng = fetch_val(item, "engagement") || fetch_val(item, "metadata")
        return eng if eng.is_a?(Hash)

        item
      end

      def extract_published_at(item)
        fetch_val(item, "published_at") ||
          fetch_val(item, "created_at") ||
          fetch_val_nested(item, %w[metadata published_at]) ||
          fetch_val_nested(item, %w[metadata created_at])
      end

      def fetch_val(hash, key)
        return nil unless hash.is_a?(Hash)

        hash[key.to_s] || hash[key.to_sym]
      end

      def fetch_val_nested(hash, keys)
        curr = hash
        keys.each do |k|
          return nil unless curr.is_a?(Hash)

          curr = fetch_val(curr, k)
        end
        curr
      end
    end
  end
end
