# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/discovery_tools'

class DiscoveryToolsTest < ActiveSupport::TestCase
  test 'prospects filtra por PATROCINADOR_PROSPECTO' do
    create(:discovered_profile, platform: 'twitter', username: 'prospect1', classification: 'PATROCINADOR_PROSPECTO')
    create(:discovered_profile, platform: 'twitter', username: 'other', classification: 'CONCORRENTE')

    tool = ProspectsTool.new
    result = tool.execute(limit: 10)
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_equal 'PATROCINADOR_PROSPECTO', result[:data].first[:classification]
  end

  test 'unclassified filtra por classification nil' do
    create(:discovered_profile, platform: 'twitter', username: 'unclassified1', classification: nil)
    create(:discovered_profile, platform: 'twitter', username: 'classified', classification: 'CONCORRENTE')

    tool = UnclassifiedProfilesTool.new
    result = tool.execute(limit: 10)
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_nil result[:data].first[:classification]
  end

  test 'prospects respeita limit e clamp' do
    create_list(:discovered_profile, 5, platform: 'twitter', classification: 'PATROCINADOR_PROSPECTO')
    tool = ProspectsTool.new
    result = tool.execute(limit: 2)
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
  end

  test 'prospects aplica clamp minimo para limit 0' do
    create_list(:discovered_profile, 3, platform: 'twitter', classification: 'PATROCINADOR_PROSPECTO')
    tool = ProspectsTool.new
    result = tool.execute(limit: 0)
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
  end

  test 'prospects aplica clamp maximo para limit 51' do
    create_list(:discovered_profile, 55, platform: 'twitter', classification: 'PATROCINADOR_PROSPECTO')
    tool = ProspectsTool.new
    result = tool.execute(limit: 51)
    assert_equal :success, result[:status]
    assert_equal 50, result[:data].size
  end
end
