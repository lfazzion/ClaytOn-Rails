# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/conversation_compactor"
require_relative "../../app/services/conversation_rehydrator"

class ConversationRehydratorTest < ActiveSupport::TestCase
  setup do
    @conversation = Conversation.open_for(scope: "u:1:c:2", channel_id: "2", user_id: "1")
  end

  teardown { ENV.delete("DISCORD_REHYDRATE_MESSAGES") }

  def add_message(role, content, username: "joao")
    ChatMessage.create!(
      conversation: @conversation, role: role, content: content,
      discord_user_id: (role == "user" ? "1" : nil),
      discord_username: (role == "user" ? username : nil)
    )
  end

  test "rehydrate_limit tem padrão 30 e é clampado" do
    assert_equal 30, ConversationRehydrator.rehydrate_limit

    ENV["DISCORD_REHYDRATE_MESSAGES"] = "5"
    assert_equal 5, ConversationRehydrator.rehydrate_limit

    ENV["DISCORD_REHYDRATE_MESSAGES"] = "9999"
    assert_equal 100, ConversationRehydrator.rehydrate_limit
  end

  test "messages_for devolve tudo quando não há resumo" do
    add_message("user", "um")
    add_message("assistant", "dois")

    assert_equal 2, ConversationRehydrator.messages_for(@conversation).size
  end

  test "messages_for pula o que o resumo já cobre" do
    primeira = add_message("user", "coberta")
    add_message("assistant", "viva")
    @conversation.update!(summary: "resumo", summary_covers_upto_id: primeira.id)

    conteudos = ConversationRehydrator.messages_for(@conversation).map(&:content)

    assert_equal ["viva"], conteudos
  end

  test "messages_for respeita o limite, mantendo as mais recentes" do
    ENV["DISCORD_REHYDRATE_MESSAGES"] = "2"
    add_message("user", "antiga")
    add_message("assistant", "meio")
    add_message("user", "recente")

    conteudos = ConversationRehydrator.messages_for(@conversation).map(&:content)

    assert_equal %w[meio recente], conteudos
  end

  test "context_block é nil sem resumo" do
    assert_nil ConversationRehydrator.context_block(@conversation)
  end

  test "context_block traz aviso de referência e o resumo" do
    @conversation.update!(summary: "## Pedido em aberto\n\"faz o relatorio\"")
    bloco = ConversationRehydrator.context_block(@conversation)

    assert_includes bloco, "referência"
    assert_includes bloco, "faz o relatorio"
  end

  test "context_block de conversa compartilhada explica o formato de autor" do
    @conversation.update!(shared: true, summary: "resumo")
    bloco = ConversationRehydrator.context_block(@conversation)

    assert_includes bloco, "<autor>:"
  end

  test "conversa compartilhada sem resumo ainda recebe o bloco multi-usuário" do
    @conversation.update!(shared: true)

    assert_includes ConversationRehydrator.context_block(@conversation).to_s, "<autor>:"
  end

  test "apply! anexa instruções e adiciona as mensagens na ordem" do
    @conversation.update!(summary: "resumo antigo")
    add_message("user", "pergunta")
    add_message("assistant", "resposta")

    chat = mock("chat")
    chat.expects(:with_instructions).with { |texto, append:| texto.include?("resumo antigo") && append }
        .returns(chat)
    sequencia = sequence("mensagens")
    chat.expects(:add_message).with(role: :user, content: "pergunta").in_sequence(sequencia)
    chat.expects(:add_message).with(role: :assistant, content: "resposta").in_sequence(sequencia)

    assert_equal chat, ConversationRehydrator.apply!(chat, @conversation)
  end

  test "apply! não chama with_instructions quando não há bloco" do
    add_message("user", "so isso")
    chat = mock("chat")
    chat.expects(:with_instructions).never
    chat.expects(:add_message).once

    ConversationRehydrator.apply!(chat, @conversation)
  end

  test "apply! carimba o autor em conversa compartilhada" do
    @conversation.update!(shared: true)
    add_message("user", "oi", username: "maria")

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.expects(:add_message).with(role: :user, content: "maria: oi")

    ConversationRehydrator.apply!(chat, @conversation)
  end
end
