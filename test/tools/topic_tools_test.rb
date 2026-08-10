# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/profile_management_tools"
require_relative "../../app/tools/topic_tools"

class TopicToolsTest < ActiveSupport::TestCase
  setup do
    @orig_owner_ids = ENV["DISCORD_OWNER_IDS"]
    ENV["DISCORD_OWNER_IDS"] = "12345"
    Thread.current[:cleitin_actor] = { user_id: "12345", username: "dono" }
    Thread.current[:cleitin_turn] = "turn_setup"
  end

  teardown do
    ENV["DISCORD_OWNER_IDS"] = @orig_owner_ids
    Thread.current[:cleitin_actor] = nil
    Thread.current[:cleitin_turn] = nil
  end

  # ── 1. Autorização (fail-closed) ─────────────────────────────────────────────

  test "tools de watchlist recusam execução sem cleitin_actor" do
    Thread.current[:cleitin_actor] = nil

    tools = [
      TopicAddTool.new,
      TopicListTool.new,
      TopicRemoveTool.new
    ]

    tools.each do |tool|
      result = tool.execute(name: "ia")
      assert_equal :error, result[:status], "#{tool.class} deveria ter falhado por falta de ator"
    end
  end

  test "tools de watchlist recusam execução de ator fora da allowlist" do
    Thread.current[:cleitin_actor] = { user_id: "99999", username: "intruso" }

    result = TopicAddTool.new.execute(name: "ia")
    assert_equal :error, result[:status]
  end

  test "tools de watchlist recusam execução sem DISCORD_OWNER_IDS" do
    ENV["DISCORD_OWNER_IDS"] = nil

    result = TopicAddTool.new.execute(name: "ia")
    assert_equal :error, result[:status]
  end

  # ── 2. TopicAddTool ──────────────────────────────────────────────────────────

  test "topic_add cria tópico ativo e normaliza o nome" do
    tool = TopicAddTool.new
    result = tool.execute(name: "  AI   Agents  ")

    assert_equal :success, result[:status]
    assert_equal "ai agents", result[:data][:name]
    assert_equal true, result[:data][:active]

    topic = Topic.find_by(name: "ai agents")
    assert_not_nil topic
    assert topic.active?
  end

  test "topic_add com tópico já ativo retorna already_exists sem duplicar" do
    topic = Topic.create!(name: "ai agents", active: true)

    assert_no_difference "Topic.count" do
      tool = TopicAddTool.new
      result = tool.execute(name: "  AI   Agents  ")

      assert_equal :already_exists, result[:status]
      assert_equal topic.id, result[:data][:id]
    end
  end

  test "topic_add com tópico inativo reativa o tópico com status reactivated" do
    topic = Topic.create!(name: "ai agents", active: false)

    tool = TopicAddTool.new
    result = tool.execute(name: "AI Agents")

    assert_equal :reactivated, result[:status]
    assert topic.reload.active?
  end

  test "topic_add recusa criação além do teto de 15 ativos" do
    15.times do |i|
      Topic.create!(name: "topico #{i}", active: true)
    end

    tool = TopicAddTool.new
    result = tool.execute(name: "topico 16")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "15 tópicos ativos"
  end

  test "topic_add recusa nome com tamanho inválido (<2 ou >100 chars)" do
    tool = TopicAddTool.new

    result_short = tool.execute(name: "a")
    assert_equal :error, result_short[:status]

    result_long = tool.execute(name: "x" * 101)
    assert_equal :error, result_long[:status]
  end

  # ── 3. TopicListTool ─────────────────────────────────────────────────────────

  test "topic_list lista tópicos cadastrados com limit clamp" do
    3.times do |i|
      Topic.create!(name: "topico #{i}", active: true)
    end

    tool = TopicListTool.new
    result = tool.execute(limit: 10)

    assert_equal :success, result[:status]
    assert_equal 3, result[:data].size
  end

  # ── 4. TopicRemoveTool ───────────────────────────────────────────────────────

  test "topic_remove desativa tópico existente (soft delete)" do
    topic = Topic.create!(name: "tecnologia", active: true)

    tool = TopicRemoveTool.new
    result = tool.execute(name: "  Tecnologia ")

    assert_equal :success, result[:status]
    assert_equal false, topic.reload.active?
  end

  test "topic_remove retorna erro para tópico inexistente" do
    tool = TopicRemoveTool.new
    result = tool.execute(name: "fantasma")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "não encontrado"
  end
end
