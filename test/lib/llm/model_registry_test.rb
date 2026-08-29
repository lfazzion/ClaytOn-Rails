# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../../lib/llm/model_registry"

class Llm::ModelRegistryTest < ActiveSupport::TestCase
  # O registry interno da gem é compartilhado entre testes; este arquivo só
  # exercita a SINCRONIZAÇÃO de `register_from_spec!` (mutex), não o conteúdo
  # vivo do registry da gem. A partir de N threads que chamam concorrentemente
  # com o MESMO spec, o `any?`+`<<` sem lock poderia duplicar — aqui provamos
  # que o resultado é idempotente sob concorrência.

  # Um `spec` que NÃO existe no registry hardcoded (slug novo), para forçar o
  # caminho de inserção.
  SPEC = { provider: :concorrencia_test, model: "concorrencia/novo-modelo", effort: nil, params: nil }.freeze

  test "registro concorrente não duplica o modelo no registry" do
    # Limpeza prévia defensiva: remove qualquer resquício do spec de teste.
    Llm::ModelRegistry.send(:registry).reject! do |m|
      m.id == SPEC[:model].to_s && m.provider == SPEC[:provider].to_s
    end

    Thread.abort_on_exception = true
    n = 12
    threads = Array.new(n) do
      Thread.new { Llm::ModelRegistry.register_from_spec!(**SPEC) }
    end
    threads.each(&:join)

    # Conta quantas cópias do mesmo id+provider estão no registry.
    copias = Llm::ModelRegistry.send(:registry).count do |m|
      m.id == SPEC[:model].to_s && m.provider == SPEC[:provider].to_s
    end
    assert_equal 1, copias, "registro concorrente duplicou o modelo (#{copias} cópias)"

    # Limpeza pós-teste para não poluir o registry da gem.
  ensure
    Llm::ModelRegistry.send(:registry).reject! do |m|
      m.id == SPEC[:model].to_s && m.provider == SPEC[:provider].to_s
    end
    Thread.abort_on_exception = false
  end
end
