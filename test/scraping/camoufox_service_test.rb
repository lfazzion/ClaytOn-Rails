# frozen_string_literal: true

require 'test_helper'

class CamoufoxServiceTest < ActiveSupport::TestCase
  TIMEOUT = ScrapingServices::CamoufoxService::TIMEOUT

  def expect_sidecar(args:, stdout: '', stderr: '', success: true)
    ScrapingServices::SidecarClient
      .expects(:capture)
      .with(script: 'camoufox_scrape.py', args: args, timeout: TIMEOUT)
      .returns([stdout, stderr, stub(success?: success, exitstatus: success ? 0 : 1)])
  end

  def stub_sidecar(stdout: '', stderr: '', success: true)
    ScrapingServices::SidecarClient
      .expects(:capture)
      .returns([stdout, stderr, stub(success?: success, exitstatus: success ? 0 : 1)])
  end

  test 'scrape_url builds correct command without proxy' do
    expect_sidecar(
      args: ['https://example.com'],
      stdout: '{"title": "Example", "content": "Hello world"}'
    )

    result = ScrapingServices::CamoufoxService.scrape_url('https://example.com')

    assert_not_nil result
    assert_equal 'Example', result[:title]
    assert_equal 'Hello world', result[:content]
  end

  test 'scrape_url builds command with proxy' do
    expect_sidecar(
      args: ['https://example.com', '--proxy', 'http://proxy:8080'],
      stdout: '{"title": "Example"}'
    )

    result = ScrapingServices::CamoufoxService.scrape_url('https://example.com', proxy: 'http://proxy:8080')
    assert_not_nil result
  end

  test 'scrape_batch returns array of url/data pairs' do
    urls = ['https://example.com/1', 'https://example.com/2']

    ScrapingServices::SidecarClient.expects(:capture).twice.returns(
      ['{"title": "Page 1"}', '', stub(success?: true, exitstatus: 0)],
      ['{"title": "Page 2"}', '', stub(success?: true, exitstatus: 0)]
    )

    results = ScrapingServices::CamoufoxService.scrape_batch(urls)

    assert_equal 2, results.size
    assert_equal 'https://example.com/1', results.first[:url]
    assert_equal 'Page 1', results.first[:data][:title]
  end

  test 'returns nil when stdout is empty' do
    stub_sidecar(stdout: '')

    result = ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    assert_nil result
  end

  test 'returns nil when process fails' do
    stub_sidecar(stderr: 'error', success: false)

    result = ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    assert_nil result
  end

  test 'raises RateLimitError on 429 in stderr' do
    stub_sidecar(stderr: 'HTTP 429 rate limit', success: false)

    assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    end
  end

  test 'raises RateLimitError on Blocked in stderr' do
    stub_sidecar(stderr: 'Blocked by Cloudflare', success: false)

    assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    end
  end

  test 'returns nil on invalid JSON' do
    stub_sidecar(stdout: 'not json')

    result = ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    assert_nil result
  end

  test 'raises Timeout::Error when sidecar call times out' do
    Timeout.expects(:timeout).raises(Timeout::Error)

    assert_raises(Timeout::Error) do
      ScrapingServices::CamoufoxService.scrape_url('https://example.com')
    end
  end
end
