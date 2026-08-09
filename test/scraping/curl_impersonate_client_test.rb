# frozen_string_literal: true

require 'test_helper'

class CurlImpersonateClientTest < ActiveSupport::TestCase
  test 'defaults to chrome profile' do
    client = ScrapingServices::CurlImpersonateClient.new
    assert_equal :chrome, client.profile
  end

  test 'falls back to chrome for invalid profile' do
    client = ScrapingServices::CurlImpersonateClient.new(profile: :invalid)
    assert_equal :chrome, client.profile
  end

  test 'accepts valid profiles' do
    %i[chrome safari firefox chrome_android edge].each do |profile|
      client = ScrapingServices::CurlImpersonateClient.new(profile: profile)
      assert_equal profile, client.profile
    end
  end

  test 'stores proxy' do
    client = ScrapingServices::CurlImpersonateClient.new(proxy: 'http://proxy:8080')
    assert_equal 'http://proxy:8080', client.proxy
  end

  test 'build_command includes profile' do
    client = ScrapingServices::CurlImpersonateClient.new(profile: :safari)
    cmd = client.send(:build_command, 'https://example.com', method: 'GET')

    assert_includes cmd, 'safari'
    assert_includes cmd, '--profile'
  end

  test 'build_command includes proxy when set' do
    client = ScrapingServices::CurlImpersonateClient.new(proxy: 'http://proxy:8080')
    cmd = client.send(:build_command, 'https://example.com', method: 'GET')

    assert_includes cmd, '--proxy'
    assert_includes cmd, 'http://proxy:8080'
  end

  test 'build_command includes extra headers' do
    client = ScrapingServices::CurlImpersonateClient.new
    cmd = client.send(:build_command, 'https://example.com', method: 'GET', headers: { 'X-Custom' => 'value' })

    assert_includes cmd, '--header'
    assert_includes cmd, 'X-Custom:value'
  end

  test 'build_command includes body for POST' do
    client = ScrapingServices::CurlImpersonateClient.new
    cmd = client.send(:build_command, 'https://example.com', method: 'POST', body: 'data=1')

    assert_includes cmd, '--body'
    assert_includes cmd, 'data=1'
  end

  test 'get returns parsed result on success' do
    client = ScrapingServices::CurlImpersonateClient.new
    json_output = '{"success": true, "status_code": 200, "body": "<html>OK</html>"}'

    ScrapingServices::SidecarClient.expects(:capture).returns([json_output, '', stub(success?: true, exitstatus: 0)])

    result = client.get('https://example.com')

    assert_not_nil result
    assert result['success']
    assert_equal '<html>OK</html>', result['body']
  end

  test 'get returns nil when process fails' do
    client = ScrapingServices::CurlImpersonateClient.new

    ScrapingServices::SidecarClient.expects(:capture).returns(['', 'python error', stub(success?: false, exitstatus: 1)])

    result = client.get('https://example.com')
    assert_nil result
  end

  test 'get returns nil when success is false' do
    client = ScrapingServices::CurlImpersonateClient.new
    json_output = '{"success": false, "status_code": 403, "error": "blocked"}'

    ScrapingServices::SidecarClient.expects(:capture).returns([json_output, '', stub(success?: true, exitstatus: 0)])

    result = client.get('https://example.com')
    assert_nil result
  end

  test 'raises RateLimitError when rate_limit in output' do
    client = ScrapingServices::CurlImpersonateClient.new
    json_output = '{"success": false, "error": "rate_limit_429", "status_code": 429}'

    ScrapingServices::SidecarClient.expects(:capture).returns([json_output, '', stub(success?: true, exitstatus: 0)])

    assert_raises(ScrapingServices::RateLimitError) do
      client.get('https://example.com')
    end
  end

  test 'raises RateLimitError on 429 in stderr' do
    client = ScrapingServices::CurlImpersonateClient.new

    ScrapingServices::SidecarClient.expects(:capture).returns(['', 'HTTP 429 Too Many Requests', stub(success?: true, exitstatus: 0)])

    assert_raises(ScrapingServices::RateLimitError) do
      client.get('https://example.com')
    end
  end

  test 'raises RateLimitError on Captcha in stderr' do
    client = ScrapingServices::CurlImpersonateClient.new

    ScrapingServices::SidecarClient.expects(:capture).returns(['', 'Captcha detected', stub(success?: true, exitstatus: 0)])

    assert_raises(ScrapingServices::RateLimitError) do
      client.get('https://example.com')
    end
  end

  test 'returns nil on empty stdout' do
    client = ScrapingServices::CurlImpersonateClient.new

    ScrapingServices::SidecarClient.expects(:capture).returns(['', '', stub(success?: true, exitstatus: 0)])

    result = client.get('https://example.com')
    assert_nil result
  end

  test 'returns nil on invalid JSON' do
    client = ScrapingServices::CurlImpersonateClient.new

    ScrapingServices::SidecarClient.expects(:capture).returns(['not json', '', stub(success?: true, exitstatus: 0)])

    result = client.get('https://example.com')
    assert_nil result
  end

  test 'raises Timeout::Error when command times out' do
    client = ScrapingServices::CurlImpersonateClient.new

    Timeout.expects(:timeout).raises(Timeout::Error)

    assert_raises(Timeout::Error) do
      client.get('https://example.com')
    end
  end
end
