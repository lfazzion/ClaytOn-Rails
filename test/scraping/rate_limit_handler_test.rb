# frozen_string_literal: true

require 'test_helper'

class RateLimitHandlerTest < ActiveSupport::TestCase
  test 'rate_limited? matches 429 pattern' do
    error = StandardError.new('HTTP 429 Too Many Requests')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? does NOT match isolated 403 without explicit text' do
    error = StandardError.new('HTTP 403 Forbidden')
    refute ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? does NOT match isolated 503 without explicit text' do
    error = StandardError.new('HTTP 503 Service Unavailable')
    refute ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches cloudflare pattern' do
    error = StandardError.new('Cloudflare WAF blocked request')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches cloudflare pattern without status code' do
    error = StandardError.new('Cloudflare challenge detected')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches rate limit text without status code' do
    error = StandardError.new('Rate limit exceeded')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches blocked text without status code' do
    error = StandardError.new('Request blocked by firewall')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches captcha pattern' do
    error = StandardError.new('Captcha verification required')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? does NOT match 403 with unrelated text' do
    error = StandardError.new('HTTP 403 Forbidden - access denied')
    refute ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches 403 blocked (explicit text)' do
    error = StandardError.new('HTTP 403 blocked by administrator')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches 503 rate limit (explicit text)' do
    error = StandardError.new('HTTP 503 rate limit exceeded')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches 503 with cloudflare text' do
    error = StandardError.new('HTTP 503 Cloudflare challenge')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'rate_limited? matches Retry-After header in context' do
    error = StandardError.new('HTTP 403 Forbidden')
    assert ScrapingServices::RateLimitHandler.rate_limited?(error, retry_after: '120')
  end

  test 'rate_limited? returns false for unrelated errors' do
    error = StandardError.new('Connection refused')
    refute ScrapingServices::RateLimitHandler.rate_limited?(error)
  end

  test 'determine_backoff returns 12h for cloudflare' do
    error = StandardError.new('Cloudflare challenge detected')
    backoff = ScrapingServices::RateLimitHandler.determine_backoff(error)

    assert_equal 12.hours, backoff
  end

  test 'determine_backoff returns 12h for datadome' do
    error = StandardError.new('DataDome bot detection triggered')
    backoff = ScrapingServices::RateLimitHandler.determine_backoff(error)

    assert_equal 12.hours, backoff
  end

  test 'determine_backoff returns 2h for 429' do
    error = StandardError.new('HTTP 429 rate limit exceeded')
    backoff = ScrapingServices::RateLimitHandler.determine_backoff(error)

    assert_equal 2.hours, backoff
  end

  test 'determine_backoff returns 12h when retry_count > 2' do
    error = StandardError.new('HTTP 429')
    backoff = ScrapingServices::RateLimitHandler.determine_backoff(error, retry_count: 3)

    assert_equal 12.hours, backoff
  end

  test 'determine_backoff returns 6h for default' do
    error = StandardError.new('HTTP 403 Forbidden - general error')
    backoff = ScrapingServices::RateLimitHandler.determine_backoff(error)

    assert_equal 6.hours, backoff
  end

  test 'suspicious_block? detects connection reset' do
    error = StandardError.new('Connection reset by peer')
    assert ScrapingServices::RateLimitHandler.suspicious_block?(error)
  end

  test 'suspicious_block? detects timeout' do
    error = StandardError.new('Net::ReadTimeout')
    assert ScrapingServices::RateLimitHandler.suspicious_block?(error)
  end

  test 'suspicious_block? detects empty response' do
    error = StandardError.new('Empty response from server')
    assert ScrapingServices::RateLimitHandler.suspicious_block?(error)
  end

  test 'handle_error raises RateLimitError with retry_after' do
    error = StandardError.new('HTTP 429 Too Many Requests')

    raised = assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::RateLimitHandler.handle_error(error)
    end

    assert_equal 2.hours, raised.retry_after
    assert_equal error, raised.original_error
  end

  test 'handle_error re-raises error when not rate limited' do
    error = StandardError.new('Connection refused')
    assert_raises(StandardError) { ScrapingServices::RateLimitHandler.handle_error(error) }
  end

  test 'handle_error raises RateLimitError for 403 blocked with context' do
    error = StandardError.new('HTTP 403 blocked')
    raised = assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::RateLimitHandler.handle_error(error, retry_after: '60')
    end
    assert_equal error, raised.original_error
    assert_equal 60, raised.retry_after
  end

  test 'handle_error raises RateLimitError with Retry-After header' do
    error = StandardError.new('HTTP 429 Too Many Requests')
    raised = assert_raises(ScrapingServices::RateLimitError) do
      ScrapingServices::RateLimitHandler.handle_error(error, retry_after: '120')
    end
    assert_equal 120, raised.retry_after
  end

  test 'determine_backoff parses String retry_after into numeric seconds' do
    error = StandardError.new('Rate limited')
    assert_equal 120, ScrapingServices::RateLimitHandler.determine_backoff(error, retry_after: '120')
    assert_equal 120.5, ScrapingServices::RateLimitHandler.determine_backoff(error, retry_after: '120.5')
    assert_kind_of Numeric, ScrapingServices::RateLimitHandler.determine_backoff(error, retry_after: '60')
  end
end
