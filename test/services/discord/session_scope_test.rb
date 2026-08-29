# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/discord/session_scope"

class Discord::SessionScopeTest < ActiveSupport::TestCase
  teardown do
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
    ENV.delete("DISCORD_MUTE_PREFIX")
  end

  test "canal comum gera escopo individual" do
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "9")

    assert_equal "u:7:c:9", scope.key
    assert_not scope.shared
    assert_equal "7", scope.user_id
    assert_equal "9", scope.channel_id
  end

  test "canal aberto gera escopo compartilhado sem usuário" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "9"
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "9")

    assert_equal "c:9", scope.key
    assert scope.shared
    assert_nil scope.user_id
  end

  test "usuários diferentes no canal aberto caem no mesmo escopo" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "9"
    a = Discord::SessionScope.for(user_id: "1", channel_id: "9")
    b = Discord::SessionScope.for(user_id: "2", channel_id: "9")

    assert_equal a.key, b.key
  end

  test "lista de canais aceita espaços e vírgulas" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = " 11 , 22 ,, 33 "

    assert Discord::SessionScope.open_channel?("11")
    assert Discord::SessionScope.open_channel?("22")
    assert Discord::SessionScope.open_channel?("33")
    assert_not Discord::SessionScope.open_channel?("44")
  end

  test "ENV ausente não abre canal nenhum" do
    assert_not Discord::SessionScope.open_channel?("9")
  end

  test "ENV vazia não abre canal nenhum" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = ""

    assert_not Discord::SessionScope.open_channel?("")
    assert_not Discord::SessionScope.open_channel?("9")
  end

  test "prefixo de silêncio padrão é barra dupla" do
    assert_equal "//", Discord::SessionScope.mute_prefix
    assert Discord::SessionScope.muted?("// papo entre humanos")
    assert Discord::SessionScope.muted?("   //com espaço antes")
    assert_not Discord::SessionScope.muted?("oi bot")
  end

  test "prefixo de silêncio é configurável" do
    ENV["DISCORD_MUTE_PREFIX"] = "."

    assert Discord::SessionScope.muted?(".ignora isso")
    assert_not Discord::SessionScope.muted?("// agora não silencia")
  end

  test "prefixo vazio na ENV volta ao padrão" do
    ENV["DISCORD_MUTE_PREFIX"] = ""

    assert_equal "//", Discord::SessionScope.mute_prefix
  end

  test "muted? aceita nil" do
    assert_not Discord::SessionScope.muted?(nil)
  end

  # === Missão thread-heranca (plano v2) ===

  test "open_channel_id ausente assume o proprio channel_id (classificacao igual)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "9"
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "9")
    assert_equal "9", scope.open_channel_id
    assert_equal "9", scope.channel_id
  end

  test "open_channel_id recebe o pai em thread; channel_id mantem a identidade da thread" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "9"
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "10", open_channel_id: "9")
    assert scope.shared
    assert_equal "c:10", scope.key
    assert_equal "10", scope.channel_id
    assert_equal "9", scope.open_channel_id
    assert_nil scope.user_id
  end

  test "thread de canal nao aberto mantem escopo individual com identidade da thread" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "9"
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "10", open_channel_id: "11")
    assert_not scope.shared
    assert_equal "u:7:c:10", scope.key
    assert_equal "10", scope.channel_id
    assert_equal "11", scope.open_channel_id
    assert_equal "7", scope.user_id
  end

  test "open_channel_id nil e canal fechado nao abre nada" do
    scope = Discord::SessionScope.for(user_id: "7", channel_id: "10", open_channel_id: nil)
    assert_not scope.shared
    assert_equal "u:7:c:10", scope.key
    assert_equal "10", scope.channel_id
  end
end
