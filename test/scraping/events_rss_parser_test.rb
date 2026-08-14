# frozen_string_literal: true

require 'test_helper'

class EventsRssParserTest < ActiveSupport::TestCase
  RSS_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Google News</title>
        <item>
          <title>BGS 2026: Brasil Game Show anuncia datas</title>
          <link>https://example.com/bgs2026</link>
          <description>Evento de games em São Paulo</description>
          <pubDate>Mon, 20 Mar 2026 12:00:00 GMT</pubDate>
        </item>
        <item>
          <title>CCXP 2026 terá atrações exclusivas</title>
          <link>https://example.com/ccxp2026</link>
          <description>Convenção de cultura pop</description>
          <pubDate>Tue, 21 Mar 2026 10:00:00 GMT</pubDate>
        </item>
        <item>
          <title>Anime Friends 2026: ingressos à venda</title>
          <link>https://example.com/animefriends2026</link>
          <description>Evento de anime no Brasil</description>
          <pubDate>Wed, 22 Mar 2026 08:00:00 GMT</pubDate>
        </item>
        <item>
          <title>Outro evento nerd qualquer</title>
          <link>https://example.com/other</link>
          <description>Descrição genérica</description>
          <pubDate>Thu, 23 Mar 2026 14:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
  XML

  test "fetch_events returns normalized array from RSS" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events

    assert events.is_a?(Array)
    assert events.size > 0
    events.each do |event|
      assert event.key?(:title)
      assert event.key?(:source_url)
      assert event.key?(:event_type)
    end
  end

  test "fetch_events infers bgs event type from title" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events
    bgs_event = events.find { |e| e[:title]&.include?("BGS") }

    assert_not_nil bgs_event
    assert_equal "bgs", bgs_event[:event_type]
  end

  test "fetch_events infers ccxp event type from title" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events
    ccxp_event = events.find { |e| e[:title]&.include?("CCXP") }

    assert_not_nil ccxp_event
    assert_equal "ccxp", ccxp_event[:event_type]
  end

  test "fetch_events infers anime_friends event type from title" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events
    af_event = events.find { |e| e[:title]&.include?("Anime Friends") }

    assert_not_nil af_event
    assert_equal "anime_friends", af_event[:event_type]
  end

  test "fetch_events returns other for unrecognized titles" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events
    other_event = events.find { |e| e[:title] == "Outro evento nerd qualquer" }

    assert_not_nil other_event
    assert_equal "other", other_event[:event_type]
  end

  test "fetch_events returns empty array on malformed XML" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: "<rss><channel><item><title>Broken")
    end

    events = ScrapingServices::EventsRssParser.fetch_events

    assert_equal [], events
  end

  test "fetch_events returns empty array on HTTP error" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 500, body: "Server Error")
    end

    events = ScrapingServices::EventsRssParser.fetch_events

    assert_equal [], events
  end

  test "parse_xml returns items with correct fields" do
    ScrapingServices::EventsRssParser::FEEDS.each do |feed|
      stub_request(:get, feed[:url])
        .to_return(status: 200, body: RSS_XML)
    end

    events = ScrapingServices::EventsRssParser.fetch_events
    first = events.first

    assert_equal "BGS 2026: Brasil Game Show anuncia datas", first[:title]
    assert_equal "https://example.com/bgs2026", first[:source_url]
    assert_equal "Evento de games em São Paulo", first[:description]
    assert_equal Time.parse("Mon, 20 Mar 2026 12:00:00 GMT"), first[:pub_date]
  end

  test "parse_xml handles invalid pubDate between valid items" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>Valid Event One</title>
            <link>https://example.com/one</link>
            <pubDate>Mon, 20 Mar 2026 12:00:00 GMT</pubDate>
          </item>
          <item>
            <title>Invalid PubDate Event</title>
            <link>https://example.com/invalid</link>
            <pubDate>N/A</pubDate>
          </item>
          <item>
            <title>Valid Event Two</title>
            <link>https://example.com/two</link>
            <pubDate>Tue, 21 Mar 2026 10:00:00 GMT</pubDate>
          </item>
        </channel>
      </rss>
    XML

    items = ScrapingServices::EventsRssParser.send(:parse_xml, xml)

    assert_equal 3, items.size
    assert_equal Time.parse("Mon, 20 Mar 2026 12:00:00 GMT"), items[0][:pub_date]
    assert_nil items[1][:pub_date]
    assert_equal Time.parse("Tue, 21 Mar 2026 10:00:00 GMT"), items[2][:pub_date]
  end
end
