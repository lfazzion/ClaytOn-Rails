# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../../lib/llm/llm_chain_loader"

class Llm::LlmChainLoaderTest < ActiveSupport::TestCase
  # Helper: escreve `conteudo` num arquivo temporário e devolve o caminho.
  def arquivo_tmp(conteudo)
    Dir.mktmpdir do |dir|
      caminho = File.join(dir, "llm_chain.yml")
      File.write(caminho, conteudo)
      yield caminho
    end
  end

  YAML_VALIDO = <<~YAML.freeze
    version: 1
    chat:
      primary:
        label: nous
        provider: nous
        model: tencent/hy3:free
        effort: none
        params:
          tags: ["user=cleitin-bot"]
      fallback:
        label: openrouter
        provider: openrouter
        model: openrouter/free
        effort: null
        params: null
  YAML

  test "carga válida devolve primary e fallback normalizados" do
    arquivo_tmp(YAML_VALIDO) do |caminho|
      cfg = Llm::LlmChainLoader.new(path: caminho, logger: nil).load
      assert_equal :nous, cfg[:primary][:provider]
      assert_equal "tencent/hy3:free", cfg[:primary][:model]
      assert_equal({ tags: ["user=cleitin-bot"] }, cfg[:primary][:params])
      assert_equal :openrouter, cfg[:fallback][:provider]
    end
  end

  test "fallback null é aceito e normalizado como nil" do
    yaml = YAML_VALIDO.sub(/fallback:.*/m, "fallback: null")
    arquivo_tmp(yaml) do |caminho|
      cfg = Llm::LlmChainLoader.new(path: caminho, logger: nil).load
      assert_nil cfg[:fallback], "fallback: null deve normalizar para nil"
    end
  end

  test "arquivo ausente no primeiro boot devolve nil (cadeia vazia)" do
    Dir.mktmpdir do |dir|
      caminho = File.join(dir, "inexistente.yml")
      cfg = Llm::LlmChainLoader.new(path: caminho, logger: nil).load
      assert_nil cfg, "sem arquivo no primeiro boot, cadeia fica vazia (não mente)"
    end
  end

  test "YAML com version errado levanta ConfigError e first-boot devolve nil" do
    arquivo_tmp("version: 2\nchat:\n  primary:\n    provider: nous\n    model: x\n") do |caminho|
      loader = Llm::LlmChainLoader.new(path: caminho, logger: nil)
      assert_raises(Llm::LlmChainLoader::ConfigError) { loader.send(:parse_and_validate, "version: 2\nchat:\n  primary:\n    provider: nous\n    model: x\n") }
      # No método público, first-boot inválido => nil.
      assert_nil loader.load
    end
  end

  test "primary ausente é rejeitado (obrigatório)" do
    arquivo_tmp("version: 1\nchat:\n  fallback:\n    provider: openrouter\n    model: openrouter/free\n") do |caminho|
      loader = Llm::LlmChainLoader.new(path: caminho, logger: nil)
      assert_raises(Llm::LlmChainLoader::ConfigError) { loader.send(:parse_and_validate, "version: 1\nchat:\n  fallback:\n    provider: openrouter\n    model: openrouter/free\n") }
    end
  end

  test "aliases YAML são proibidos (safe_load)" do
    yaml_com_alias = "version: 1\ndefaults: &d\n  provider: nous\nchat:\n  primary:\n    <<: *d\n    model: x\n"
    arquivo_tmp(yaml_com_alias) do |caminho|
      loader = Llm::LlmChainLoader.new(path: caminho, logger: nil)
      # Valida o MESMO YAML que foi escrito (com `defaults: &d` / `<<: *d`),
      # não outro conteúdo. Com `aliases: false`, o YAML.safe_load levanta
      # Psych::BadAlias, que o loader embrulha em ConfigError.
      assert_raises(Llm::LlmChainLoader::ConfigError) { loader.send(:parse_and_validate, yaml_com_alias) }
    end
  end

  # CASO 4 (nível loader) — após carga válida, YAML corrompido mantém last-known-good
  # e LOGA APENAS UMA VEZ por digest.
  test "YAML inválido após carga válida mantém last-known-good e loga uma vez" do
    Dir.mktmpdir do |dir|
      caminho = File.join(dir, "llm_chain.yml")
      File.write(caminho, YAML_VALIDO)
      logs = []
      loader = Llm::LlmChainLoader.new(path: caminho, logger: ->(m) { logs << m })

      cfg1 = loader.load
      assert_equal "tencent/hy3:free", cfg1[:primary][:model]

      # Corrompe (primary vazio => ConfigError).
      File.write(caminho, "version: 1\nchat:\n  primary: {}\n")
      cfg2 = loader.load
      assert_equal "tencent/hy3:free", cfg2[:primary][:model], "mantém last-known-good"

      cfg3 = loader.load
      assert_equal "tencent/hy3:free", cfg3[:primary][:model]

      invalidos = logs.count { |m| m =~ /inválido/ }
      assert_equal 1, invalidos, "log de YAML inválido deve ser único por digest: #{logs.inspect}"
    end
  end

  # CASO 3 (nível loader) — reescrever o arquivo entre chamadas muda a config.
  test "reescrever o arquivo muda a configuração sem reiniciar" do
    Dir.mktmpdir do |dir|
      caminho = File.join(dir, "llm_chain.yml")
      File.write(caminho, YAML_VALIDO)
      loader = Llm::LlmChainLoader.new(path: caminho, logger: nil)
      assert_equal "tencent/hy3:free", loader.load[:primary][:model]

      File.write(caminho, <<~YAML)
        version: 1
        chat:
          primary:
            provider: openrouter
            model: openrouter/free
          fallback: null
      YAML
      assert_equal "openrouter/free", loader.load[:primary][:model]
    end
  end
end
