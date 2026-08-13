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
end
