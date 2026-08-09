# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/llm/providers/poolside"

class Llm::Providers::PoolsideTest < ActiveSupport::TestCase
  # Config de mentira em vez da RubyLLM::Configuration real: os acessores
  # `poolside_*` só nascem depois do Provider.register (medido — é o
  # register que chama register_provider_options), e este teste não pode
  # depender da ordem de boot dos initializers para valer.
  class FakeConfig
    attr_accessor :poolside_api_key, :poolside_api_base, :request_timeout

    def initialize(key: nil, base: nil)
      @poolside_api_key = key
      @poolside_api_base = base
      @request_timeout = 120
    end

    def method_missing(name, *args)
      nil
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  def build(key: "sk-teste", base: nil)
    Llm::Providers::Poolside.new(FakeConfig.new(key: key, base: base))
  end

  test "é uma subclasse de RubyLLM::Providers::OpenAI" do
    # Herdar da OpenAI, e NÃO da OpenRouter da gem, é o que faz o payload sair
    # no formato chato que esta API entende. A OpenRouter sobrescreve
    # render_payload para `reasoning: { effort: }` aninhado.
    assert_operator Llm::Providers::Poolside, :<, RubyLLM::Providers::OpenAI
  end

  test "o slug é derivado do nome da classe e casa com o provider dos Model::Info" do
    # Se este slug mudar, todo Model::Info registrado com provider "poolside"
    # deixa de ser encontrado e RubyLLM.chat levanta ModelNotFoundError.
    assert_equal "poolside", Llm::Providers::Poolside.slug
  end

  test "aponta para a API direta da Poolside" do
    assert_equal "https://inference.poolside.ai/v1", build.api_base
  end

  test "api_base pode ser sobreposta pela configuração" do
    assert_equal "https://outro.exemplo/v1", build(base: "https://outro.exemplo/v1").api_base
  end

  test "monta o Authorization com a chave configurada" do
    assert_equal({ "Authorization" => "Bearer sk-teste" }, build(key: "sk-teste").headers)
  end

  test "sem chave, o provedor nem chega a ser construído" do
    # `Provider#initialize` chama `ensure_configured!` e levanta ANTES de
    # qualquer requisição. É por isso que a ModelChain filtra o elo pela chave
    # em vez de deixar o provedor decidir: sem o filtro, o turno do usuário
    # morreria aqui, e com um erro que não descende de RubyLLM::Error.
    assert_raises(RubyLLM::ConfigurationError) { build(key: nil) }
  end

  test "configured? é falso sem chave e verdadeiro com chave" do
    assert_not Llm::Providers::Poolside.configured?(FakeConfig.new(key: nil))
    assert Llm::Providers::Poolside.configured?(FakeConfig.new(key: "sk-teste"))
  end

  test "declara as duas opções de configuração e exige só a chave" do
    assert_equal %i[poolside_api_key poolside_api_base],
                 Llm::Providers::Poolside.configuration_options
    assert_equal %i[poolside_api_key], Llm::Providers::Poolside.configuration_requirements
  end
end
