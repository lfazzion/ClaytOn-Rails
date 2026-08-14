# frozen_string_literal: true

require 'test_helper'

class RssParserServiceTest < ActiveSupport::TestCase
  test 'parse_feed returns articles from valid RSS' do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Google News</title>
          <item>
            <title>Test Article</title>
            <link>https://example.com/article1</link>
            <description>Test description</description>
            <pubDate>Mon, 20 Mar 2026 12:00:00 GMT</pubDate>
            <source>Example Source</source>
          </item>
          <item>
            <title>Another Article</title>
            <link>https://example.com/article2</link>
            <description>Another description</description>
            <pubDate>Tue, 21 Mar 2026 10:00:00 GMT</pubDate>
            <source>Another Source</source>
          </item>
        </channel>
      </rss>
    XML

    articles = ScrapingServices::RssParserService.send(:parse_feed, xml)

    assert_equal 2, articles.size
    assert_equal 'Test Article', articles.first[:title]
    assert_equal 'https://example.com/article1', articles.first[:link]
    assert_equal 'Example Source', articles.first[:source]
    assert articles.first[:pub_date].is_a?(Time)
  end

  test 'parse_feed handles malformed HTML gracefully' do
    xml = '<rss><channel><item><title>Broken'

    articles = ScrapingServices::RssParserService.send(:parse_feed, xml)

    assert_empty articles
  end

  test 'parse_feed handles nil values in items' do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <item>
            <link>https://example.com/article</link>
          </item>
        </channel>
      </rss>
    XML

    articles = ScrapingServices::RssParserService.send(:parse_feed, xml)

    assert_equal 1, articles.size
    assert_nil articles.first[:title]
    assert_equal 'https://example.com/article', articles.first[:link]
  end

  test 'parse_feed handles invalid pubDate values without breaking the batch' do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>Valid Article One</title>
            <link>https://example.com/article1</link>
            <pubDate>Mon, 20 Mar 2026 12:00:00 GMT</pubDate>
          </item>
          <item>
            <title>Invalid PubDate Article</title>
            <link>https://example.com/article2</link>
            <pubDate>N/A</pubDate>
          </item>
          <item>
            <title>Empty PubDate Article</title>
            <link>https://example.com/article3</link>
            <pubDate></pubDate>
          </item>
          <item>
            <title>Valid Article Two</title>
            <link>https://example.com/article4</link>
            <pubDate>Tue, 21 Mar 2026 10:00:00 GMT</pubDate>
          </item>
        </channel>
      </rss>
    XML

    articles = ScrapingServices::RssParserService.send(:parse_feed, xml)

    assert_equal 4, articles.size
    assert articles[0][:pub_date].is_a?(Time)
    assert_nil articles[1][:pub_date]
    assert_nil articles[2][:pub_date]
    assert articles[3][:pub_date].is_a?(Time)
  end
end
