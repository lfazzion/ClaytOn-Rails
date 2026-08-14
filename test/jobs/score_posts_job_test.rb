# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/jobs/score_posts_job'
require_relative '../../app/services/analytics/post_scorer'

class ScorePostsJobTest < ActiveJob::TestCase
  test 'score_posts_job raises on unexpected scorer failure and logs context' do
    profile1 = create(:social_profile, :youtube, monitoring_status: 'active')
    profile2 = create(:social_profile, :twitter, monitoring_status: 'active')

    Analytics::PostScorer.expects(:score_posts).with(profile: profile1).raises(StandardError.new('Scoring failed'))

    linhas = []
    # Matcher com bloco captura TODAS as chamadas de error (incluindo as do
    # ActiveJob LogSubscriber) — filtrar as do job no assert.
    Rails.logger.stubs(:error).with { |m| linhas << m.to_s; true }

    err = assert_raises(StandardError) do
      ScorePostsJob.perform_now
    end
    assert_equal 'Scoring failed', err.message

    linhas_job = linhas.select { |l| l.include?("[ScorePostsJob]") }
    assert_match(/Erro ao pontuar perfil #{profile1.id} \(youtube\)/, linhas_job.join("\n"))
    assert_match(/StandardError/, linhas_job.join("\n"))
    assert_match(/Scoring failed/, linhas_job.join("\n"))
    # profile2 nunca e atingido porque a excecao de profile1 propaga
    assert_equal 1, linhas_job.size
  end

  test 'score_posts_job succeeds and calls scorer for all monitored profiles' do
    profile1 = create(:social_profile, :youtube, monitoring_status: 'active')
    profile2 = create(:social_profile, :twitter, monitoring_status: 'active')

    Analytics::PostScorer.expects(:score_posts).with(profile: profile1).returns(true)
    Analytics::PostScorer.expects(:score_posts).with(profile: profile2).returns(true)

    assert_nothing_raised do
      ScorePostsJob.perform_now
    end
  end

  test 'score_posts_job logs error context for first failing profile in a batch' do
    profile1 = create(:social_profile, :youtube, monitoring_status: 'active')
    profile2 = create(:social_profile, :twitter, monitoring_status: 'active')

    Analytics::PostScorer.expects(:score_posts).with(profile: profile1).raises(StandardError.new('boom'))
    Analytics::PostScorer.expects(:score_posts).with(profile: profile2).never

    linhas = []
    Rails.logger.stubs(:error).with { |m| linhas << m.to_s; true }

    assert_raises(StandardError) do
      ScorePostsJob.perform_now
    end

    texto = linhas.join("\n")
    assert_match(/ScorePostsJob/, texto)
    assert_match(/perfil #{profile1.id}/, texto)
    assert_match(/youtube/, texto)
    assert_match(/StandardError/, texto)
    assert_match(/boom/, texto)
  end
end
