# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/discord/command_router"

class Discord::CommandRouterTest < ActiveSupport::TestCase
  test "new e clear são o mesmo comando" do
    assert_equal :new, Discord::CommandRouter.parse_text("!new").name
    assert_equal :new, Discord::CommandRouter.parse_text("!clear").name
  end

  # ANTES os dois viravam :sessions. Separar foi decisão do dono depois que a
  # paginação colidiu com o requisito de eles serem idênticos: o número passaria a
  # significar PÁGINA num e CONVERSA no outro.
  test "sessions e resume são comandos DIFERENTES" do
    assert_equal :sessions, Discord::CommandRouter.parse_text("!sessions").name
    assert_equal :resume, Discord::CommandRouter.parse_text("!resume").name
  end

  test "delete é reconhecido" do
    assert_equal :delete, Discord::CommandRouter.parse_text("!delete").name
  end

  test "help é reconhecido" do
    assert_equal :help, Discord::CommandRouter.parse_text("!help").name
  end

  # O CORAÇÃO DESTA TAREFA. Antes, parse_index clampava para 1..10: "!resume 999"
  # virava 10 e o bot retomava a décima conversa em silêncio, e o mesmo clamp num
  # /delete apagaria a errada. Índice fora da faixa tem que chegar cru para quem
  # sabe o tamanho real da lista transformar em erro visível.
  test "índice NÃO é clampado" do
    assert_equal 999, Discord::CommandRouter.parse_text("!resume 999").arg
    assert_equal 0, Discord::CommandRouter.parse_text("!resume 0").arg
    assert_equal 1, Discord::CommandRouter.parse_text("!resume 1").arg
    assert_equal 47, Discord::CommandRouter.parse_text("!delete 47").arg
  end

  test "comando sem argumento tem arg nil" do
    assert_nil Discord::CommandRouter.parse_text("!resume").arg
    assert_nil Discord::CommandRouter.parse_text("!sessions").arg
  end

  test "argumento não numérico é ignorado" do
    assert_nil Discord::CommandRouter.parse_text("!resume abc").arg
  end

  test "confirm é verdadeiro só com a palavra sim" do
    assert Discord::CommandRouter.parse_text("!delete 3 sim").confirm
    assert Discord::CommandRouter.parse_text("!delete 3 SIM").confirm
    assert Discord::CommandRouter.parse_text("!delete 3   sim  ").confirm
    assert_not Discord::CommandRouter.parse_text("!delete 3").confirm
  end

  # A intenção é "só a palavra sim SOZINHA confirma". "sim senhor" contém o token
  # "sim", mas não está sozinho — é só outro jeito de tentar confirmar sem digitar
  # exatamente a palavra esperada, e por isso também NÃO deve confirmar. (O plano
  # original pulava esta asserção quando o caso confirmava, o que mascarava a
  # intenção em vez de testá-la; corrigido para cobrar o mesmo de todos os casos.)
  test "sinônimo de sim NÃO confirma" do
    ["!delete 3 s", "!delete 3 yes", "!delete 3 confirmar", "!delete 3 sim senhor"].each do |texto|
      comando = Discord::CommandRouter.parse_text(texto)

      assert_not comando.confirm, "#{texto.inspect} não deveria confirmar"
    end
  end

  test "sim sem número não confirma nada e não vira índice" do
    comando = Discord::CommandRouter.parse_text("!delete sim")

    assert_nil comando.arg
    assert_not comando.confirm
  end

  test "texto sem prefixo não é comando" do
    assert_nil Discord::CommandRouter.parse_text("resume 3")
    assert_nil Discord::CommandRouter.parse_text("oi, tudo bem?")
  end

  test "palavra desconhecida com prefixo não é comando" do
    assert_nil Discord::CommandRouter.parse_text("!banana")
    assert_nil Discord::CommandRouter.parse_text("!play alguma musica")
    assert_nil Discord::CommandRouter.parse_text("!")
  end

  test "comando é case-insensitive e tolera espaço em volta" do
    assert_equal :new, Discord::CommandRouter.parse_text("  !NEW  ").name
  end

  test "nil e string vazia não são comando" do
    assert_nil Discord::CommandRouter.parse_text(nil)
    assert_nil Discord::CommandRouter.parse_text("")
  end

  # O caminho slash entrega Integer e Boolean já tipados pelo Discord, não texto.
  test "build aceita inteiro e booleano vindos do slash" do
    comando = Discord::CommandRouter.build("delete", 3, true)

    assert_equal :delete, comando.name
    assert_equal 3, comando.arg
    assert comando.confirm
  end

  test "build com booleano falso do slash não confirma" do
    assert_not Discord::CommandRouter.build("delete", 3, false).confirm
  end

  test "build sem confirmação nenhuma não confirma" do
    assert_not Discord::CommandRouter.build("delete", 3).confirm
  end

  test "SLASH_COMMANDS cobre os nove nomes, e só delete pede confirmação" do
    nomes = Discord::CommandRouter::SLASH_COMMANDS.map { |c| c[:name] }
    assert_equal %w[new clear sessions resume delete help sentiment_target sentiment_run sentiment_status].sort, nomes.sort

    com_confirmacao = Discord::CommandRouter::SLASH_COMMANDS.select { |c| c[:takes_confirm] }
    assert_equal ["delete"], com_confirmacao.map { |c| c[:name] }
  end

  test "sessions, resume e delete declaram opção de número, com rótulos diferentes" do
    por_nome = Discord::CommandRouter::SLASH_COMMANDS.index_by { |c| c[:name] }

    %w[sessions resume delete].each { |nome| assert por_nome[nome][:takes_index] }
    %w[new clear help].each { |nome| assert_not por_nome[nome][:takes_index] }
    assert_not_equal por_nome["sessions"][:index_label], por_nome["resume"][:index_label]
  end

  test "comandos de sentiment são reconhecidos via prefixo text" do
    assert_equal :sentiment_target, Discord::CommandRouter.parse_text("!sentiment_target").name
    assert_equal :sentiment_run, Discord::CommandRouter.parse_text("!sentiment_run 1").name
    assert_equal :sentiment_status, Discord::CommandRouter.parse_text("!sentiment_status 1").name
    assert_equal :sentiment_status, Discord::CommandRouter.parse_text("!sentiment 1").name
  end

  test "comandos de sentiment extraem argumento numérico quando fornecido" do
    cmd_run = Discord::CommandRouter.parse_text("!sentiment_run 42")
    assert_equal :sentiment_run, cmd_run.name
    assert_equal 42, cmd_run.arg

    cmd_status = Discord::CommandRouter.parse_text("!sentiment_status 42")
    assert_equal :sentiment_status, cmd_status.name
    assert_equal 42, cmd_status.arg
  end

  test "build aceita comandos de sentiment vindos de slash command" do
    cmd_target = Discord::CommandRouter.build("sentiment_target")
    assert_equal :sentiment_target, cmd_target.name

    cmd_run = Discord::CommandRouter.build("sentiment_run", 5)
    assert_equal :sentiment_run, cmd_run.name
    assert_equal 5, cmd_run.arg

    cmd_status = Discord::CommandRouter.build("sentiment_status", 5)
    assert_equal :sentiment_status, cmd_status.name
    assert_equal 5, cmd_status.arg
  end

  test "SLASH_COMMANDS inclui comandos de sentiment" do
    nomes = Discord::CommandRouter::SLASH_COMMANDS.map { |c| c[:name] }
    assert_includes nomes, "sentiment_target"
    assert_includes nomes, "sentiment_run"
    assert_includes nomes, "sentiment_status"

    por_nome = Discord::CommandRouter::SLASH_COMMANDS.index_by { |c| c[:name] }
    assert por_nome["sentiment_run"][:takes_index]
    assert por_nome["sentiment_status"][:takes_index]
    assert_not por_nome["sentiment_target"][:takes_index]
  end
end
