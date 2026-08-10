# frozen_string_literal: true

module Analytics
  class PostScorer
    MIN_BASELINE_N = 10
    # Janela etária do baseline: posts com idade dentro de ±BASELINE_AGE_WINDOW_DAYS do alvo.
    BASELINE_AGE_WINDOW_DAYS = 7

    class << self
      def score_posts(profile:)
        candidates = profile.social_posts.where("scored_at IS NULL OR views_at_scoring IS NULL OR views_at_scoring != views_count")
        candidates.find_each do |post|
          score!(post)
        end
      end

      def score!(post)
        return if post.views_count.nil?

        # Posts < 7d: ainda amadurecendo, sem pontuação.
        if post.posted_at.present? && post.posted_at >= 7.days.ago
          post.update!(
            performance_band: "maturing",
            performance_score: nil,
            views_at_scoring: nil,
            scored_at: Time.current
          )
          return
        end

        # Achado 3: Posts > 45d ficam fora da janela de scoring.
        # — Se já têm banda: manter a última, não re-pontuar.
        # — Se nunca foram pontuados (scored_at nil): pular com log (baseline seria de época
        #   completamente diferente; re-pontuar agora produz z inflado falso).
        if post.posted_at.present? && post.posted_at < 45.days.ago
          if post.performance_band.present?
            # Mantém pontuação existente sem re-pontuar.
            return
          else
            Rails.logger.info "[PostScorer] Pulando post #{post.id} (posted_at=#{post.posted_at&.to_date}): > 45d e nunca pontuado — baseline seria de era diferente"
            return
          end
        end

        # Achado 2: baseline age-matched — mesma faixa etária do post (±BASELINE_AGE_WINDOW_DAYS).
        # Elimina viés de acumulação de views: post de 8d não é comparado com posts de 30d.
        # posted_at nil (scrape falhou): pular sem pontuar — o post volta à fila quando a
        # coleta corrigir a data. Sem essa guarda, Time.current - nil levantava TypeError
        # e a pontuação do perfil inteiro morria.
        return if post.posted_at.nil?

        post_age = Time.current - post.posted_at
        age_window_start = Time.current - (post_age + BASELINE_AGE_WINDOW_DAYS.days)
        age_window_end   = Time.current - (post_age - BASELINE_AGE_WINDOW_DAYS.days)

        # Achado 1: excluir o próprio post do baseline (where.not(id: post.id)).
        baseline_scope = SocialPost.where(
          social_profile_id: post.social_profile_id,
          post_type: post.post_type
        ).where("posted_at >= ? AND posted_at < ?", age_window_start, age_window_end)
         .where("views_count IS NOT NULL AND views_count > 0")
         .where.not(id: post.id)

        baseline_n = baseline_scope.count

        if baseline_n < MIN_BASELINE_N
          post.update!(
            performance_band: "insufficient_data",
            performance_score: nil,
            views_at_scoring: nil,
            baseline_n: baseline_n,
            scored_at: Time.current
          )
          return
        end

        values = baseline_scope.pluck(:views_count).map { |v| Math.log1p(v) }
        post_val = Math.log1p(post.views_count)

        med = median(values)
        abs_devs = values.map { |x| (x - med).abs }
        mad = median(abs_devs)

        dispersion = if mad > 0
                       mad / 0.6745
                     else
                       iqr = calculate_iqr(values)
                       iqr > 0 ? (iqr / 1.349) : nil
                     end

        if dispersion.nil? || dispersion.zero?
          post.update!(
            performance_band: "insufficient_data",
            performance_score: nil,
            views_at_scoring: nil,
            baseline_n: baseline_n,
            scored_at: Time.current
          )
          return
        end

        factor = scale_correction_factor(baseline_n)
        z = (post_val - med) / (dispersion * factor)

        band = if z >= 2.0
                 "excelente"
               elsif z >= 1.0
                 "bom"
               elsif z <= -1.0
                 "ruim"
               else
                 "medio"
               end

        post.update!(
          performance_score: z.round(4),
          performance_band: band,
          scored_at: Time.current,
          baseline_n: baseline_n,
          views_at_scoring: post.views_count
        )
      end

      private

      def median(array)
        return 0.0 if array.empty?

        sorted = array.sort
        len = sorted.length
        if len.odd?
          sorted[len / 2]
        else
          (sorted[(len / 2) - 1] + sorted[len / 2]) / 2.0
        end
      end

      def calculate_iqr(values)
        sorted = values.sort
        len = sorted.length
        m = len / 2
        lower = sorted[0...m]
        upper = len.odd? ? sorted[(m + 1)...len] : sorted[m...len]

        q1 = median(lower)
        q3 = median(upper)
        q3 - q1
      end

      # Código morto removido: when 8..9 era inalcançável com MIN_BASELINE_N=10
      # (baseline_n < 10 resulta em insufficient_data antes de chegar aqui).
      def scale_correction_factor(n)
        case n
        when 10..14 then 1.08
        when 15..19 then 1.05
        else 1.0
        end
      end
    end
  end
end
