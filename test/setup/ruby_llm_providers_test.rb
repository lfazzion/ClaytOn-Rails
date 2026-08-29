# frozen_string_literal: true

require "test_helper"
require "pathname"
require "llm/model_chain"

# Não existe teste algum hoje cobrindo config/initializers/ruby_llm.rb, e foi
# essa lacuna que deixou o HEAD com um PRIMARY_MODEL apontando para um id que
# nenhum initializer commitado registra. Estes testes fecham a porta: eles rodam
# depois do boot do Rails, então observam o estado real que o initializer deixou.
class RubyLlmProvidersTest < ActiveSupport::TestCase
  # `Llm::ModelChain.links` monta cada elo SÓ quando a chave daquela rota está
  # no ambiente (`lib/llm/model_chain.rb:153` via `chave?`) — chave ausente
  # ENCURTA a cadeia de propósito. DESDE 29/08 a cadeia NÃO vem de ENV
  # hardcoded: `links` lê config/llm_chain.yml (primary + fallback opcional) via
  # LlmChainLoader; sem o arquivo (ou sem chaves de API) `links` volta [] e o
  # laço que a percorre exercita ZERO elos (falso-positivo: passa sem cobrir
  # nada). Igual ao chat_models_registry_test, escrevemos um YAML válido num
  # Dir.mktmpdir, apontamos CHAIN_CONFIG_PATH para ele e ligamos as ENVs das
  # rotas que o YAML declara, para que TODOS os elos sejam montados e
  # verificados — a asserção fica mais forte, não mais fraca. `links` não é
  # memoizado (model_chain.rb:74-98), então o ENV vale na hora da chamada.
  CHAVES_DE_ROTA = %w[NOUS_API_KEY POOLSIDE_API_KEY OPENROUTER_API_KEY].freeze
  VALOR_FALSO = "chave-teste-invalida"

  # Redefine uma constante de classe durante o bloco e restaura no ensure.
  # `links` referencia CHAIN_CONFIG_PATH como constante nua, resolvida em tempo
  # de execucao — trocar a constante redireciona a leitura sem acoplar o teste
  # a localizacao de producao (padrao de test/lib/llm/model_chain_test.rb).
  def stub_const(klass, const, valor)
    original = klass.const_defined?(const, false) ? klass.const_get(const, false) : :__undef__
    klass.send(:remove_const, const) if klass.const_defined?(const, false)
    klass.const_set(const, valor)
    yield
  ensure
    klass.send(:remove_const, const) if klass.const_defined?(const, false)
    klass.const_set(const, original) unless original == :__undef__
  end

  # Escreve um YAML de cadeia em arquivo temporario, aponta CHAIN_CONFIG_PATH
  # para ele (limpando o last-known-good state daquele caminho) e devolve o
  # caminho. Dir.mktmpdir garante que NAO tocamos em arquivo fixo nem no
  # config/llm_chain.yml da aplicacao.
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

  # YAML valido: primary nous + fallback openrouter (cadeia de 2 elos).
  YAML_CADEIA = <<~YAML.freeze
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

  test "os dois provedores novos estão registrados na gem" do
    assert_equal Llm::Providers::Poolside, RubyLLM::Provider.providers[:poolside]
    assert_equal Llm::Providers::Nous, RubyLLM::Provider.providers[:nous]
  end

  test "registrar o provedor criou os acessores de configuração" do
    # Provider.register chama Configuration.register_provider_options por dentro.
    assert_respond_to RubyLLM.config, :poolside_api_key
    assert_respond_to RubyLLM.config, :nous_api_key
  end

  # Sem registro manual, RubyLLM.chat levanta ModelNotFoundError ANTES de fazer a
  # requisição — o models.json embarcado na gem é congelado no release.
  test "todo modelo da cadeia existe no registry, com o provider certo" do
    esperados = {
      "poolside/laguna-xs-2.1" => "poolside",
      "poolside/laguna-s-2.1" => "poolside",
      "poolside/laguna-xs-2.1:free" => "nous",
      "tencent/hy3:free" => "nous",
      "openrouter/free" => "openrouter"
    }

    esperados.each do |id, provider|
      encontrado = RubyLLM.models.find(id, provider)

      assert_equal id, encontrado.id
      assert_equal provider, encontrado.provider
    end
  end

  test "o provider dos Model::Info é String, nunca Symbol" do
    # Model::Info não faz coerção de tipo, e Models#find compara com to_s contra
    # o valor cru. Symbol aqui vira ModelNotFoundError em tempo de execução.
    %w[poolside/laguna-xs-2.1 poolside/laguna-xs-2.1:free tencent/hy3:free].each do |id|
      assert_kind_of String, RubyLLM.models.find(id).provider
    end
  end

  test "o provider registrado casa com o slug da classe do provedor" do
    assert_equal Llm::Providers::Poolside.slug, RubyLLM.models.find("poolside/laguna-xs-2.1").provider
    assert_equal Llm::Providers::Nous.slug, RubyLLM.models.find("tencent/hy3:free").provider
  end

  test "a janela de contexto registrada é a medida na API, não um chute" do
    # 262.144 medido em GET /v1/models das duas rotas em 2026-08-07. É esta
    # janela que o ConversationCompactor usa para decidir quando compactar.
    assert_equal 262_144, RubyLLM.models.find("poolside/laguna-xs-2.1").context_window
    assert_equal 262_144, RubyLLM.models.find("poolside/laguna-xs-2.1:free").context_window
    assert_equal 262_144, RubyLLM.models.find("tencent/hy3:free").context_window
  end

  test "os modelos da cadeia declaram function_calling" do
    # O bot é inútil sem tool calling: 17 tools dependem disso.
    %w[poolside/laguna-xs-2.1 poolside/laguna-xs-2.1:free openrouter/free].each do |id|
      assert_includes RubyLLM.models.find(id).capabilities, "function_calling", id
    end
  end

  test "os dois Gemini continuam registrados" do
    # Regressão: eles não têm nada a ver com esta entrega e não podem sumir.
    assert RubyLLM.models.find("gemini-3.1-flash-lite")
    assert RubyLLM.models.find("gemini-3.5-flash-lite")
  end

  test "o default_model é um modelo que existe no registry" do
    assert RubyLLM.models.find(RubyLLM.config.default_model)
  end

  test "elos da ModelChain e ids registrados a mao resolvem no registry" do
    # Ver ressalva do revisor GLМ: sem as ENVs de rota no ambiente (e sem o
    # YAML da cadeia) este laço exercitava 0 elos (links vazio) e o teste
    # passava sem cobrir a cadeia. DESDE 29/08 a cadeia vem de
    # config/llm_chain.yml (primary + fallback); aqui escrevemos um YAML valido
    # num Dir.mktmpdir, apontamos CHAIN_CONFIG_PATH para ele e ligamos as ENVs
    # das rotas que o YAML declara (nous + openrouter) e RESTAURAMOS tudo em
    # ensure. Garantimos que os 2 elos foram de fato montados e verificados.
    anteriores = CHAVES_DE_ROTA.to_h { |nome| [nome, ENV.key?(nome) ? ENV[nome] : :ausente] }
    CHAVES_DE_ROTA.each { |nome| ENV[nome] = VALOR_FALSO if ENV[nome].to_s.strip.empty? }
    begin
      com_yaml(YAML_CADEIA) do
        links = Llm::ModelChain.links
        # YAML declara primary (nous) + fallback (openrouter); ambas as chaves
        # estao presentes, entao montam 2 elos.
        assert_equal 2, links.size,
                     "com primary e fallback no YAML e chaves presentes a cadeia tem de montar 2 elos"
        links.each do |link|
          encontrado = RubyLLM.models.find(link.model, link.provider)
          assert encontrado,
                 "elo #{link.label} aponta para #{link.model} (#{link.provider}), fora do registry"
          assert_equal link.model.to_s, encontrado.id
          assert_equal link.provider.to_s, encontrado.provider
        end
      end
    ensure
      anteriores.each do |nome, valor|
        valor == :ausente ? ENV.delete(nome) : ENV[nome] = valor
      end
    end

    Llm::ModelRegistry.custom_models.each do |info|
      assert RubyLLM.models.find(info.id),
             "id registrado a mao (#{info.id}) nao resolve no registry"
    end
    assert RubyLLM.models.find("gemma-4-31b-it"),
           "gemma-4-31b-it (registrado a mao no Llm::ModelRegistry) nao resolve"
  end

  test "mensagem de sistema sai com o papel 'system', não 'developer'" do
    # A rota direta da Poolside IGNORA o papel 'developer' — medido 3/3 em
    # 2026-08-07: com 'developer' ela responde genérico em inglês; com 'system'
    # obedece. Sem esta configuração o bot perde persona, timestamp e as regras
    # das 17 tools no elo primário, e nenhum teste que estuba RubyLLM.chat vê isso.
    #
    # O CI não tem POOLSIDE_API_KEY nem NOUS_API_KEY no .env: o initializer já
    # rodou, deixou os campos nil, e o construtor do provider chama
    # `ensure_configured!` que levanta ConfigurationError se a chave exigida for
    # ausente (ver ruby_llm-1.16.0/lib/ruby_llm/provider.rb:261-267; a classe
    # ConfigurationError é definida em ruby_llm-1.16.0/lib/ruby_llm/error.rb:21).
    # Os stubs abaixo satisfazem a presença exigida pela gem (o require do
    # provider só checa presença, não validade) sem alterar a asserção sobre o
    # papel da mensagem.
    # O laço abaixo instancia TRÊS provedores, inclusive :openrouter, mas os
    # stubs originais cobriam só poolside e nous — daí o
    # `ConfigurationError: Missing configuration for OpenRouter` no container e
    # em qualquer ambiente sem OPENROUTER_API_KEY. Só a lista de stubs estava
    # incompleta; a asserção sobre o papel da mensagem não muda.
    #
    # Alinhado com o registry test: usamos `=` (sobrescreve sempre) guardando o
    # valor anterior em `anteriores`, em vez de `||=` + booleanos de presença —
    # fica simétrico e não deixa a chave deletada pelo bloco sem restauração.
    anteriores = CHAVES_DE_ROTA.to_h { |nome| [nome, ENV.key?(nome) ? ENV[nome] : :ausente] }
    CHAVES_DE_ROTA.each { |nome| ENV[nome] = VALOR_FALSO }
    poolside_key_antigo   = RubyLLM.config.poolside_api_key
    nous_key_antigo       = RubyLLM.config.nous_api_key
    openrouter_key_antigo = RubyLLM.config.openrouter_api_key
    RubyLLM.config.poolside_api_key   = ENV["POOLSIDE_API_KEY"]
    RubyLLM.config.nous_api_key       = ENV["NOUS_API_KEY"]
    RubyLLM.config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]

    begin
      %i[poolside nous openrouter].each do |slug|
        provedor = RubyLLM::Provider.providers[slug].new(RubyLLM.config)
        mensagens = provedor.send(:format_messages, [RubyLLM::Message.new(role: :system, content: "x")])

        assert_equal "system", mensagens.first[:role], slug.to_s
      end
    ensure
      # Restaura o estado global (ENV + config) capturado no início: o `=` acima
      # sobrescreve sempre, por isso guardamos o valor anterior (ou :ausente) e
      # restauramos/deleteamos conforme o caso — simétrico ao registry test.
      anteriores.each do |nome, valor|
        valor == :ausente ? ENV.delete(nome) : ENV[nome] = valor
      end
      RubyLLM.config.poolside_api_key   = poolside_key_antigo
      RubyLLM.config.nous_api_key       = nous_key_antigo
      RubyLLM.config.openrouter_api_key = openrouter_key_antigo
    end
  end
end
