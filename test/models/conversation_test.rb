# frozen_string_literal: true

require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  test "open_for cria conversa nova quando não há ativa" do
    conversation = Conversation.open_for(scope: "c:1", channel_id: "1", shared: true)

    assert conversation.persisted?
    assert conversation.active
    assert conversation.shared
    assert_not_nil conversation.last_active_at
  end

  test "open_for devolve a conversa ativa existente" do
    first = Conversation.open_for(scope: "c:1", channel_id: "1", shared: true)
    second = Conversation.open_for(scope: "c:1", channel_id: "1", shared: true)

    assert_equal first.id, second.id
  end

  test "open_for cria outra conversa depois de close!" do
    first = Conversation.open_for(scope: "c:1", channel_id: "1", shared: true)
    first.close!
    second = Conversation.open_for(scope: "c:1", channel_id: "1", shared: true)

    assert_not_equal first.id, second.id
    assert_not first.reload.active
  end

  test "só existe uma conversa ativa por escopo" do
    Conversation.open_for(scope: "c:1", channel_id: "1")

    assert_raises ActiveRecord::RecordNotUnique do
      Conversation.create!(scope: "c:1", discord_channel_id: "1", active: true, last_active_at: Time.current)
    end
  end

  test "escopos diferentes têm conversas ativas independentes" do
    a = Conversation.open_for(scope: "u:1:c:9", channel_id: "9", user_id: "1")
    b = Conversation.open_for(scope: "u:2:c:9", channel_id: "9", user_id: "2")

    assert_not_equal a.id, b.id
  end

  test "assign_title_from trunca em 80 caracteres" do
    conversation = Conversation.open_for(scope: "c:1", channel_id: "1")
    conversation.assign_title_from("a" * 200)

    assert_equal 80, conversation.title.length
  end

  test "assign_title_from não sobrescreve título existente" do
    conversation = Conversation.open_for(scope: "c:1", channel_id: "1")
    conversation.assign_title_from("primeiro")
    conversation.assign_title_from("segundo")

    assert_equal "primeiro", conversation.title
  end

  test "recent ordena da mais recente para a mais antiga" do
    velha = Conversation.create!(scope: "c:1", discord_channel_id: "1", active: false,
                                 last_active_at: 2.days.ago)
    nova = Conversation.create!(scope: "c:1", discord_channel_id: "1", active: false,
                                last_active_at: 1.hour.ago)

    assert_equal [nova.id, velha.id], Conversation.recent.pluck(:id)
  end

  test "recent desempata por id quando last_active_at é idêntico" do
    empatada_1 = Conversation.create!(scope: "c:1", discord_channel_id: "1", active: false,
                                      last_active_at: 1.hour.ago)
    empatada_2 = Conversation.create!(scope: "c:1", discord_channel_id: "1", active: false,
                                      last_active_at: empatada_1.last_active_at)

    assert_equal empatada_1.last_active_at, empatada_2.last_active_at
    assert_equal [empatada_2.id, empatada_1.id], Conversation.recent.pluck(:id)
  end

end
