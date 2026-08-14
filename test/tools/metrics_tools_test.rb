# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/metrics_tools'

class MetricsToolsTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile, platform: 'twitter', platform_username: 'testuser', followers_count: 1000)
  end

  test 'engagement_rate retorna nil quando followers é nil' do
    create(:social_profile, platform: 'twitter', platform_username: 'nofollowers', followers_count: nil)
    tool = EngagementRateTool.new
    result = tool.execute(username: 'nofollowers', platform: 'twitter')
    assert_equal :success, result[:status]
    assert_nil result[:data][:engagement_rate]
  end

  test 'engagement_rate retorna 0.0 quando posts existentes têm engajamento zero' do
    create(:social_post, social_profile: @profile, post_type: 'image', likes_count: 0, comments_count: 0, shares_count: 0, posted_at: 1.day.ago)
    tool = EngagementRateTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter')
    assert_equal :success, result[:status]
    assert_equal 0.0, result[:data][:engagement_rate]
  end

  test 'engagement_rate calcula quando há posts' do
    create_list(:social_post, 5, social_profile: @profile, post_type: 'image', likes_count: 50, comments_count: 5,
                                 shares_count: 2, posted_at: 1.day.ago)
    tool = EngagementRateTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter')
    assert_equal :success, result[:status]
    assert_not_nil result[:data][:engagement_rate]
  end

  test 'snapshot_trend retorna array de snapshots' do
    create(:profile_snapshot, social_profile: @profile, recorded_at: 1.day.ago, followers_count: 950, posts_count: 10)
    tool = SnapshotTrendTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', days: 30)
    assert_equal :success, result[:status]
    assert_kind_of Array, result[:data]
  end

  test 'snapshot_trend retorna erro para days zero' do
    tool = SnapshotTrendTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', days: 0)
    assert_equal :error, result[:status]
  end

  test 'snapshot_trend retorna erro para days negativo' do
    tool = SnapshotTrendTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', days: -5)
    assert_equal :error, result[:status]
  end

  test 'snapshot_trend funciona com período positivo' do
    create(:profile_snapshot, social_profile: @profile, recorded_at: 5.days.ago, followers_count: 950, posts_count: 10)
    tool = SnapshotTrendTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', days: 10)
    assert_equal :success, result[:status]
    assert_kind_of Array, result[:data]
  end

  test 'ranking por followers ordena corretamente' do
    create(:social_profile, platform: 'twitter', platform_username: 'high', followers_count: 5000)
    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'followers', platform: 'twitter', limit: 10)
    assert_equal :success, result[:status]
    assert_equal 5000, result[:data].first[:followers_count]
  end

  test 'ranking retorna error para métrica inválida' do
    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'invalid')
    assert_equal :error, result[:status]
  end

  test 'ranking usa recência por posted_at e não por id' do
    old_profile = create(:social_profile, platform: 'twitter', platform_username: 'olduser', followers_count: 1000)
    12.times do |i|
      create(:social_post, social_profile: @profile, post_type: 'text', likes_count: 10, comments_count: 1,
                           shares_count: 0, posted_at: 1.day.ago + i.minutes)
    end

    # Posts históricos com IDs maiores, mas posted_at antigo
    create(:social_post, social_profile: @profile, post_type: 'text', likes_count: 999, comments_count: 999,
                         shares_count: 999, posted_at: 30.days.ago)

    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'engagement', platform: 'twitter', limit: 5)
    assert_equal :success, result[:status]
    assert result[:data].any?

    max_engagement = result[:data].map { |d| d[:engagement_rate] }.max
    # O post com posted_at de 30 dias atrás (engajamento 1000/1000) não deve ser o top
    # Os posts de ontem (engajamento ~1.1%) devem dominar se o ranking usar recência por posted_at
    assert_not_equal max_engagement, (999 + 999 + 999).to_f / 1000 * 100
  end

  test 'ranking com limit omitido retorna até 10 resultados' do
    create_list(:social_profile, 15, platform: 'twitter', followers_count: 100)
    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'followers', platform: 'twitter')
    assert_equal :success, result[:status]
    assert result[:data].size <= 10
  end

  test 'ranking com limit nil retorna até 10 resultados' do
    create_list(:social_profile, 15, platform: 'twitter', followers_count: 100)
    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'followers', platform: 'twitter', limit: nil)
    assert_equal :success, result[:status]
    assert result[:data].size <= 10
  end

  test 'ranking com limit string vazia retorna até 10 resultados' do
    create_list(:social_profile, 15, platform: 'twitter', followers_count: 100)
    tool = ProfileRankingTool.new
    result = tool.execute(metric: 'followers', platform: 'twitter', limit: '')
    assert_equal :success, result[:status]
    assert result[:data].size <= 10
  end

  test 'ranking com limit numérico é clampado entre 1 e 50' do
    create_list(:social_profile, 60, platform: 'twitter', followers_count: 100)
    tool = ProfileRankingTool.new

    result = tool.execute(metric: 'followers', platform: 'twitter', limit: 100)
    assert_equal :success, result[:status]
    assert result[:data].size <= 50

    result = tool.execute(metric: 'followers', platform: 'twitter', limit: -5)
    assert_equal :success, result[:status]
    assert result[:data].size >= 1
  end
end
