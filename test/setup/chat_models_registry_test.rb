# frozen_string_literal: true

require "test_helper"
require "pathname"
require "llm/model_chain"

# Fecha a porta do achado de revisao do PR de LLM: o caminho que o chat
# realmente usa (ModelChain, consumido pelo ChatSessionManager) nao pode
# apontar para modelo fora do registry da gem — senao toda mensagem cai em
# ModelNotFoundError -> "Erro ao processar". A versao antiga do bug vivia em
# PRIMARY_MODEL/FALLBACK_MODEL (constantes do ChatSessionManager antigo).
#
# DESDE 29/08 a cadeia NAO vem mais de ENV hardcoded: ModelChain.links le
# config/llm_chain.yml (primary + fallback opcional) via LlmChainLoader. Sem o
# arquivo (ou sem chaves de API), `links` volta VAZIA. Entao o teste tem de
# (1) escrever um YAML valido num Dir.mktmpdir (NAO arquivo fixo), (2) apontar
# a constante CHAIN_CONFIG_PATH para ele e (3) ligar as ENVs das rotas que o
# YAML declara. So assim a cadeia de fato monta e o mapeamento
# (modelo, provider) de cada elo e exercitado contra o registry da gem.
class ChatModelsRegistryTest < ActiveSupport::TestCase
  # `Llm::ModelChain.links` monta cada elo SÓ quando a chave daquela rota está
  # no ambiente (`lib/llm/model_chain.rb:153` via `chave?`) — chave ausente
  # ENCURTA a cadeia de propósito. No container de teste (e no CI) não existe
  # chave nenhuma, então `links` voltaria [] e o teste morreria no
  # `refute_empty` sem nunca exercitar o que ele existe para cobrir.
  #
  # A correção NÃO é aceitar a cadeia vazia (isso desligaria a cobertura) nem
  # ler segredo: os nomes das chaves são presença, não valor. Setamos valores
  # obviamente falsos para que TODOS os elos sejam montados e verificados — a
  # asserção fica mais forte, não mais fraca. `links` não é memoizado de
  # propósito (model_chain.rb:74-98), então o ENV vale na hora da chamada.
  ENV_KEYS = %w[NOUS_API_KEY POOLSIDE_API_KEY OPENROUTER_API_KEY].freeze
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

  # Liga as ENVs das rotas no ambiente (valores obviamente falsos — so a
  # PRESENCA importa, o valor nao e validado aqui) e restaura no ensure.
  def com_todas_as_rotas_no_ambiente
    anteriores = ENV_KEYS.index_with { |nome| ENV.key?(nome) ? ENV[nome] : :ausente }
    ENV_KEYS.each { |nome| ENV[nome] = VALOR_FALSO if ENV[nome].to_s.strip.empty? }
    yield
  ensure
    anteriores.each do |nome, valor|
      valor == :ausente ? ENV.delete(nome) : ENV[nome] = valor
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

  test "cada elo da ModelChain resolve no registry da gem" do
    com_todas_as_rotas_no_ambiente do
      com_yaml(YAML_CADEIA) do
        links = Llm::ModelChain.links
        refute_empty links, "sem elos, o chat nao tem rota nenhuma"
        # Com primary+fallback no YAML e ambas as chaves presentes, montam 2.
        assert_equal 2, links.size,
                     "com primary e fallback no YAML e chaves presentes, a cadeia monta 2 elos"
        links.each do |link|
          encontrado = RubyLLM.models.find(link.model, link.provider)
          assert encontrado,
                 "elo #{link.label} aponta para #{link.model} (#{link.provider}), fora do registry"
          assert_equal link.model.to_s, encontrado.id
          assert_equal link.provider.to_s, encontrado.provider
        end
      end
    end
  end
end
