# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/news_tools'

class NewsToolsTest < ActiveSupport::TestCase
  test 'recent_articles retorna artigos recentes' do
    create(:news_article, title: 'Artigo A', source: 'tech', link: 'https://example.com/a', pub_date: 1.day.ago)
    create(:news_article, title: 'Artigo B', source: 'games', link: 'https://example.com/b', pub_date: 2.days.ago)

    tool = RecentArticlesTool.new
    result = tool.execute
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
  end

  test 'recent_articles com source filter' do
    create(:news_article, title: 'Tech Article', source: 'tech', link: 'https://example.com/tech', pub_date: 1.day.ago)
    create(:news_article, title: 'Games Article', source: 'games', link: 'https://example.com/games',
                          pub_date: 2.days.ago)

    tool = RecentArticlesTool.new
    result = tool.execute(source: 'tech')
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_equal 'tech', result[:data].first[:source]
  end

  test 'recent_articles respeita limit' do
    5.times { |i| create(:news_article, link: "https://example.com/article/#{i}", pub_date: 1.day.ago) }
    tool = RecentArticlesTool.new
    result = tool.execute(limit: 2)
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
  end
end
