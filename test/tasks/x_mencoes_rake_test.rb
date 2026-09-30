# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/fetcher/channels/x_notificacoes"

# `x:mencoes` é a porta de linha de comando da leitura das menções (notificações). O teste segura o
# ENVELOPE: uma linha JSON {"posts": [...]}, o LIMITE repassado e o erro tipado com status 1.
# Nada aqui fala com o X: `XNotificacoes.mencoes` é dublado.
class XMencoesRakeTest < ActiveSupport::TestCase
  N = Fetcher::Channels::XNotificacoes
  E = Fetcher::Channels::XEscrita

  setup do
    Rake.application = Rake::Application.new
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("lib/tasks/x.rake").to_s
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake::TaskManager.record_task_metadata = false
    Rake.application = nil
    ENV.delete("LIMITE")
  end

  def roda
    saida = StringIO.new
    original = $stdout
    $stdout = saida
    status = 0
    begin
      Rake::Task["x:mencoes"].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, saida.string]
  end

  test "sem LIMITE usa 40 e imprime {posts:[...]} em uma linha, status 0" do
    post = { "id" => "1", "autor" => "conta_a", "texto" => "oi", "criado_em" => nil,
             "url" => "https://x.com/conta_a/status/1", "em_resposta_a" => nil, "e_resposta" => false }
    N.expects(:mencoes).with(limite: 40).returns([post])
    status, saida = roda
    assert_equal 0, status
    assert_equal({ "posts" => [post] }, JSON.parse(saida))
    assert_equal 1, saida.lines.size
  end

  test "LIMITE e repassado como inteiro; lista vazia continua sendo envelope valido" do
    ENV["LIMITE"] = "20"
    N.expects(:mencoes).with(limite: 20).returns([])
    status, saida = roda
    assert_equal 0, status
    assert_equal({ "posts" => [] }, JSON.parse(saida))
  end

  test "erro do canal sai como {erro,tipo} e status 1" do
    N.stubs(:mencoes).raises(E::RateLimited, "trava local")
    status, saida = roda
    assert_equal 1, status
    assert_equal({ "erro" => "trava local", "tipo" => "RateLimited" }, JSON.parse(saida))
  end

  test "LIMITE que nao e numero vira erro tipado, sem chamar o canal" do
    ENV["LIMITE"] = "abc"
    N.expects(:mencoes).never
    status, saida = roda
    assert_equal 1, status
    assert JSON.parse(saida)["erro"]
  end

  test "a task tem descricao" do
    assert_match(/menç/i, Rake::Task["x:mencoes"].comment.to_s)
  end
end
