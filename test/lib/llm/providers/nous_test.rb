# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/llm/providers/nous"

class Llm::Providers::NousTest < ActiveSupport::TestCase
  class FakeConfig
    attr_accessor :nous_api_key, :nous_api_base, :request_timeout

    def initialize(key: nil, base: nil)
      @nous_api_key = key
      @nous_api_base = base
      @request_timeout = 120
    end

    def method_missing(name, *args)
      nil
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  def build(key: "sk-nous-teste", base: nil)
    Llm::Providers::Nous.new(FakeConfig.new(key: key, base: base))
  end

  test "é uma subclasse de RubyLLM::Providers::OpenAI" do
    assert_operator Llm::Providers::Nous, :<, RubyLLM::Providers::OpenAI
  end

  test "o slug é derivado do nome da classe e casa com o provider dos Model::Info" do
    assert_equal "nous", Llm::Providers::Nous.slug
  end

  test "aponta para o Nous Portal" do
    assert_equal "https://inference-api.nousresearch.com/v1", build.api_base
  end

  test "api_base pode ser sobreposta pela configuração" do
    assert_equal "https://outro.exemplo/v1", build(base: "https://outro.exemplo/v1").api_base
  end

  test "monta o Authorization com a chave configurada" do
    assert_equal({ "Authorization" => "Bearer sk-nous-teste" }, build(key: "sk-nous-teste").headers)
  end

  test "sem chave, o provedor nem chega a ser construído" do
    assert_raises(RubyLLM::ConfigurationError) { build(key: nil) }
  end

  test "configured? é falso sem chave e verdadeiro com chave" do
    assert_not Llm::Providers::Nous.configured?(FakeConfig.new(key: nil))
    assert Llm::Providers::Nous.configured?(FakeConfig.new(key: "sk-nous-teste"))
  end

  test "declara as duas opções de configuração e exige só a chave" do
    assert_equal %i[nous_api_key nous_api_base], Llm::Providers::Nous.configuration_options
    assert_equal %i[nous_api_key], Llm::Providers::Nous.configuration_requirements
  end

  test "os dois provedores são endereços diferentes" do
    require_relative "../../../../lib/llm/providers/poolside"

    assert_not_equal Llm::Providers::Nous::DEFAULT_API_BASE,
                     Llm::Providers::Poolside::DEFAULT_API_BASE
  end
end
