# frozen_string_literal: true

require 'test_helper'

class NodriverRunnerTest < ActiveSupport::TestCase
  # Os scripts rodam no sidecar python-scraper (é o único container com nodriver
  # instalado), então o que se verifica aqui é o par script + args enviado a ele.
  def expect_sidecar(script:, args:, stdout: '', stderr: '', success: true, exitstatus: nil)
    ScrapingServices::SidecarClient
      .expects(:capture)
      .with(script: script, args: args, timeout: ScrapingServices::NodriverRunner::TIMEOUT)
      .returns([stdout, stderr, stub(success?: success, exitstatus: exitstatus || (success ? 0 : 1))])
  end

  def stub_sidecar(stdout: '', stderr: '', success: true, exitstatus: nil)
    ScrapingServices::SidecarClient
      .expects(:capture)
      .returns([stdout, stderr, stub(success?: success, exitstatus: exitstatus || (success ? 0 : 1))])
  end

  test 'scrape_instagram_profile builds correct command' do
    expect_sidecar(
      script: 'nodriver_instagram.py',
      args: ['testuser', '--mode', 'profile'],
      stdout: '{"user_id": "123", "username": "testuser", "full_name": "Test"}'
    )

    result = ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')

    assert_not_nil result
    assert_equal '123', result[:user_id]
    assert_equal 'testuser', result[:username]
  end

  test 'scrape_instagram_posts builds command with limit' do
    expect_sidecar(
      script: 'nodriver_instagram.py',
      args: ['testuser', '--mode', 'posts', '--limit', '6'],
      stdout: '[{"platform_post_id": "p1", "caption": "Post 1"}]'
    )

    result = ScrapingServices::NodriverRunner.scrape_instagram_posts('testuser', limit: 6)

    assert_equal 1, result.size
    assert_equal 'p1', result.first[:platform_post_id]
  end

  test 'scrape_instagram_posts builds command with proxy' do
    expect_sidecar(
      script: 'nodriver_instagram.py',
      args: ['testuser', '--mode', 'posts', '--limit', '12', '--proxy', 'http://proxy:8080'],
      stdout: '[]'
    )

    result = ScrapingServices::NodriverRunner.scrape_instagram_posts('testuser', proxy: 'http://proxy:8080')
    assert_empty result
  end

  test 'scrape_twitter_profile uses nodriver_twitter.py script' do
    expect_sidecar(
      script: 'nodriver_twitter.py',
      args: ['twitteruser', '--mode', 'profile'],
      stdout: '{"user_id": "456", "username": "twitteruser", "full_name": "Twitter User"}'
    )

    result = ScrapingServices::NodriverRunner.scrape_twitter_profile('twitteruser')

    assert_not_nil result
    assert_equal '456', result[:user_id]
    assert_equal 'twitteruser', result[:username]
  end

  test 'fetch_page delega nodriver_fetch.py ao sidecar' do
    expect_sidecar(
      script: 'nodriver_fetch.py',
      args: ['https://blocked.example/page'],
      stdout: '{"title": "T", "url": "https://blocked.example/page", "content": "corpo"}'
    )

    result = ScrapingServices::NodriverRunner.fetch_page('https://blocked.example/page')

    assert_equal 'T', result[:title]
    assert_equal 'corpo', result[:content]
  end

  test 'returns nil when stdout is empty' do
    stub_sidecar(stdout: '')

    result = ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    assert_nil result
  end

  test 'returns nil when process fails' do
    stub_sidecar(stderr: 'error', success: false)

    result = ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    assert_nil result
  end

  test 'raises RateLimitError on 429 in stderr' do
    stub_sidecar(stderr: 'HTTP 429 Too Many Requests', success: false)

    assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    end
  end

  test 'raises RateLimitError on Captcha in stderr' do
    stub_sidecar(stderr: 'Captcha detected', success: false)

    assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    end
  end

  test 'raises StandardError on 403 Forbidden in stderr (não é rate limit)' do
    stub_sidecar(stderr: '403 Forbidden', success: false)

    # DECISÃO 5: 403/503 isolados NÃO são mais rate limit — só quando
    # acompanhados de texto explícito (blocked/captcha/etc). 403 puro sobe
    # como StandardError (erro operacional), não RateLimitError.
    assert_raises(StandardError) do
      ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    end
  end

  test 'returns nil on invalid JSON' do
    stub_sidecar(stdout: 'not json')

    result = ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    assert_nil result
  end

  test 'raises Timeout::Error when sidecar call times out' do
    Timeout.expects(:timeout).raises(Timeout::Error)

    assert_raises(Timeout::Error) do
      ScrapingServices::NodriverRunner.scrape_instagram_profile('testuser')
    end
  end
end
