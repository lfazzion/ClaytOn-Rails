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

  # ---------------------------------------------------------------------------
  # D2-F5a-v3 (30/08/2026) — Caracterização do teto de conversa no model
  # ---------------------------------------------------------------------------
  #
  # Estes testes travam o MODEL: a coluna `web_search_count` existe, começa
  # em 0 (default da migration), o teto MAX_WEB_SEARCH_PER_CONVERSATION é
  # 5, e `increment_counter` (UPDATE atômico por PK) persiste.

  test "D2-F5a-v3: web_search_count começa em zero em conversa nova" do
    conversation = Conversation.open_for(scope: "c:d2f5av3", channel_id: "1", shared: true)

    assert_equal 0, conversation.web_search_count,
                 "default da migration (default: 0, null: false) — toda conversa NOVA começa em 0"
    assert_equal 5, Conversation::MAX_WEB_SEARCH_PER_CONVERSATION
  end

  test "D2-F5a-v3: increment_counter persiste web_search_count atomicamente" do
    conversation = Conversation.open_for(scope: "c:d2f5av3:inc", channel_id: "1", shared: true)
    initial = conversation.web_search_count

    Conversation.increment_counter(:web_search_count, conversation.id)

    refute_equal initial, conversation.reload.web_search_count,
                 "increment_counter deve ter persistido a mudança"
    assert_equal initial + 1, conversation.reload.web_search_count

    # Mais 4 incrementos satura o teto (5/5): prova que a coluna está
    # escrevendo (não só sendo lida como 0 por bug de migration).
    4.times { Conversation.increment_counter(:web_search_count, conversation.id) }
    assert_equal Conversation::MAX_WEB_SEARCH_PER_CONVERSATION, conversation.reload.web_search_count
  end
end
