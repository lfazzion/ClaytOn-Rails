# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/scraping/scrapers/twitter_scraper'

class TwitterScraperTest < ActiveSupport::TestCase
  TOPIC = 'twitter_scraper_validation'

  setup do
    @scraper = ScrapingServices::TwitterScraper.allocate
    @scraper.stubs(:browser).returns(stub(evaluate: nil, goto: nil, at_css: nil, css: []))
    @scraper.stubs(:visit).returns(true)
    @scraper.stubs(:execute_script).returns(nil)
    @scraper.stubs(:random_delay)
  end

  # --- CORRECAO 1: handle validation ---

  test 'scrape_profile accepts valid handle' do
    @scraper.stubs(:execute_script).returns(JSON.generate({
      user_id: '123', username: 'john', display_name: 'John'
    }))
    assert_nothing_raised do
      @scraper.scrape_profile('john_doe')
    end
  end

  test 'scrape_tweets accepts valid handle' do
    @scraper.stubs(:execute_script).returns(JSON.generate([]))
    assert_nothing_raised do
      @scraper.scrape_tweets('john_doe')
    end
  end

  [
    '../etc/passwd',
    'foo/bar',
    'foo\\bar',
    'foo?bar=1',
    'foo#fragment',
    'foo bar',
    'foo;drop',
    'foo|bar',
    'user@domain',
    'a' * 16,
    '',
    nil
  ].each do |bad|
    test "scrape_profile rejects invalid handle: #{bad.inspect}" do
      @scraper.expects(:visit).never
      assert_raises(ArgumentError) do
        @scraper.scrape_profile(bad)
      end
    end

    test "scrape_tweets rejects invalid handle: #{bad.inspect}" do
      @scraper.expects(:visit).never
      assert_raises(ArgumentError) do
        @scraper.scrape_tweets(bad)
      end
    end
  end

  test 'scrape_profile rejects path traversal' do
      @scraper.expects(:visit).never
    assert_raises(ArgumentError) do
      @scraper.scrape_profile('../etc/passwd')
    end
  end

  test 'scrape_profile rejects slash' do
      @scraper.expects(:visit).never
    assert_raises(ArgumentError) do
      @scraper.scrape_profile('foo/bar')
    end
  end

  test 'scrape_profile rejects backslash' do
      @scraper.expects(:visit).never
    assert_raises(ArgumentError) do
      @scraper.scrape_profile('foo\\bar')
    end
  end

  test 'scrape_profile rejects query string' do
      @scraper.expects(:visit).never
    assert_raises(ArgumentError) do
      @scraper.scrape_profile('foo?bar=1')
    end
  end

  test 'scrape_profile rejects fragment' do
      @scraper.expects(:visit).never
    assert_raises(ArgumentError) do
      @scraper.scrape_profile('foo#fragment')
    end
  end

  test 'scrape_profile accepts x_ prefixed handle and preserves x_ prefix in URL' do
    @scraper.expects(:visit).with('https://x.com/x_john_doe', wait_for: "[data-testid='UserName']")
    @scraper.stubs(:execute_script).returns(JSON.generate({
      user_id: '123', username: 'x_john_doe', display_name: 'John'
    }))
    assert_nothing_raised do
      @scraper.scrape_profile('x_john_doe')
    end
  end

  # --- CORRECAO 2: JS error is not rate limit ---

  test 'scrape_profile with error key raises ScrapingError, not RateLimitError' do
    error_msg = 'DOM changed'
    @scraper.stubs(:execute_script).returns(JSON.generate({ error: error_msg }))

    raised = nil
    begin
      @scraper.scrape_profile('john_doe')
    rescue ScrapingServices::TwitterScraper::ScrapingError => e
      raised = e
    rescue ScrapingServices::RateLimitError => e
      flunk "Expected ScrapingError, got RateLimitError: #{e.message}"
    end
    assert_kind_of ScrapingServices::TwitterScraper::ScrapingError, raised
    assert_equal error_msg, raised.message
  end

  test 'scrape_profile returns nil on JSON parse error' do
    @scraper.stubs(:execute_script).returns('not json')
    result = @scraper.scrape_profile('john_doe')
    assert_nil result
  end
end
