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

  # CASO 7 — payload HTTP serializado com/sem tags (medido em 28/08: o gateway
  # Nous passou a exigir `tags` de chamadores com API key crua; sem tags => HTTP
  # 400). O params do Link faz deep_merge no corpo RAIZ da requisição (gem
  # 1.16.0: Provider#complete -> Utils.deep_merge(render_payload(...), params)).
  # Aqui inspecionamos o JSON que EFETIVAMENTE seria enviado, não só um helper.
  test "elo com params tags produz 'tags' no corpo HTTP; sem params, não" do
    require "ruby_llm"

    # ModelInfo mínimo aceito por Models.resolve (sem tocar no registry global).
    model_info = RubyLLM::Model::Info.new(
      id: "tencent/hy3:free", name: "HY3 (teste)", provider: "nous",
      capabilities: %w[function_calling streaming], max_output_tokens: 32_768, context_window: 262_144
    )

    # Sem ostruct (não é default gem no Ruby 4.0): reusa FakeConfig, que já
    # expõe nous_api_key/nous_api_base/request_timeout e devolve nil via
    # method_missing para openai_use_system_role.
    config = FakeConfig.new(
      key: "sk-test", base: "https://inference-api.nousresearch.com/v1"
    )

    provider = Llm::Providers::Nous.new(config)
    # Força o modelo resolvido a ser o nosso info de teste (evita ModelNotFoundError).
    provider.instance_variable_set(:@model, model_info)

    mensagem = RubyLLM::Message.new(role: :user, content: "ping")

    # Com tags: o params do Link deve aparecer no corpo.
    com_tags = RubyLLM::Utils.deep_merge(
      provider.send(:render_payload, [mensagem], tools: {}, tool_prefs: {},
                    temperature: nil, model: model_info, stream: false),
      { tags: ["user=cleitin-bot"] }
    )
    assert_includes com_tags.keys, :tags
    assert_equal ["user=cleitin-bot"], com_tags[:tags]

    # Sem params: render_payload puro NÃO tem tags.
    sem_tags = provider.send(:render_payload,
      [mensagem], tools: {}, tool_prefs: {}, temperature: nil, model: model_info, stream: false
    )
    refute_includes sem_tags.keys, :tags, "modelo Nous sem tags não deve injetar o campo"
  end
end
