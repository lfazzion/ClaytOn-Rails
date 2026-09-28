# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require "rake"
require_relative "../../lib/fetcher/channels/x_artigo"

# O `x:artigo` é a porta de linha de comando do caminho de publicação. O que este teste segura é
# o ENVELOPE do comando (leitura de `-`/arquivo, defaults, repasso dos argumentos, status de saída
# e erro tipado) — a publicação em si é do canal, testada em x_artigo_test.rb.
#
# Nenhum teste aqui fala com o X: `XArtigo.publicar` é dublado, e o teste prova que o comando
# entrega os argumentos certos e sai com o contrato certo.
class XArtigoRakeTest < ActiveSupport::TestCase
  A = Fetcher::Channels::XArtigo

  setup do
    # Aplicação nova por teste: o Rake só executa uma task uma vez por processo, e sem isto o
    # segundo teste que invoca `x:artigo` receberia a execução do primeiro em silêncio.
    Rake.application = Rake::Application.new
    # `load` (e não `rake_require`): o nome que o Rake resolve é relativo ao diretório de trabalho,
    # e `rake_require` procuraria `tasks/x.rake` a partir do CWD — que no container é `/rails`, não
    # `lib/`. O caminho ABSOLUTO é o que não depende de CWD.
    load Rails.root.join("lib/tasks/x.rake").to_s
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake.application = nil
    %w[TITULO CORPO VISIBILIDADE CONVERSA RASCUNHO].each { |variavel| ENV.delete(variavel) }
  end

  # O task termina em `exit XComando.executa { ... }`, e `exit` LEVANTA `SystemExit` — o caminho
  # mais fiel é capturar essa exceção, sem dublar `Kernel#exit` (dublar `exit` global vaza para
  # o runner do Minitest e mata a suíte no meio).
  #
  # `$stdout` e `$stdin` são desviados porque o `XComando.executa` escreve no `$stdout` PADRÃO (o
  # rake não passa `saida:`) e o `le_texto` lê do `$stdin` padrão. Sem o desvio, a linha JSON
  # impressa no log do container não chegaria à asserção e o stdin seria o do runner.
  def roda(env, stdin: "")
    ENV.update(env.transform_keys(&:to_s))
    saida = StringIO.new
    status = nil
    original_stdout = $stdout
    original_stdin = $stdin
    $stdout = saida
    $stdin = StringIO.new(stdin)
    begin
      Rake::Task["x:artigo"].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original_stdout
      $stdin = original_stdin
    end
    [status, saida.string]
  end

  # Envolve a chamada direta ao `XComando.executa(saida)`, usada nos testes do envelope de erro —
  # lá o comando é chamado sem passar pelo rake, e a saída é o `StringIO` passado explicitamente.
  def com_saida
    saida = StringIO.new
    status = Fetcher::XComando.executa(saida) { yield }
    [status, saida.string]
  end

  test "publica lendo titulo e corpo de ARQUIVO e devolve uma linha JSON com status 0" do
    titulo = Tempfile.new(["artigo_titulo", ".txt"])
    corpo = Tempfile.new(["artigo_corpo", ".md"])
    titulo.write("Meu artigo\n")
    corpo.write("# Secao\n\ncorpo do artigo\n")
    titulo.flush
    corpo.flush

    A.expects(:publicar).with(titulo: "Meu artigo", corpo: "# Secao\n\ncorpo do artigo",
                               visibilidade: "Public", conversa: "ByInvitation")
           .returns({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" })
    status, saida = roda({ "TITULO" => titulo.path, "CORPO" => corpo.path })

    assert_equal 0, status
    assert_equal({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" },
                 JSON.parse(saida.lines.first))
  ensure
    titulo&.close
    corpo&.close
  end

  test "TITULO=arquivo e CORPO=- leem do stdin so no corpo" do
    A.expects(:publicar).with(titulo: "do arquivo", corpo: "corpo do stdin",
                               visibilidade: "Public", conversa: "ByInvitation").returns({ "id" => "1" })
    titulo = Tempfile.new(["artigo_titulo", ".txt"])
    titulo.write("do arquivo\n")
    titulo.flush
    status, saida = roda({ "TITULO" => titulo.path, "CORPO" => "-" }, stdin: "corpo do stdin\n")

    assert_equal 0, status
    assert_equal({ "id" => "1" }, JSON.parse(saida.lines.first))
  ensure
    titulo&.close
  end

  test "TITULO=- e CORPO=arquivo leem do stdin so no titulo" do
    A.expects(:publicar).with(titulo: "do stdin", corpo: "corpo do arquivo",
                               visibilidade: "Public", conversa: "ByInvitation").returns({ "id" => "2" })
    corpo = Tempfile.new(["artigo_corpo", ".md"])
    corpo.write("corpo do arquivo\n")
    corpo.flush
    status, = roda({ "TITULO" => "-", "CORPO" => corpo.path }, stdin: "do stdin\n")

    assert_equal 0, status
  ensure
    corpo&.close
  end

  # O stdin é UM fluxo e `le_texto` o consome inteiro: com os dois em "-" o título viria com o
  # corpo dentro e o corpo sairia vazio — artigo publicado com o texto trocado. O comando recusa
  # esse par explicitamente, e o teste segura essa recusa.
  test "TITULO=- e CORPO=- juntos sao recusados com o motivo, sem publicar" do
    A.expects(:publicar).never
    status, saida = roda({ "TITULO" => "-", "CORPO" => "-" }, stdin: "T\nC\n")

    assert_equal 1, status
    resultado = JSON.parse(saida.lines.first)
    assert_equal "ArgumentError", resultado["tipo"]
    assert_match(/so um dos dois pode ser/, resultado["erro"])
  end

  test "sem os argumentos obrigatorios sai linha JSON de erro e status 1, sem excecao crua" do
    A.expects(:publicar).never
    status, saida = com_saida do
      titulo = ENV["TITULO"] || raise(ArgumentError, "uso: x:artigo TITULO=-|arquivo CORPO=-|arquivo")
      corpo = ENV["CORPO"] || raise(ArgumentError, "uso: x:artigo TITULO=-|arquivo CORPO=-|arquivo")
      A.publicar(titulo: titulo, corpo: corpo)
    end

    assert_equal 1, status
    resultado = JSON.parse(saida.lines.first)
    assert_match(/uso: x:artigo/, resultado["erro"])
    assert_equal "ArgumentError", resultado["tipo"]
  end

  # O `FormatoInvalido` é filha de `Channels::Error`, então o `XComando.executa` a tipa. Se alguém
  # trocar por `RuntimeError` crua, o porteiro do experimento-x perde o nome do erro e volta a ver
  # backtrace — este teste é o que segura esse contrato.
  test "recusa de formato sai como {erro,tipo:FormatoInvalido} e status 1" do
    A.stubs(:publicar).raises(A::FormatoInvalido, "formato nao suportado: bloco de codigo (x)")
    status, saida = com_saida { A.publicar(titulo: "T", corpo: "```\ncodigo\n```") }

    assert_equal 1, status
    resultado = JSON.parse(saida.lines.first)
    assert_equal "formato nao suportado: bloco de codigo (x)", resultado["erro"]
    assert_equal "FormatoInvalido", resultado["tipo"]
  end

  test "visibilidade e conversa custom sao repassadas ao canal" do
    A.expects(:publicar).with(titulo: "do stdin", corpo: "corpo do arquivo",
                               visibilidade: "Followers", conversa: "All").returns({ "id" => "3" })
    corpo = Tempfile.new(["artigo_corpo", ".md"])
    corpo.write("corpo do arquivo\n")
    corpo.flush
    status, = roda({ "TITULO" => "-", "CORPO" => corpo.path, "VISIBILIDADE" => "Followers", "CONVERSA" => "All" },
                   stdin: "do stdin\n")
    assert_equal 0, status
  ensure
    corpo&.close
  end

  # ── Retomada: sem RASCUNHO= a task segue criando rascunho novo (caminho normal) ──

  test "sem RASCUNHO= a task nao passa rascunho: o canal cria o rascunho" do
    A.expects(:publicar).with(titulo: "T", corpo: "corpo", visibilidade: "Public", conversa: "ByInvitation")
     .returns({ "id" => "42" })
    titulo = Tempfile.new(["artigo_titulo", ".txt"])
    titulo.write("T\n")
    titulo.flush
    status, = roda({ "TITULO" => titulo.path, "CORPO" => "-" }, stdin: "corpo\n")
    assert_equal 0, status
  ensure
    titulo&.close
  end

  # O caminho que fecha o achado 2: a falha no meio devolveu "RASCUNHO=<id>" na mensagem, e quem
  # re-executa passa esse id. A task repassa o id ao canal e NÃO levanta erro de uso.
  test "RASCUNHO=42 e repassado ao canal e nao recusa o comando" do
    A.expects(:publicar).with(titulo: "T", corpo: "corpo", visibilidade: "Public", conversa: "ByInvitation",
                               rascunho: "42")
     .returns({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" })
    titulo = Tempfile.new(["artigo_titulo", ".txt"])
    titulo.write("T\n")
    titulo.flush
    status, saida = roda({ "TITULO" => titulo.path, "CORPO" => "-", "RASCUNHO" => "42" }, stdin: "corpo\n")

    assert_equal 0, status
    assert_equal({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" },
                 JSON.parse(saida.lines.first))
  ensure
    titulo&.close
  end

  # A retomada sem TITULO/CORPO não tem o que reenviar: recusar com o motivo é melhor que publicar
  # o rascunho antigo com título vazio.
  test "RASCUNHO= sem TITULO/CORPO e recusado com o motivo, sem publicar" do
    A.expects(:publicar).never
    status, saida = roda({ "RASCUNHO" => "42" })

    assert_equal 1, status
    resultado = JSON.parse(saida.lines.first)
    assert_equal "ArgumentError", resultado["tipo"]
    assert_match(/com RASCUNHO= informe TITULO e CORPO/, resultado["erro"])
  end

  # `RASCUNHO=` (vazio) é o mesmo que não informar: o comando tem de cair no caminho normal, e não
  # mandar um id vazio ao canal — nem criar rascunho novo por conta própria.
  test "RASCUNHO= vazio e o mesmo que nao informar" do
    A.expects(:publicar).with(titulo: "T", corpo: "corpo", visibilidade: "Public", conversa: "ByInvitation")
     .returns({ "id" => "42" })
    titulo = Tempfile.new(["artigo_titulo", ".txt"])
    titulo.write("T\n")
    titulo.flush
    status, = roda({ "TITULO" => titulo.path, "CORPO" => "-", "RASCUNHO" => "" }, stdin: "corpo\n")
    assert_equal 0, status
  ensure
    titulo&.close
  end

  # `Rake::Task#comment` é nil quando o arquivo é carregado por `load` num `Rake::Application`
  # novo (o `desc` de um task sem `Rake::TaskManager` associado não gruda). O que este teste
  # segura é o que importa para quem descobre o comando: `rails -T` mostra a descrição.
  test "o task existe e depende de :environment" do
    assert_equal ["environment"], Rake::Task["x:artigo"].prerequisites
  end
end
