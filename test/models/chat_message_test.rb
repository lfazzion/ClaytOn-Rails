# frozen_string_literal: true

require "test_helper"

class ChatMessageTest < ActiveSupport::TestCase
  setup do
    @individual = Conversation.open_for(scope: "u:1:c:2", channel_id: "2", user_id: "1")
    @compartilhada = Conversation.open_for(scope: "c:3", channel_id: "3", shared: true)
  end

  test "aceita apenas os papéis user e assistant" do
    message = ChatMessage.new(conversation: @individual, role: "tool", content: "x")

    assert_not message.valid?
    assert_includes message.errors[:role], "is not included in the list"
  end

  test "mensagem de usuário exige discord_user_id" do
    message = ChatMessage.new(conversation: @individual, role: "user", content: "oi")

    assert_not message.valid?
  end

  test "mensagem de assistente não exige autor" do
    message = ChatMessage.new(conversation: @individual, role: "assistant", content: "olá")

    assert message.valid?
  end

  test "llm_content carimba o autor em conversa compartilhada" do
    message = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                                  discord_user_id: "1", discord_username: "joao")

    assert_equal "joao: oi", message.llm_content
  end

  test "llm_content não carimba em conversa individual" do
    message = ChatMessage.create!(conversation: @individual, role: "user", content: "oi",
                                  discord_user_id: "1", discord_username: "joao")

    assert_equal "oi", message.llm_content
  end

  test "llm_content não carimba resposta do assistente" do
    message = ChatMessage.create!(conversation: @compartilhada, role: "assistant", content: "olá")

    assert_equal "olá", message.llm_content
  end

  test "for_llm devolve em ordem de id" do
    primeira = ChatMessage.create!(conversation: @individual, role: "user", content: "1",
                                   discord_user_id: "1")
    segunda = ChatMessage.create!(conversation: @individual, role: "assistant", content: "2")

    assert_equal [primeira.id, segunda.id], @individual.chat_messages.for_llm.pluck(:id)
  end

  test "llm_content remove dois-pontos, quebra de linha e controle do carimbo" do
    message = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                                  discord_user_id: "1",
                                  discord_username: "mal:\nicioso\x00\x07")

    assert_equal "malicioso: oi", message.llm_content
    assert_not_includes message.llm_content, "\n"
  end

  test "llm_content neutraliza nome que tenta se passar por assistente ou system" do
    %w[assistente ASSISTANT usuario Usuário system SISTEMA].each do |personificacao|
      message = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                                    discord_user_id: "1", discord_username: "  #{personificacao}  ")

      assert_equal "#{ChatMessage::DISPLAY_NAME_FALLBACK}: oi", message.llm_content,
                   "esperava neutralizar '#{personificacao}'"
    end
  end

  test "llm_content limita nome muito longo" do
    message = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                                  discord_user_id: "1", discord_username: "a" * 100)

    assert_equal ChatMessage::DISPLAY_NAME_LIMIT, message.discord_username.length
  end

  test "llm_content preserva nome normal com acento intacto" do
    joao = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                               discord_user_id: "1", discord_username: "João")
    maria = ChatMessage.create!(conversation: @compartilhada, role: "user", content: "oi",
                                discord_user_id: "2", discord_username: "Maria Clara")

    assert_equal "João: oi", joao.llm_content
    assert_equal "Maria Clara: oi", maria.llm_content
  end

  test "assistant? identifica mensagens do assistente e não do usuário" do
    assistente = ChatMessage.new(conversation: @individual, role: "assistant", content: "olá")
    usuario = ChatMessage.new(conversation: @individual, role: "user", content: "oi", discord_user_id: "1")

    assert assistente.assistant?
    assert_not usuario.assistant?
  end
end
