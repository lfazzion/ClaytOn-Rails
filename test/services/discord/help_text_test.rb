# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/discord/session_scope"
require_relative "../../../app/services/discord/help_text"

class Discord::HelpTextTest < ActiveSupport::TestCase
  teardown { ENV.delete("DISCORD_MUTE_PREFIX") }

  test "cita todos os comandos" do
    texto = Discord::HelpText.render(open_channel: false)

    %w[/new /clear /sessions /resume /help !new !clear !sessions !resume !help].each do |comando|
      assert_includes texto, comando
    end
  end

  test "em canal comum diz que precisa de menção" do
    texto = Discord::HelpText.render(open_channel: false)

    assert_includes texto, "me mencione"
    assert_not_includes texto, "sem precisar mencionar"
  end

  test "em canal aberto diz que responde sem menção e que a conversa é de todos" do
    texto = Discord::HelpText.render(open_channel: true)

    assert_includes texto, "sem precisar mencionar"
    assert_includes texto, "todo mundo"
  end

  test "em canal aberto explica o prefixo de silêncio" do
    texto = Discord::HelpText.render(open_channel: true)

    assert_includes texto, "//"
  end

  test "prefixo de silêncio configurado aparece no texto" do
    ENV["DISCORD_MUTE_PREFIX"] = ">>"
    texto = Discord::HelpText.render(open_channel: true)

    assert_includes texto, ">>"
  end

  test "cabe numa mensagem do Discord" do
    assert_operator Discord::HelpText.render(open_channel: true).length, :<, 2000
    assert_operator Discord::HelpText.render(open_channel: false).length, :<, 2000
  end

  # C5 — o texto antigo prometia "o que você escreveu eu guardo com as suas
  # palavras", mas isso nunca foi uma garantia mecânica: é só um pedido no prompt do
  # resumidor, que pode ser ignorado. Não pode continuar afirmando o que o código
  # não garante.
  test "não promete guardar as mensagens do usuário palavra por palavra" do
    [true, false].each do |open_channel|
      texto = Discord::HelpText.render(open_channel: open_channel)
      assert_not_includes texto, "com as suas palavras"
    end
  end

  # C5 — antes de should_handle? aceitar "!" em qualquer canal (C1), dizer que "!" e
  # "/" funcionam igual em canal comum era mentira: "!help" sem menção não fazia
  # nada. Agora isso é verdade, e o texto precisa dizer isso explicitamente — sem
  # essa frase o usuário de canal comum continuaria achando que precisa mencionar
  # até para rodar um comando.
  test "em canal comum diz que os comandos não precisam de menção" do
    texto = Discord::HelpText.render(open_channel: false)

    assert_includes texto, "não precisam que você me mencione"
  end

  test "cita o /delete nas duas formas" do
    texto = Discord::HelpText.render(open_channel: false)

    assert_includes texto, "/delete"
    assert_includes texto, "!delete"
  end

  test "NÃO descreve mais /sessions e /resume como idênticos" do
    texto = Discord::HelpText.render(open_channel: false)

    assert_not_includes texto, "fazem exatamente o mesmo"
    assert_includes texto, "/sessions"
    assert_includes texto, "/resume"
  end

  test "explica que o delete não alcança a conversa em andamento" do
    texto = Discord::HelpText.render(open_channel: false)

    assert_includes texto, "em andamento"
  end

  test "explica a paginação" do
    assert_includes Discord::HelpText.render(open_channel: false), "/sessions 2"
  end
end
