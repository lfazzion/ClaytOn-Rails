# frozen_string_literal: true

require 'test_helper'

class SidecarClientTest < ActiveSupport::TestCase
  RUN_URL = 'http://python-scraper:8080/run'

  setup do
    @previous_url = ENV['PYTHON_SCRAPER_URL']
    @previous_token = ENV['PYTHON_SCRAPER_TOKEN']
    ENV['PYTHON_SCRAPER_URL'] = 'http://python-scraper:8080'
    ENV['PYTHON_SCRAPER_TOKEN'] = nil
  end

  teardown do
    ENV['PYTHON_SCRAPER_URL'] = @previous_url
    ENV['PYTHON_SCRAPER_TOKEN'] = @previous_token
  end

  test 'envia script e args e devolve a tripla do Open3' do
    stub_request(:post, RUN_URL)
      .with(body: { script: 'nodriver_fetch.py', args: ['https://a.test'], timeout: 180 }.to_json)
      .to_return(
        status: 200,
        body: { exit_code: 0, timed_out: false, stdout: '{"title":"T"}', stderr: '', data: { 'title' => 'T' } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stdout, stderr, status = ScrapingServices::SidecarClient.capture(
      script: 'nodriver_fetch.py', args: ['https://a.test']
    )

    assert_equal '{"title":"T"}', stdout
    assert_equal '', stderr
    assert_predicate status, :success?
    assert_equal 0, status.exitstatus
  end

  test 'exit code diferente de zero não é sucesso' do
    stub_request(:post, RUN_URL).to_return(
      status: 200,
      body: { exit_code: 2, timed_out: false, stdout: '', stderr: 'boom', data: nil }.to_json
    )

    stdout, stderr, status = ScrapingServices::SidecarClient.capture(script: 'camoufox_scrape.py', args: [])

    assert_equal '', stdout
    assert_equal 'boom', stderr
    assert_not status.success?
    assert_equal 2, status.exitstatus
  end

  test 'timeout no sidecar vira exit 124 com stderr explicativo' do
    stub_request(:post, RUN_URL).to_return(
      status: 200,
      body: { exit_code: nil, timed_out: true, stdout: '', stderr: 'timeout de 180s no sidecar', data: nil }.to_json
    )

    _stdout, stderr, status = ScrapingServices::SidecarClient.capture(script: 'camoufox_scrape.py', args: [])

    assert_not status.success?
    assert_equal 124, status.exitstatus
    assert_match(/timeout/i, stderr)
  end

  test 'sidecar fora do ar degrada para falha, não explode' do
    stub_request(:post, RUN_URL).to_raise(Errno::ECONNREFUSED)

    stdout, stderr, status = ScrapingServices::SidecarClient.capture(script: 'camoufox_scrape.py', args: [])

    assert_equal '', stdout
    assert_match(/sidecar indisponível/i, stderr)
    assert_not status.success?
  end

  test 'erro HTTP do sidecar vira falha com a mensagem do corpo' do
    stub_request(:post, RUN_URL).to_return(status: 400, body: { error: 'script não permitido' }.to_json)

    _stdout, stderr, status = ScrapingServices::SidecarClient.capture(script: 'evil.py', args: [])

    assert_not status.success?
    assert_match(/script não permitido/, stderr)
  end

  test 'manda bearer token quando configurado' do
    ENV['PYTHON_SCRAPER_TOKEN'] = 'segredo'

    stub_request(:post, RUN_URL)
      .with(headers: { 'Authorization' => 'Bearer segredo' })
      .to_return(status: 200, body: { exit_code: 0, timed_out: false, stdout: '{}', stderr: '' }.to_json)

    _stdout, _stderr, status = ScrapingServices::SidecarClient.capture(script: 'camoufox_scrape.py', args: [])

    assert_predicate status, :success?
  end

  test 'respeita PYTHON_SCRAPER_URL' do
    ENV['PYTHON_SCRAPER_URL'] = 'http://outro-host:9999'
    stub_request(:post, 'http://outro-host:9999/run')
      .to_return(status: 200, body: { exit_code: 0, timed_out: false, stdout: '{}', stderr: '' }.to_json)

    _stdout, _stderr, status = ScrapingServices::SidecarClient.capture(script: 'camoufox_scrape.py', args: [])

    assert_predicate status, :success?
  end
end
