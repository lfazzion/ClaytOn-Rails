# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/social_profile_tools'

class SocialProfileToolsTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile,
                      platform: 'twitter',
                      platform_username: 'testuser',
                      display_name: 'Test User',
                      followers_count: 1000,
                      bio: 'Influenciador de teste')
  end

  test 'lookup encontra perfil existente' do
    tool = ProfileLookupTool.new
    result = tool.execute(username: 'testuser', platform: 'twitter')
    assert_equal :success, result[:status]
    assert_equal 'testuser', result[:data][:username]
  end

  test 'lookup retorna error para perfil inexistente' do
    tool = ProfileLookupTool.new
    result = tool.execute(username: 'naoexiste', platform: 'twitter')
    assert_equal :error, result[:status]
  end

  test 'list respeita limit e clamp' do
    create_list(:social_profile, 5, platform: 'twitter')
    tool = ProfileListTool.new
    result = tool.execute(platform: 'twitter', limit: 3)
    assert_equal :success, result[:status]
    assert_operator result[:data].size, :<=, 3
  end

  test 'list sem platform retorna todos' do
    create(:social_profile, platform: 'instagram')
    tool = ProfileListTool.new
    result = tool.execute
    assert_equal :success, result[:status]
  end

  test 'search filtra por bio' do
    tool = ProfileSearchTool.new
    result = tool.execute(query: 'Influenciador')
    assert_equal :success, result[:status]
    assert(result[:data].any? { |p| p[:username] == 'testuser' })
  end

  test 'compare retorna hash comparativo' do
    create(:social_profile, platform: 'instagram', platform_username: 'otheruser')
    tool = ProfileCompareTool.new
    result = tool.execute(
      username_a: 'testuser', platform_a: 'twitter',
      username_b: 'otheruser', platform_b: 'instagram'
    )
    assert_equal :success, result[:status]
    assert_kind_of Hash, result[:data][:profile_a]
    assert_kind_of Hash, result[:data][:profile_b]
    assert_equal 'testuser', result[:data][:profile_a][:username]
    assert_equal 'twitter', result[:data][:profile_a][:platform]
    assert_equal 'otheruser', result[:data][:profile_b][:username]
    assert_equal 'instagram', result[:data][:profile_b][:platform]
  end

  test 'compare retorna error se perfil não encontrado' do
    tool = ProfileCompareTool.new
    result = tool.execute(
      username_a: 'testuser', platform_a: 'twitter',
      username_b: 'naoexiste', platform_b: 'instagram'
    )
    assert_equal :error, result[:status]
  end
end
