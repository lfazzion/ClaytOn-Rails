# frozen_string_literal: true

require "time"

module Research
  module Signals
    SOURCE_QUALITY = {
      "hackernews" => 0.8,
      "youtube"    => 0.85,
      "reddit"     => 0.6,
      "x"          => 0.68,
      "polymarket" => 0.5,
      "github"     => 0.9,
      "rss"        => 0.75,
      "web"        => 0.6
    }.freeze

    ENGAGEMENT_WEIGHTS = {
      "x"          => [["likes", 0.55], ["reposts", 0.25], ["replies", 0.15], ["quotes", 0.05]],
      "hackernews" => [["points", 0.55], ["comments", 0.45]],
      "polymarket" => [["volume", 0.60], ["liquidity", 0.40]]
    }.freeze

    # Alias de campo por canal: o scoring procura `reposts`, o canal X entrega
    # `retweets` — sem o alias, item com só retweet vira engagement nil.
    FIELD_ALIASES = { "reposts" => "retweets" }.freeze

    VOTE_LOG_REFERENCE = {
      "reddit"     => 7.6,
      "hackernews" => 6.2,
      "youtube"    => 10.3,
      "tiktok"     => 10.3,
      "instagram"  => 9.2,
      "x"          => 9.2,
      "bluesky"    => 9.2
    }.freeze

    VOTE_LOG_REFERENCE_DEFAULT = 7.6

    def self.log1p(value)
      val = value.to_f
      return 0.0 if val <= 0

      Math.log1p(val)
    rescue Math::DomainError, TypeError
      0.0
    end

    def self.top_comment_score(data)
      return 0 if data.nil?

      comments = fetch_val(data, "top_comments")
      return 0 unless comments.is_a?(Array) && comments.any?

      top3 = comments.first(3)
      scores = top3.filter_map do |c|
        s = c.is_a?(Hash) ? fetch_val(c, "score") : nil
        s.to_f if s && s.to_f > 0
      end

      scores.max || 0
    end

    def self.engagement_raw(source, engagement)
      return nil unless engagement.is_a?(Hash)

      src = source.to_s.strip.downcase

      case src
      when "reddit"
        score = fetch_val(engagement, "score")
        num_comments = fetch_val(engagement, "num_comments") || fetch_val(engagement, "comments")
        upvote_ratio = fetch_val(engagement, "upvote_ratio")
        tc_score = fetch_val(engagement, "top_comment_score") || top_comment_score(engagement)

        if score.nil? && num_comments.nil? && upvote_ratio.nil? && tc_score.to_f.zero?
          return nil
        end

        upvote_val = upvote_ratio ? upvote_ratio.to_f * 10.0 : 0.0

        0.50 * log1p(score) +
          0.35 * log1p(num_comments) +
          0.05 * upvote_val +
          0.10 * log1p(tc_score)

      when "youtube"
        views = fetch_val(engagement, "views")
        likes = fetch_val(engagement, "likes")
        comments = fetch_val(engagement, "comments") || fetch_val(engagement, "num_comments")
        tc_score = fetch_val(engagement, "top_comment_score") || top_comment_score(engagement)

        if views.nil? && likes.nil? && comments.nil? && tc_score.to_f.zero?
          return nil
        end

        0.45 * log1p(views) +
          0.32 * log1p(likes) +
          0.13 * log1p(comments) +
          0.10 * log1p(tc_score)

      else
        weights = ENGAGEMENT_WEIGHTS[src]
        if weights
          has_any = weights.any? do |field, _|
            !fetch_val(engagement, field).nil? ||
              (FIELD_ALIASES[field] && !fetch_val(engagement, FIELD_ALIASES[field]).nil?)
          end
          return nil unless has_any

          weights.sum do |field, weight|
            val = fetch_val(engagement, field)
            val = fetch_val(engagement, FIELD_ALIASES[field]) if val.nil? && FIELD_ALIASES[field]
            log1p(val) * weight
          end
        else
          numeric_vals = engagement.values.filter_map { |v| v.to_f if v.is_a?(Numeric) && v > 0 }
          return nil if numeric_vals.empty?

          numeric_vals.sum { |v| log1p(v) }
        end
      end
    end

    def self.freshness(published_at, max_days: 30, reference: Time.now.utc)
      # Data ausente NÃO ganha frescor máximo (isso favoreceria item sem data
      # sobre item datado): neutro 0.5, sem mentir nem penalizar.
      return 0.5 if published_at.nil?

      ref = reference.is_a?(Time) ? reference : Time.parse(reference.to_s)
      pub = case published_at
            when Time then published_at
            when Date, DateTime then published_at.to_time
            else Time.parse(published_at.to_s)
            end

      dias = (ref - pub.utc) / 86400.0
      return 0.0 if dias > max_days
      return 1.0 if dias < 0

      days_fresh = 1.0 - (dias / max_days.to_f)
      days_fresh.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      1.0
    end

    def self.source_quality(source)
      src = source.to_s.strip.downcase
      SOURCE_QUALITY.fetch(src, 0.6)
    end

    private_class_method def self.fetch_val(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key.to_s] || hash[key.to_sym]
    end
  end
end
