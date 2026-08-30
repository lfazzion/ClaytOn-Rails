# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/llm/providers/agnes"

class Llm::Providers::AgnesTest < ActiveSupport::TestCase
  # Config de mentira: os acessores `agnes_*` só nascem depois do
  # Provider.register (que chama register_provider_options), e este teste não
  # depende da ordem de boot dos initializers para valer — espelha o padrão de
  # nous_test.rb / poolside_test.rb.
  class FakeConfig
    attr_accessor :agnes_api_key, :agnes_api_base, :request_timeout

    def initialize(key: nil, base: nil)
      @agnes_api_key = key
      @agnes_api_base = base
      @request_timeout = 120
    end

    def method_missing(name, *args)
      nil
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  def build(key: "sk-teste-agnes-123", base: nil)
    Llm::Providers::Agnes.new(FakeConfig.new(key: key, base: base))
  end

  test "é uma subclasse de RubyLLM::Providers::OpenAI" do
    # O endpoint da Agnes é OpenAI-compatível; herdar da OpenAI mantém o payload
    # no formato que a API entende (mesma escolha de Nous/Poolside).
    assert_operator Llm::Providers::Agnes, :<, RubyLLM::Providers::OpenAI
  end

  test "o slug é derivado do nome da classe e casa com o provider dos Model::Info" do
    # Se este slug mudar, todo Model::Info registrado com provider "agnes"
    # deixa de ser encontrado e RubyLLM.chat levanta ModelNotFoundError.
    assert_equal "agnes", Llm::Providers::Agnes.slug
  end

  test "aponta para o Agnes AI API hub" do
    assert_equal "https://apihub.agnes-ai.com/v1", build.api_base
  end

  test "api_base pode ser sobreposta pela configuração" do
    assert_equal "https://outro.exemplo/v1", build(base: "https://outro.exemplo/v1").api_base
  end

  test "monta o Authorization com a chave configurada" do
    assert_equal({ "Authorization" => "Bearer sk-teste-agnes-123" }, build(key: "sk-teste-agnes-123").headers)
  end

  test "sem chave, o provedor nem chega a ser construído" do
    # `Provider#initialize` chama `ensure_configured!` e levanta ANTES de
    # qualquer requisição. É por isso que a ModelChain filtra o elo pela chave
    # em vez de deixar o provedor decidir.
    assert_raises(RubyLLM::ConfigurationError) { build(key: nil) }
  end

  test "configured? é falso sem chave e verdadeiro com chave" do
    assert_not Llm::Providers::Agnes.configured?(FakeConfig.new(key: nil))
    assert Llm::Providers::Agnes.configured?(FakeConfig.new(key: "sk-teste-agnes-123"))
  end

  test "declara as duas opções de configuração e exige só a chave" do
    assert_equal %i[agnes_api_key agnes_api_base], Llm::Providers::Agnes.configuration_options
    assert_equal %i[agnes_api_key], Llm::Providers::Agnes.configuration_requirements
  end

  test "agnes e nous são endereços diferentes" do
    require_relative "../../../../lib/llm/providers/nous"

    assert_not_equal Llm::Providers::Agnes::DEFAULT_API_BASE,
                     Llm::Providers::Nous::DEFAULT_API_BASE
  end
end
