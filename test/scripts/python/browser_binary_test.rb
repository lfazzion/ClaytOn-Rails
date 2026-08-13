# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

# Exercita `scripts/python/browser_binary.py` de verdade, com o módulo
# `re`/`glob`/`os` reais. O script roda como subprocesso e devolve o caminho
# resolvido via stdout JSON.
class BrowserBinaryScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join('scripts/python/browser_binary.py').to_s

  def run_script(env: {})
    stdout, stderr, status = Open3.capture3(env, 'python3', '-u', SCRIPT_PATH)
    [stdout, stderr, status]
  end

  def call_find_chrome(env: {})
    env = { 'PYTHON_PATH' => Rails.root.join('scripts/python').to_s }.merge(env)
    # Importa o módulo Python e chama find_chrome() diretamente
    script = <<~PYTHON
      import sys, json, importlib.util
      spec = importlib.util.spec_from_file_location("browser_binary", "#{SCRIPT_PATH}")
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      result = mod.find_chrome()
      print(json.dumps({"result": result}))
    PYTHON
    stdout, stderr, status = Open3.capture3(env, 'python3', '-u', '-c', script)
    JSON.parse(stdout.strip)
  rescue JSON::ParserError
    { 'result' => nil, 'stderr' => stderr }
  end

  # --- CORRECAO 4: versões numéricas, não lexicográficas ---

  test 'seleciona chromium-1145 sobre chromium-999 (numérico, não lexicográfico)' do
    Dir.mktmpdir do |dir|
      # Cria a estrutura de diretórios como o playwright faria
      base = File.join(dir, 'chromium-1145', 'chrome-linux')
      FileUtils.mkdir_p(base)
      FileUtils.touch(File.join(base, 'chrome'))

      base2 = File.join(dir, 'chromium-999', 'chrome-linux')
      FileUtils.mkdir_p(base2)
      FileUtils.touch(File.join(base2, 'chrome'))

      # Monkeypatch CANDIDATE_GLOBS para apontar pro tmpdir
      env = {
        'CHROME_BIN' => nil,
        'PYTHONPATH' => ''
      }

      script = <<~PYTHON
        import sys, json, importlib.util, os
        spec = importlib.util.spec_from_file_location("browser_binary", "#{SCRIPT_PATH}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.CANDIDATE_GLOBS = (
            "#{dir}/chromium-*/chrome-linux/chrome",
        )
        result = mod.find_chrome()
        print(json.dumps({"result": result}))
      PYTHON

      stdout, stderr, status = Open3.capture3(env, 'python3', '-u', '-c', script)
      parsed = JSON.parse(stdout.strip)

      assert_match(/chromium-1145/, parsed['result'],
                   "deveria selecionar 1145 sobre 999 (ordem numérica), mas retornou: #{parsed['result']}")
    end
  end

  test 'seleciona chromium_headless_shell-100 sobre chromium-99 quando houver conflito' do
    # Garante que chromium_headless_shell- é extraído antes de chromium-
    # (ambos compartilham o prefixo "chromium-")
    Dir.mktmpdir do |dir|
      shell_dir = File.join(dir, 'chromium_headless_shell-100', 'chrome-linux')
      FileUtils.mkdir_p(shell_dir)
      FileUtils.touch(File.join(shell_dir, 'headless_shell'))

      env = { 'PYTHONPATH' => '' }

      script = <<~PYTHON
        import sys, json, importlib.util, os
        spec = importlib.util.spec_from_file_location("browser_binary", "#{SCRIPT_PATH}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.CANDIDATE_GLOBS = (
            "#{dir}/chromium_headless_shell-*/chrome-linux/headless_shell",
        )
        result = mod.find_chrome()
        print(json.dumps({"result": result}))
      PYTHON

      stdout, stderr, status = Open3.capture3(env, 'python3', '-u', '-c', script)
      parsed = JSON.parse(stdout.strip)

      assert_match(/chromium_headless_shell-100/, parsed['result'],
                   "deveria resolver headless_shell como 100: #{parsed['result']}")
    end
  end

  test 'CHROME_BIN explícito tem prioridade sobre glob resolvido' do
    Dir.mktmpdir do |dir|
      # Cria um binário no cache
      cache_dir = File.join(dir, 'chromium-1145', 'chrome-linux')
      FileUtils.mkdir_p(cache_dir)
      FileUtils.touch(File.join(cache_dir, 'chrome'))

      explicit = File.join(dir, 'meu_chrome_binario')
      FileUtils.touch(explicit)
      File.chmod(0755, explicit)

      env = { 'CHROME_BIN' => explicit, 'PYTHONPATH' => '' }

      script = <<~PYTHON
        import sys, json, importlib.util, os
        spec = importlib.util.spec_from_file_location("browser_binary", "#{SCRIPT_PATH}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.CANDIDATE_GLOBS = (
            "#{dir}/chromium-*/chrome-linux/chrome",
        )
        result = mod.find_chrome()
        print(json.dumps({"result": result}))
      PYTHON

      stdout, stderr, status = Open3.capture3(env, 'python3', '-u', '-c', script)
      parsed = JSON.parse(stdout.strip)

      assert_equal explicit, parsed['result'],
                   "CHROME_BIN explícito deveria ter prioridade: #{parsed['result']}"
    end
  end

  test '_version_key extrai número numérico corretamente' do
    script = <<~PYTHON
      import sys, json, importlib.util
      spec = importlib.util.spec_from_file_location("browser_binary", "#{SCRIPT_PATH}")
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      cases = {
          "chromium-999": mod._version_key("/foo/chromium-999/chrome-linux/chrome"),
          "chromium-1145": mod._version_key("/foo/chromium-1145/chrome-linux/chrome"),
          "headless_shell-100": mod._version_key("/foo/chromium_headless_shell-100/chrome-linux/headless_shell"),
          "sem_numero": mod._version_key("/foo/chromium/chrome-linux/chrome"),
      }
      print(json.dumps(cases))
    PYTHON

    stdout, stderr, status = Open3.capture3({ 'PYTHONPATH' => '' }, 'python3', '-u', '-c', script)
    parsed = JSON.parse(stdout.strip)

    assert_equal [999], parsed['chromium-999']
    assert_equal [1145], parsed['chromium-1145']
    assert_equal [100], parsed['headless_shell-100']
    assert_equal [0], parsed['sem_numero']

    # Ordenação numérica: 1145 > 999 (não lexicográfica: "999" > "1145").
    # _version_key devolve tupla (n,) — Array não responde a #>, comparar o
    # elemento numérico.
    assert_operator parsed['chromium-1145'].first, :>, parsed['chromium-999'].first,
                    "tupla 1145 deve ser maior que 999 (ordem numérica), não lexicográfica"
  end
end
