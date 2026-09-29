# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/fetcher/channels/x_escrita"

# `x:descurtir` e `x:deseguir` são as portas de linha de comando do DESFAZER (curtida e follow).
# O que este teste segura é o ENVELOPE do comando — repasse dos argumentos, status de saída,
# ausência do argumento obrigatório e erro tipado — porque o desfazer em si é do canal, testado
# em `x_escrita_test.rb`.
#
# NENHUM teste aqui fala com o X: `XEscrita.descurtir`/`deseguir` são dublados, e o teste prova
# que o comando entrega os argumentos certos e sai com o contrato certo (`{"erro","tipo"}` +
# status 1, o mesmo envelope das outras escritas).
class XDesfazerRakeTest < ActiveSupport::TestCase
  E = Fetcher::Channels::XEscrita

  setup do
    # Aplicação nova por teste: o Rake só executa uma task uma vez por processo.
    Rake.application = Rake::Application.new
    # `record_task_metadata` é o que faz o `desc` virar `task.comment`, e o Rake só o liga em
    # `Rake::Application#run` (rake-13.4.2, application.rb:648). Como este harness carrega o
    # `.rake` com `load` e invoca a task direto, TODA task — inclusive as que já existiam — ficaria
    # com `comment` `nil` sem isto. Medido: com o Rake application novo e sem esta linha, 16 tasks
    # carregadas e ZERO com comment.
    Rake::TaskManager.record_task_metadata = true
    # `load` (e não `rake_require`): o nome que o Rake resolve é relativo ao diretório de
    # trabalho, e o caminho ABSOLUTO é o que não depende de CWD (o container roda em /rails).
    load Rails.root.join("lib/tasks/x.rake").to_s
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake::TaskManager.record_task_metadata = false
    Rake.application = nil
    %w[ID USUARIO_ID].each { |variavel| ENV.delete(variavel) }
  end

  # O task termina em `exit XComando.executa { ... }`, e `exit` LEVANTA `SystemExit` — o caminho
  # mais fiel é capturar a exceção, sem dublar `Kernel#exit` (vaza para o runner do Minitest).
  # `$stdout` é desviado porque o `XComando.executa` escreve no `$stdout` padrão.
  def roda(task, env)
    ENV.update(env.transform_keys(&:to_s))
    saida = StringIO.new
    status = nil
    original_stdout = $stdout
    $stdout = saida
    begin
      Rake::Task[task].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original_stdout
    end
    [status, saida.string]
  end

  # Ids reais do X: o `tweet_id` do `XLeitura` RECUSA o que tiver menos de 15 dígitos, então um
  # id de teste de "1" seria rejeitado pelo envelope do comando e o teste mediria o `tweet_id`
  # em vez do `x:descurtir`.
  ID_REAL = "2104291497428345283"
  USUARIO_ID = "1000000000000000001"

  test "as duas tasks de desfazer existem com o nome do comando" do
    assert Rake::Task.task_defined?("x:descurtir"), "x:descurtir tem de existir"
    assert Rake::Task.task_defined?("x:deseguir"), "x:deseguir tem de existir"
    assert_match(/ID=/, Rake::Task["x:descurtir"].comment)
    assert_match(/USUARIO_ID=/, Rake::Task["x:deseguir"].comment)
  end

  test "descurtir devolve uma linha JSON com o id e status 0" do
    E.expects(:descurtir).with(id: ID_REAL).returns({ "id" => ID_REAL })
    status, saida = roda("x:descurtir", { "ID" => ID_REAL })
    assert_equal 0, status
    assert_equal "#{JSON.generate({ 'id' => ID_REAL })}\n", saida
  end

  # O `ID=` aceita link como nas outras escritas: quem copia da barra de endereços do X cola o link.
  test "descurtir aceita ID como link do post" do
    link = "https://x.com/daemon403/status/#{ID_REAL}"
    E.expects(:descurtir).with(id: ID_REAL).returns({ "id" => ID_REAL })
    status, = roda("x:descurtir", { "ID" => link })
    assert_equal 0, status
  end

  test "deseguir devolve uma linha JSON com o usuario e status 0" do
    E.expects(:deseguir).with(usuario_id: USUARIO_ID).returns({ "usuario_id" => USUARIO_ID })
    status, saida = roda("x:deseguir", { "USUARIO_ID" => USUARIO_ID })
    assert_equal 0, status
    assert_equal "#{JSON.generate({ 'usuario_id' => USUARIO_ID })}\n", saida
  end

  # O `USUARIO_ID=` é o ID numérico, e não o screen_name: o `x:seguir` aceita `USUARIO=` e
  # traduz com o `XConta.perfil` (que é uma LEITURA, e por isso gasta cota). O desfazer é para
  # uso logo após um sweep que já sabe o id, e não deve fazer uma leitura a mais. Um screen_name
  # colado aqui não é id e tem de ser recusado por quem confere o snowflake — nunca traduzido
  # por baixo dos panos, porque isso faria o comando fazer o que ele não diz que faz.
  #
  # Aqui o canal NÃO é dublado: o que se prova é que o comando REPASSA o valor cru e que quem
  # recusa é o canal (antes da rede), e não o comando com uma tradução escondida.
  test "deseguir nao traduz screen_name e o id invalido sai tipado com status 1" do
    status, saida = roda("x:deseguir", { "USUARIO_ID" => "terceiro" })
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "Recusado", erro["tipo"]
    assert_match(/id invalido/, erro["erro"])
    assert_match(/terceiro/, erro["erro"], "o erro tem de dizer qual id foi recusado")
  end

  test "sem ID no descurtir sai erro de uso com status 1 e nao chama o canal" do
    E.expects(:descurtir).never
    status, saida = roda("x:descurtir", {})
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "ArgumentError", erro["tipo"]
    assert_match(/x:descurtir ID=/, erro["erro"])
  end

  test "sem USUARIO_ID no deseguir sai erro de uso com status 1 e nao chama o canal" do
    E.expects(:deseguir).never
    status, saida = roda("x:deseguir", {})
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "ArgumentError", erro["tipo"]
    assert_match(/x:deseguir USUARIO_ID=/, erro["erro"])
  end

  # O erro do canal (recusa do X, sessão, trava local) sai pelo mesmo envelope das outras
  # escritas, para o porteiro ler igual.
  test "erro do canal sai como uma linha JSON com tipo e status 1" do
    E.expects(:descurtir).raises(E::Incerto, "pode TER saido no X")
    status, saida = roda("x:descurtir", { "ID" => ID_REAL })
    assert_equal 1, status
    assert_equal({ "erro" => "pode TER saido no X", "tipo" => "Incerto" }, JSON.parse(saida))

    E.expects(:deseguir).raises(E::Restrito, "conta sob restricao")
    status, saida = roda("x:deseguir", { "USUARIO_ID" => USUARIO_ID })
    assert_equal 1, status
    assert_equal({ "erro" => "conta sob restricao", "tipo" => "Restrito" }, JSON.parse(saida))
  end
end
