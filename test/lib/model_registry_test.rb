# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/llm/model_registry'

class ModelRegistryTest < ActiveSupport::TestCase
  # Doubles no formato cru da OpenRouter, que é o que free lê.
  def row(id, prompt: '0', completion: '0', tools: true, ctx: 1000)
    {
      'id' => id,
      'context_length' => ctx,
      'pricing' => { 'prompt' => prompt, 'completion' => completion },
      'supported_parameters' => tools ? %w[tools] : []
    }
  end

  def stub_rows(*rows)
    Llm::ModelRegistry.stubs(:live_rows).returns(rows)
  end

  test 'free lista apenas os modelos sem custo de entrada e saída' do
    stub_rows(
      row('gratuito:free'),
      row('pago', prompt: '0.000000075', completion: '0.0000003')
    )

    assert_equal ['gratuito:free'], Llm::ModelRegistry.free.map(&:id)
  end

  test 'free exclui roteadores de tarifa variável' do
    # openrouter/auto anuncia preço -1: ele roteia para modelos pagos e cobra a
    # tarifa de quem atender. O parser do gem descarta preço não-positivo, então
    # via Model::Info ele era indistinguível de um gratuito.
    stub_rows(
      row('openrouter/free'),
      row('openrouter/auto', prompt: '-1', completion: '-1')
    )

    assert_equal ['openrouter/free'], Llm::ModelRegistry.free.map(&:id)
  end

  test 'free exclui modelos sem preço declarado' do
    stub_rows(row('sem-preco', prompt: nil, completion: nil))

    assert_empty Llm::ModelRegistry.free
  end

  test 'free exclui modelos sem tool calling por padrão' do
    stub_rows(row('com-tools:free'), row('sem-tools:free', tools: false))

    assert_equal ['com-tools:free'], Llm::ModelRegistry.free.map(&:id)
  end

  test 'free inclui modelos sem tool calling quando tools_only é falso' do
    stub_rows(row('com-tools:free'), row('sem-tools:free', tools: false))

    assert_equal %w[com-tools:free sem-tools:free], Llm::ModelRegistry.free(tools_only: false).map(&:id).sort
  end

  test 'free devolve o contexto de cada modelo' do
    stub_rows(row('modelo:free', ctx: 262_144))

    assert_equal 262_144, Llm::ModelRegistry.free.first.context_window
  end

  test 'refresh! delega para o RubyLLM e devolve o total de modelos' do
    fake_models = mock('models')
    fake_models.expects(:refresh!).returns(stub(all: [Object.new, Object.new]))
    RubyLLM.stubs(:models).returns(fake_models)

    assert_equal 2, Llm::ModelRegistry.refresh!
  end
end
