# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/analytics/post_scorer"

class AnalyticsPostScorerTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile, platform: "youtube")
  end

  # ---------------------------------------------------------------------------
  # Achado 1 — o post pontuado NÃO entra no próprio baseline
  # Com a correção: 10 baselines + 1 alvo → baseline_n == 10 (exclui o alvo)
  # ---------------------------------------------------------------------------
  test "score_posts calculates z-score and sets performance_band correctly with 10+ baseline posts" do
    # 10 baseline posts dentro da janela etária do alvo (alvo 12d → faixa 5..19d)
    # Fixtures com 8..17d: folga de 2d do limite superior da janela (19d)
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (8 + i).days.ago,
        views_count: 1000 + (i * 100)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 12.days.ago,
      views_count: 10_000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload

    assert_not_nil target_post.performance_score
    assert_equal "excelente", target_post.performance_band
    assert_not_nil target_post.scored_at
    # Achado 1 corrigido: o alvo é excluído do baseline → baseline_n == 10 (não 11)
    assert_equal 10, target_post.baseline_n

    assert_equal 10_000, target_post.views_at_scoring
  end

  # ---------------------------------------------------------------------------
  # MAD=0: fallback IQR ou insufficient_data — sem infinity
  # Baseline: posts com mesma idade do alvo (posted_at 10d → faixa ±7d: 3..17d)
  # O alvo também tem posted_at 10d → faixa válida
  # ---------------------------------------------------------------------------
  test "MAD=0 (identical views in baseline) falls back to IQR or insufficient_data without infinity" do
    10.times do
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: 15.days.ago,
        views_count: 1000
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 10.days.ago,
      views_count: 1000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload

    assert_nil target_post.performance_score
    assert_equal "insufficient_data", target_post.performance_band
    assert_not_equal Float::INFINITY, target_post.performance_score
  end

  # ---------------------------------------------------------------------------
  # Baseline < 10 posts → insufficient_data
  # Achado 2: baseline é age-matched; 5 posts na faixa → insuficiente
  # ---------------------------------------------------------------------------
  test "baseline < 10 posts sets insufficient_data band" do
    # 5 posts na faixa de idade do alvo (posted_at 8d → faixa 1..15d)
    5.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (10 + i).days.ago,
        views_count: 1000 + (i * 100)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 8.days.ago,
      views_count: 1500
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload

    assert_nil target_post.performance_score
    assert_equal "insufficient_data", target_post.performance_band
    assert_nil target_post.views_at_scoring
  end

  # ---------------------------------------------------------------------------
  # Post < 7d → maturing, sem score, sem views_at_scoring
  # ---------------------------------------------------------------------------
  test "post < 7d gets maturing band without score and without views_at_scoring" do
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (10 + i).days.ago,
        views_count: 1000 + (i * 100)
      )
    end

    recent_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 3.days.ago,
      views_count: 2000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    recent_post.reload

    assert_nil recent_post.performance_score
    assert_equal "maturing", recent_post.performance_band
    assert_nil recent_post.views_at_scoring
  end

  # ---------------------------------------------------------------------------
  # views_count nil → não puntua
  # ---------------------------------------------------------------------------
  test "views_count nil does not score post" do
    nil_views_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 10.days.ago,
      views_count: nil
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    nil_views_post.reload

    assert_nil nil_views_post.performance_score
    assert_nil nil_views_post.performance_band
    assert_nil nil_views_post.scored_at
  end

  # ---------------------------------------------------------------------------
  # Re-score idempotente quando views_count inalterado
  # Achado 2: baseline age-matched; posted_at 12d → faixa ±7d: 5..19d
  # ---------------------------------------------------------------------------
  test "re-score is idempotent when views_count unchanged, but re-scores when views_count changes" do
    # 10 baseline posts dentro da janela etária do alvo (alvo 12d → faixa 5..19d)
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (8 + i).days.ago,
        views_count: 1000 + (i * 100)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 12.days.ago,
      views_count: 2000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload
    original_score = target_post.performance_score

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload
    assert_equal original_score, target_post.performance_score

    target_post.update!(views_count: 5000)
    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload
    assert_not_equal original_score, target_post.performance_score
    assert_equal 5000, target_post.views_at_scoring
  end

  # ---------------------------------------------------------------------------
  # log1p: 1 view não produz -Infinity
  # Achado 2: baseline age-matched; posted_at 10d → faixa ±7d: 3..17d
  # ---------------------------------------------------------------------------
  test "log1p handles 1 view without producing negative infinity" do
    # 10 baseline posts dentro da janela etária do alvo (alvo 10d → faixa 3..17d)
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (7 + i).days.ago,
        views_count: 100 + (i * 10)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 10.days.ago,
      views_count: 1
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload

    assert_not_nil target_post.performance_score
    assert_not_equal (-Float::INFINITY), target_post.performance_score
    assert_equal "ruim", target_post.performance_band
  end

  # ---------------------------------------------------------------------------
  # Achado 2 — viés de idade: baseline fora da faixa etária do alvo → insufficient_data
  # Post de 8d com baselines de 30d (fora da janela 1..15d) → sem dados suficientes
  # ---------------------------------------------------------------------------
  test "age-biased baseline (posts outside age window) yields insufficient_data" do
    # Baselines com posted_at 30d — fora da faixa do alvo (8d ± 7d = 1..15d)
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (28 + i).days.ago,
        views_count: 50_000 + (i * 1000)
      )
    end

    # Alvo: 8 dias de vida — baseline age-matched cobre 1..15 dias
    young_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 8.days.ago,
      views_count: 8_000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    young_post.reload

    # Sem baselines na janela etária → insufficient_data, não uma banda inflada
    assert_equal "insufficient_data", young_post.performance_band
    assert_nil young_post.performance_score
  end

  # ---------------------------------------------------------------------------
  # Achado 2 — baseline age-matched: posts na faixa etária correta são usados
  # ---------------------------------------------------------------------------
  test "age-matched baseline scores post correctly" do
    # Alvo: 20 dias de vida → faixa do baseline: 13..27 dias
    # 10 baselines dentro da faixa
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (14 + i).days.ago,
        views_count: 5000 + (i * 200)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 20.days.ago,
      views_count: 100_000
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    target_post.reload

    assert_not_nil target_post.performance_score
    assert_equal "excelente", target_post.performance_band
    assert_equal 10, target_post.baseline_n
  end

  # ---------------------------------------------------------------------------
  # Achado 3 — post > 45d com banda já definida NÃO é re-pontuado
  # ---------------------------------------------------------------------------
  test "post older than 45d with existing band is not re-scored" do
    old_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 60.days.ago,
      views_count: 5000,
      views_at_scoring: 3000,        # views mudou → normalmente dispararia re-score
      performance_band: "bom",
      performance_score: 1.2,
      scored_at: 50.days.ago,
      baseline_n: 12
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    old_post.reload

    # Deve manter a banda original — não re-pontua
    assert_equal "bom", old_post.performance_band
    assert_equal 1.2, old_post.performance_score
  end

  # ---------------------------------------------------------------------------
  # Achado 3 — post > 45d nunca pontuado (scored_at nil) → pulado (sem mudança)
  # ---------------------------------------------------------------------------
  test "post older than 45d never scored is skipped (no band set)" do
    old_unscored_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 50.days.ago,
      views_count: 4000,
      views_at_scoring: nil,
      performance_band: nil,
      performance_score: nil,
      scored_at: nil
    )

    Analytics::PostScorer.score_posts(profile: @profile)
    old_unscored_post.reload

    # Não deve receber banda (pular silenciosamente com log)
    assert_nil old_unscored_post.performance_band
    assert_nil old_unscored_post.performance_score
    assert_nil old_unscored_post.scored_at
  end

  # ---------------------------------------------------------------------------
  # Código morto removido: scale_correction_factor não existe para n=8 ou 9
  # (com MIN_BASELINE_N=10, n<10 gera insufficient_data antes de chegar no factor)
  # ---------------------------------------------------------------------------
  test "scale_correction_factor returns 1.08 for n=10 and 1.0 for n>=20" do
    scorer = Analytics::PostScorer
    assert_equal 1.08, scorer.send(:scale_correction_factor, 10)
    assert_equal 1.08, scorer.send(:scale_correction_factor, 14)
    assert_equal 1.05, scorer.send(:scale_correction_factor, 15)
    assert_equal 1.05, scorer.send(:scale_correction_factor, 19)
    assert_equal 1.0,  scorer.send(:scale_correction_factor, 20)
    assert_equal 1.0,  scorer.send(:scale_correction_factor, 100)
  end

  # ---------------------------------------------------------------------------
  # Blocker da re-revisão — posted_at nil não pode derrubar a pontuação do perfil
  # 1 post com posted_at nil (views_count presente) levantava TypeError em
  # `Time.current - post.posted_at` dentro do find_each → a pontuação do perfil
  # inteiro morria. Deve ser pulado silenciosamente: posts com data são pontuados.
  # ---------------------------------------------------------------------------
  test "post with nil posted_at is skipped without raising and other posts are scored" do
    # 10 baseline posts dentro da janela etária do alvo (alvo 12d → faixa 5..19d)
    10.times do |i|
      create(:social_post,
        social_profile: @profile,
        post_type: "video",
        posted_at: (8 + i).days.ago,
        views_count: 1000 + (i * 100)
      )
    end

    target_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: 12.days.ago,
      views_count: 10_000
    )

    # Post sem data e com views_count presente — o caso que matava o perfil inteiro
    nil_date_post = create(:social_post,
      social_profile: @profile,
      post_type: "video",
      posted_at: nil,
      views_count: 5000
    )

    assert_nothing_raised do
      Analytics::PostScorer.score_posts(profile: @profile)
    end

    # Posts com data são pontuados normalmente
    target_post.reload
    assert_not_nil target_post.performance_score
    assert_equal "excelente", target_post.performance_band

    # O post sem data é pulado silenciosamente: nada gravado → volta à fila
    # quando a coleta corrigir a data.
    nil_date_post.reload
    assert_nil nil_date_post.performance_score
    assert_nil nil_date_post.performance_band
    assert_nil nil_date_post.scored_at
  end
end
