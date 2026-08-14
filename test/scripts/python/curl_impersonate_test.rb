# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

# Exercita `scripts/python/curl_impersonate.py` de verdade, com `curl_cffi`
# dublado via PYTHONPATH. O dublê registra os kwargs recebidos em um JSON
# lateral para que os testes possam afirmar sobre o contrato real emitido.
class CurlImpersonateScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join('scripts/python/curl_impersonate.py').to_s

  FAKE_REQUESTS = <<~PYTHON
    import json
    import os

    CALL_LOG = os.environ["FAKE_CURL_CALL_LOG"]
    FAKE_STATUS = os.environ.get("FAKE_STATUS", "200")
    FAKE_BODY = os.environ.get("FAKE_BODY", "<html>OK</html>")
    FAKE_RAISES = os.environ.get("FAKE_RAISES")

    _last_kwargs = {}

    def _dump():
        with open(CALL_LOG, "w", encoding="utf-8") as handle:
            json.dump(_last_kwargs, handle)

    class _Response:
        def __init__(self, status_code, text):
            self.status_code = status_code
            self.text = text
            self.url = "https://example.com/"
            self.headers = {"Content-Type": "text/html"}

    class _Requests:
        @staticmethod
        def request(method, url, **kwargs):
            _last_kwargs_global = dict(kwargs)
            _last_kwargs_global["method"] = method
            _last_kwargs_global["url"] = url
            global _last_kwargs
            _last_kwargs = _last_kwargs_global
            _dump()
            if FAKE_RAISES:
                raise Exception(FAKE_RAISES)
            return _Response(int(FAKE_STATUS), FAKE_BODY)

    class _Module:
        request = staticmethod(_Requests.request)

    class _Top:
        _Module = _Module
        # O script faz `from curl_cffi import requests` — o módulo top precisa
        # expor o atributo `requests`, senão ImportError e o stdout fica vazio
        # (JSON::ParserError nos testes). Fix do fake, não do produto.
        requests = _Module

    import sys
    sys.modules["curl_cffi"] = _Top()
    sys.modules["curl_cffi.requests"] = _Module
  PYTHON

  def run_script(url: 'https://example.com/', status: '200', body: '<html>OK</html>', raises: nil, extra_env: {})
    Dir.mktmpdir do |dir|
      package = File.join(dir, 'curl_cffi')
      FileUtils.mkdir_p(package)
      File.write(File.join(package, '__init__.py'), FAKE_REQUESTS)

      call_log = File.join(dir, 'call_log.json')
      env = {
        'PYTHONPATH' => dir,
        'FAKE_CURL_CALL_LOG' => call_log,
        'FAKE_STATUS' => status,
        'FAKE_BODY' => body
      }.merge(extra_env)

      if raises
        env['FAKE_RAISES'] = raises
      end

      stdout, stderr, status_obj = Open3.capture3(env, 'python3', '-u', SCRIPT_PATH, url)
      calls = File.exist?(call_log) ? JSON.parse(File.read(call_log)) : {}

      Result.new(stdout, stderr, status_obj, calls)
    end
  end

  class Result
    attr_reader :stdout, :stderr, :status, :calls

    def initialize(stdout, stderr, status, calls)
      @stdout = stdout
      @stderr = stderr
      @status = status
      @calls = calls
    end

    def json
      @json ||= JSON.parse(stdout.strip)
    end
  end

  # --- CORRECAO 1: TLS verification is not disabled ---

  test 'does not pass verify=False to curl_cffi' do
    result = run_script

    assert result.calls['verify'].nil?,
           "verify=False foi passado ao curl_cffi: #{result.calls.inspect}"
    assert_not result.calls.key?('verify'),
               "chave 'verify' presente nos kwargs do request: #{result.calls.inspect}"
  end

  test 'certificate error surfaces as success: false' do
    result = run_script(raises: 'SSLError: certificate verify failed')

    parsed = result.json
    assert_not parsed['success'],
             "erro de certificado deveria resultar em success=false, mas foi: #{parsed.inspect}"
    assert_match(/SSLError|certificate/i, parsed['error'])
  end

  # --- CORRECAO 2: 403 is not rate_limit, 429 is, 503 is unavailable ---

  test '429 is classified as rate_limit_429' do
    result = run_script(status: '429', body: 'too many requests')

    parsed = result.json
    assert_equal false, parsed['success']
    assert_equal 'rate_limit_429', parsed['error']
    assert_equal 429, parsed['status_code']
  end

  test '403 is not classified as rate_limit' do
    result = run_script(status: '403', body: 'forbidden')

    parsed = result.json
    assert_equal false, parsed['success']
    assert_equal 'blocked_403', parsed['error']
    assert_equal 403, parsed['status_code']
  end

  test '503 is classified as unavailable, not rate limit' do
    result = run_script(status: '503', body: 'service unavailable')

    parsed = result.json
    assert_equal false, parsed['success']
    assert_equal 'unavailable_503', parsed['error']
    refute_match(/rate_limit/, parsed['error'])
  end

  test '200 returns success with full body' do
    result = run_script(status: '200', body: '<html>OK</html>')

    parsed = result.json
    assert parsed['success']
    assert_equal 200, parsed['status_code']
    assert_equal '<html>OK</html>', parsed['body']
  end
end
