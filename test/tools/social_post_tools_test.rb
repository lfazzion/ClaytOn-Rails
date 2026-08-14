# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/social_post_tools'

class SocialPostToolsTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile, platform: 'twitter', platform_username: 'testuser', followers_count: 1000)
    @post = create(:social_post,
                   social_profile: @profile,
                   post_type: 'image',
                   likes_count: 100,
                   comments_count: 10,
                   shares_count: 5,
                   posted_at: 1.day.ago)
  end

  test 'recent posts com limit clampado' do
    create_list(:social_post, 3, social_profile: @profile, post_type: 'text', posted_at: 2.days.ago)
    tool = RecentPostsTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', limit: 2)
    assert_equal :success, result[:status]
    assert_operator result[:data].size, :<=, 2
  end

  test 'recent posts retorna error para perfil inexistente' do
    tool = RecentPostsTool.new
    result = tool.execute(username: 'naoexiste', platform: 'twitter')
    assert_equal :error, result[:status]
  end

  test 'top posts ordenado por likes' do
    create(:social_post, social_profile: @profile, post_type: 'text', likes_count: 200, posted_at: 2.days.ago)
    tool = TopPostsTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter')
    assert_equal :success, result[:status]
    assert_equal 200, result[:data].first[:likes_count]
  end

  test 'by_type filtra corretamente' do
    create(:social_post, social_profile: @profile, post_type: 'video', posted_at: 2.days.ago)
    tool = PostsByTypeTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_type: 'image')
    assert_equal :success, result[:status]
    assert(result[:data].all? { |p| p[:post_type] == 'image' })
  end

  test 'by_type rejeita post_type invalido com lista de tipos aceitos' do
    tool = PostsByTypeTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_type: 'image_post')
    assert_equal :error, result[:status]
    assert_includes result[:reason], 'Tipo de post inválido'
    assert_includes result[:reason], 'image, video, text, reel, story, short'
  end

  test 'by_type retorna sucesso para post_type short' do
    create(:social_post, social_profile: @profile, post_type: 'short', posted_at: 1.day.ago)
    tool = PostsByTypeTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_type: 'short')
    assert_equal :success, result[:status]
    assert(result[:data].all? { |p| p[:post_type] == 'short' })
  end

  test 'by_type preserva filtro valido existente' do
    create(:social_post, social_profile: @profile, post_type: 'video', posted_at: 1.day.ago)
    create(:social_post, social_profile: @profile, post_type: 'image', posted_at: 1.day.ago)
    tool = PostsByTypeTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_type: 'video')
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_equal 'video', result[:data].first[:post_type]
  end

  test 'post_engagement retorna métricas' do
    tool = PostEngagementTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_id: @post.id)
    assert_equal :success, result[:status]
    assert_equal 115, result[:data][:engagement_count]
  end

  test 'post_engagement retorna error para post inexistente' do
    tool = PostEngagementTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter', post_id: 999_999)
    assert_equal :error, result[:status]
  end
end
