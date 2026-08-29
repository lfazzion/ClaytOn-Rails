# frozen_string_literal: true

require "test_helper"
require "pathname"
require_relative "../../../lib/llm/model_chain"
require_relative "../../../lib/llm/llm_chain_loader"

class Llm::ModelChainTest < ActiveSupport::TestCase
  # Chaves que model_chain lê de ENV. Todas apagadas por padrão; o teste liga o
  # que o cenário exige. Troca ENV e devolve ao que era, inclusive no erro.
  ENV_KEYS = %w[NOUS_API_KEY OPENROUTER_API_KEY POOLSIDE_API_KEY NVIDIA_API_KEY
                DISCORD_EFFORT_NOUS DISCORD_POOLSIDE_THINKING].freeze

  def com_env(valores)
    anteriores = ENV_KEYS.index_with { |chave| ENV[chave] }
    ENV_KEYS.each { |chave| ENV.delete(chave) }
    valores.each { |chave, valor| valor.nil? ? ENV.delete(chave.to_s) : ENV[chave.to_s] = valor }
    yield
  ensure
    ENV_KEYS.each { |chave| anteriores[chave].nil? ? ENV.delete(chave) : ENV[chave] = anteriores[chave] }
  end

  # Redefine uma constante de classe durante o bloco e restaura no ensure.
  # `links` referencia CHAIN_CONFIG_PATH como constante nua, resolvida por
  # lexical scope em tempo de execução — então trocar a constante redireciona a
  # leitura sem acoplar o teste à localização de produção.
  def stub_const(klass, const, valor)
    original = klass.const_defined?(const, false) ? klass.const_get(const, false) : :__undef__
    klass.send(:remove_const, const) if klass.const_defined?(const, false)
    klass.const_set(const, valor)
    yield
  ensure
    klass.send(:remove_const, const) if klass.const_defined?(const, false)
    klass.const_set(const, original) unless original == :__undef__
  end

  # Escreve um YAML de cadeia em arquivo temporário, aponta o loader para ele e
  # devolve o caminho (para quem precisa reescrever/corromper entre chamadas).
  def com_yaml(conteudo)
    Dir.mktmpdir do |dir|
      caminho = File.join(dir, "llm_chain.yml")
      File.write(caminho, conteudo)
      Llm::LlmChainLoader.state_mutex.synchronize { Llm::LlmChainLoader.state.delete(caminho) }
      stub_const(Llm::ModelChain, :CHAIN_CONFIG_PATH, Pathname.new(caminho)) do
        yield caminho
      end
    end
  end

  # ---- YAML base reutilizável (primary nous + fallback openrouter) ----------
  YAML_BASE = <<~YAML.freeze
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

  # CASO 1 — primary do arquivo (não ordem hardcoded).
  test "primary vem do YAML, não de ordem hardcoded no código" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do
        primario = Llm::ModelChain.primary
        assert_equal "tencent/hy3:free", primario.model
        assert_equal :nous, primario.provider
        assert_equal "nous", primario.label
        assert_equal "none", primario.effort
        assert_equal({ tags: ["user=cleitin-bot"] }, primario.params)
      end
    end
  end

  # CASO 2 — fallback presente E null (YAML sem fallback => cadeia de 1).
  test "fallback presente produz cadeia de 2; fallback null produz cadeia de 1" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do
        assert_equal 2, Llm::ModelChain.links.size
        assert_equal %w[nous openrouter], Llm::ModelChain.links.map(&:label)
      end

      yaml_sem_fallback = YAML_BASE.sub(/fallback:.*/m, "fallback: null")
      com_yaml(yaml_sem_fallback) do
        assert_equal 1, Llm::ModelChain.links.size
        assert_equal %w[nous], Llm::ModelChain.links.map(&:label)
      end
    end
  end

  # CASO 3 — troca entre duas leituras sem restart (reescrever arquivo muda cadeia).
  test "reescrever o YAML entre chamadas muda a cadeia sem restart" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do |caminho|
        assert_equal "tencent/hy3:free", Llm::ModelChain.primary.model

        # Troca o primary para openrouter (mantendo chave) e relê.
        File.write(caminho, <<~YAML)
          version: 1
          chat:
            primary:
              label: openrouter
              provider: openrouter
              model: openrouter/free
              effort: null
              params: null
            fallback: null
        YAML
        Llm::LlmChainLoader.state_mutex.synchronize { Llm::LlmChainLoader.state.delete(caminho) }
        assert_equal "openrouter/free", Llm::ModelChain.primary.model
        assert_equal %w[openrouter], Llm::ModelChain.links.map(&:label)
      end
    end
  end

  # CASO 4 — YAML inválido mantém last-known-good (log único).
  test "YAML inválido após carga válida mantém last-known-good e loga uma vez" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do |caminho|
        # Primeira carga válida.
        assert_equal "tencent/hy3:free", Llm::ModelChain.primary.model

        # Captura apenas avisos que mencionem "inválido" e conta quantas vezes aparecem.
        avisos = []
        Rails.logger.stubs(:warn).with { |m| avisos << m.to_s; true }

        # Corrompe o arquivo (primary sem provider/model => ConfigError).
        File.write(caminho, "version: 1\nchat:\n  primary: {}\n")
        Llm::ModelChain.primary
        Llm::ModelChain.primary # segunda vez — NÃO deve logar de novo

        invalidos = avisos.count { |m| m =~ /inválido/ }
        assert_equal 1, invalidos, "log de YAML inválido deve ser único: #{avisos.inspect}"
        # Continua com o último bom:
        assert_equal "tencent/hy3:free", Llm::ModelChain.primary.model
      end
    end
  end

  # CASO 5 — modelo não registrado previamente (slug ausente da lista hardcoded)
  # passa a ser resolvido após carga dinâmica.
  test "modelo novo no YAML é registrado dinamicamente e resolvido em links" do
    com_env("OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(<<~YAML) do |_caminho|
        version: 1
        chat:
          primary:
            label: openrouter-novo
            provider: openrouter
            model: openrouter/novissimo-free
            effort: null
            params: null
          fallback: null
      YAML
        # Antes da carga dinâmica, o registry da gem não conhece o slug.
        assert_raises(RubyLLM::ModelNotFoundError) do
          RubyLLM.models.find("openrouter/novissimo-free", :openrouter)
        end

        # links registra idempotentemente e devolve o elo.
        elo = Llm::ModelChain.primary
        assert_equal "openrouter/novissimo-free", elo.model

        # Agora o registry resolve (sem ModelNotFoundError).
        info = RubyLLM.models.find("openrouter/novissimo-free", :openrouter)
        assert_equal "openrouter", info.provider.to_s
      end
    end
  end

  # CASO 8 — chave do provider ausente encurta a cadeia.
  test "chave de provider ausente encurta a cadeia (sem NOUS => nous some)" do
    # Só openrouter configurado; o primary do YAML base aponta para nous => some.
    com_env("OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do
        # primary nous sem chave => cadeia vazia (não mente com fallback só).
        assert_empty Llm::ModelChain.links, "primary sem chave deve esvaziar a cadeia"
      end
    end

    # Agora só NOUS: fallback openrouter sem chave some, fica só o primary.
    com_env("NOUS_API_KEY" => "sk-n") do
      com_yaml(YAML_BASE) do
        assert_equal %w[nous], Llm::ModelChain.links.map(&:label)
      end
    end
  end

  # REGRESSÃO — comentário DNS corrigido: o arquivo não pode culpar o domínio errado.
  test "comentário não culpa DNS de api.nousresearch.com (domínio errado)" do
    conteudo = File.read(Rails.root.join("lib/llm/model_chain.rb"))
    # Intenção: o comentário NÃO culpa o domínio inexistente `api.nousresearch.com`
    # como causa da queda. O endpoint REAL é `inference-api.nousresearch.com`
    # (citado abaixo). Por isso proíbimos o domínio exato standalone — o lookbehind
    # (?<!-) impede casar o `api` que vem logo após o hífen em `inference-api...`,
    # enquanto ainda pega `api.nousresearch.com` solto (precedido de espaço/quote).
    refute conteudo.match?(/(?<!-)api\.nousresearch\.com\b/),
           "comentário não pode culpar o domínio inexistente api.nousresearch.com (standalone); só o endpoint real inference-api.nousresearch.com é citado"
    assert_includes conteudo, "inference-api.nousresearch.com", "deve citar o endpoint real do provider"
    assert_includes conteudo, "tags", "deve explicar a causa real (mudança de contrato do gateway)"
  end

  # REGRESSÃO — aggregator mantém tags do Nous (mesma causa do hy3 ter parado).
  test "aggregator do Nous leva tags de identificação" do
    com_env("NOUS_API_KEY" => "sk-n") do
      agregador = Llm::ModelChain.aggregator
      assert_equal({ tags: ["user=cleitin-bot"] }, agregador.params)
    end
  end

  # REGRESSÃO — summarizer continua fixo (não é o elo 1) e desliga raciocínio pela rota.
  test "summarizer não é o elo primário e mantém mecanismo da Poolside" do
    com_env("POOLSIDE_API_KEY" => "sk-p", "NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      com_yaml(YAML_BASE) do
        resumidor = Llm::ModelChain.summarizer
        assert_equal "poolside/laguna-xs-2.1", resumidor.model
        assert_equal :poolside, resumidor.provider
        assert_not_equal Llm::ModelChain.primary.model, resumidor.model
        assert_equal({ chat_template_kwargs: { enable_thinking: false } }, resumidor.params)
      end
    end
  end
end
