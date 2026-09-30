# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require "rake"
require_relative "../../lib/fetcher/channels/x_editar"
require_relative "../../lib/fetcher/channels/x_escrita"

# O `x:editar` é a porta de linha de comando da edição de post. O que este teste segura é o
# ENVELOPE do comando (leitura de `-`/arquivo, id ou link, repasse dos argumentos, status de
# saída e erro tipado) — a edição em si é do canal, testada em x_editar_test.rb.
#
# Nenhum teste aqui fala com o X: `XEditar.editar` é dublado, e o teste prova que o comando
# entrega os argumentos certos e sai com o contrato certo.
class XEditarRakeTest < ActiveSupport::TestCase
  X = Fetcher::Channels::XEditar

  setup do
    # Aplicação nova por teste: o Rake só executa uma task uma vez por processo.
    Rake.application = Rake::Application.new
    # `load` (e não `rake_require`): o nome que o Rake resolve é relativo ao diretório de
    # trabalho, e o caminho ABSOLUTO é o que não depende de CWD (o container roda em /rails).
    load Rails.root.join("lib/tasks/x.rake").to_s
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake.application = nil
    %w[ID TEXTO].each { |variavel| ENV.delete(variavel) }
  end

  # O task termina em `exit XComando.executa { ... }`, e `exit` LEVANTA `SystemExit` — o caminho
  # mais fiel é capturar a exceção, sem dublar `Kernel#exit` (vaza para o runner do Minitest).
  # `$stdout`/`$stdin` são desviados porque o `XComando.executa` escreve no `$stdout` padrão e o
  # `le_texto` lê do `$stdin` padrão.
  # O primeiro argumento é POSICIONAL de propósito: em Ruby 4, `roda({ "ID" => "1" })` seria lido
  # como argumento de palavra-chave e não preencheria `env` (o erro seria "wrong number of
  # arguments (given 0, expected 1)", longe da causa real).
  def roda(env, stdin: "")
    ENV.update(env.transform_keys(&:to_s))
    saida = StringIO.new
    status = nil
    original_stdout = $stdout
    original_stdin = $stdin
    $stdout = saida
    $stdin = StringIO.new(stdin)
    begin
      Rake::Task["x:editar"].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original_stdout
      $stdin = original_stdin
    end
    [status, saida.string]
  end

  # Ids reais do X sao de 15 a 25 digitos (`Fetcher::XLeitura::ID_REGEX`), e o `tweet_id` RECUSA
  # o que for menor: um id de teste de "1" seria rejeitado pelo proprio envelope do comando, e o
  # teste mediria o `tweet_id` em vez do `x:editar`.
  ANTIGO = "2104291497428345283"
  NOVO = "2104299999999999999"
  SAIDA = { "id" => NOVO, "id_anterior" => ANTIGO, "url" => "https://x.com/i/status/#{NOVO}",
            "versoes" => [ANTIGO, NOVO], "edicoes_restantes" => 2, "editavel_ate_ms" => "1790639000000" }.freeze

  test "edita lendo TEXTO de ARQUIVO e devolve uma linha JSON com status 0" do
    arquivo = Tempfile.new(["editar_texto", ".txt"])
    arquivo.write("texto novo\n")
    arquivo.close
    X.expects(:editar).with(id: ANTIGO, texto: "texto novo").returns(SAIDA)

    status, saida = roda({ "ID" => "2104291497428345283", "TEXTO" => arquivo.path })
    assert_equal 0, status
    assert_equal "#{JSON.generate(SAIDA)}\n", saida
  end

  test "edita lendo TEXTO do stdin quando TEXTO=-" do
    X.expects(:editar).with(id: ANTIGO, texto: "do stdin").returns(SAIDA)
    status, saida = roda({ "ID" => ANTIGO, "TEXTO" => "-" }, stdin: "do stdin\n")
    assert_equal 0, status
    assert_equal "#{JSON.generate(SAIDA)}\n", saida
  end

  # O `ID=` aceita link como nas outras escritas: quem copia da barra de endereco do X cola o link.
  test "aceita ID como link do post" do
    link = "https://x.com/daemon403/status/2104291497428345283"
    arquivo = Tempfile.new(["editar_texto", ".txt"])
    arquivo.write("oi")
    arquivo.close
    X.expects(:editar).with(id: "2104291497428345283", texto: "oi").returns(SAIDA)
    status, = roda({ "ID" => link, "TEXTO" => arquivo.path })
    assert_equal 0, status
  end

  test "sem ID sai erro de uso com status 1 e nao chama o canal" do
    X.expects(:editar).never
    status, saida = roda({ "TEXTO" => "oi" })
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "ArgumentError", erro["tipo"]
    assert_match(/x:editar ID=/, erro["erro"])
  end

  # O `ID` aqui tem de ser VÁLIDO: com um id curto, o `tweet_id` recusaria primeiro e o teste
  # passaria medindo o `tweet_id` em vez do "faltou TEXTO".
  test "sem TEXTO sai erro de uso com status 1 e nao chama o canal" do
    X.expects(:editar).never
    status, saida = roda({ "ID" => ANTIGO })
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "ArgumentError", erro["tipo"]
    assert_match(/TEXTO/, erro["erro"])
  end

  # ID que não é id nem link: o erro sai do `tweet_id` do XLeitura, e o comando não engole.
  test "ID que nao contem id de post sai erro tipado com status 1" do
    X.expects(:editar).never
    status, saida = roda({ "ID" => "https://x.com/daemon403", "TEXTO" => "oi" })
    assert_equal 1, status
    erro = JSON.parse(saida)
    assert_equal "ArgumentError", erro["tipo"]
    assert_match(/não achei o id do post/, erro["erro"])
  end

  # O erro do canal (teto, recusa do X, sessão) sai pelo mesmo envelope das outras escritas:
  # `{"erro","tipo"}` e status 1, para o porteiro ler igual.
  test "erro do canal sai como uma linha JSON com tipo e status 1" do
    arquivo = Tempfile.new(["editar_texto", ".txt"])
    arquivo.write("oi")
    arquivo.close
    X.expects(:editar).raises(Fetcher::Channels::XEscrita::Recusado, "fora da janela")
    status, saida = roda({ "ID" => ANTIGO, "TEXTO" => arquivo.path })
    assert_equal 1, status
    assert_equal({ "erro" => "fora da janela", "tipo" => "Recusado" }, JSON.parse(saida))
  end

  # `TEXTO=` que não é `-` é CAMINHO de arquivo (o mesmo contrato do `postar`), então um texto
  # solto sai como `SystemCallError`/`ENOENT` tipado — e não como texto editado por acidente.
  test "TEXTO que nao e caminho nem - sai tipado sem chamar o canal" do
    X.expects(:editar).never
    status, saida = roda({ "ID" => ANTIGO, "TEXTO" => "oi" })
    assert_equal 1, status
    assert_equal "ENOENT", JSON.parse(saida)["tipo"]
  end
end
