# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/scraping/scrapers/ferrum_scraper_base"

class ScrapingServices::FerrumScraperBaseTest < ActiveSupport::TestCase
  class FakeBrowser
    attr_reader :call_order, :reset_called, :quit_called

    def initialize(raise_on_reset: false)
      @raise_on_reset = raise_on_reset
      @call_order = []
      @reset_called = false
      @quit_called = false
    end

    def reset
      @call_order << :reset
      @reset_called = true
      raise StandardError, "falha simulada no reset" if @raise_on_reset

      true
    end

    def quit
      @call_order << :quit
      @quit_called = true
      true
    end
  end

  setup do
    FerumConfig.stubs(:browser_options).returns({})
  end

  test "close chama browser.reset antes de browser.quit (Item 8)" do
    fake_browser = FakeBrowser.new
    Ferrum::Browser.stubs(:new).returns(fake_browser)

    scraper = ScrapingServices::FerrumScraperBase.new
    scraper.close

    assert_equal %i[reset quit], fake_browser.call_order
    assert_equal true, fake_browser.reset_called
    assert_equal true, fake_browser.quit_called
  end

  test "close chama browser.quit mesmo se browser.reset levantar excecao (Item 8)" do
    fake_browser = FakeBrowser.new(raise_on_reset: true)
    Ferrum::Browser.stubs(:new).returns(fake_browser)

    scraper = ScrapingServices::FerrumScraperBase.new
    scraper.close

    assert_equal %i[reset quit], fake_browser.call_order
    assert_equal true, fake_browser.quit_called
  end
end
