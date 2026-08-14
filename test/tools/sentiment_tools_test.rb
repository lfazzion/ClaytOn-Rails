# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/profile_management_tools"
require_relative "../../app/tools/sentiment_tools"

class SentimentToolsTest < ActiveSupport::TestCase
  setup do
    @orig_owner_ids = ENV["DISCORD_OWNER_IDS"]
    ENV["DISCORD_OWNER_IDS"] = "12345"
    Thread.current[:cleitin_actor] = { user_id: "12345", username: "dono" }
    Thread.current[:cleitin_turn] = "turn_sentiment"
  end

  teardown do
    ENV["DISCORD_OWNER_IDS"] = @orig_owner_ids
    Thread.current[:cleitin_actor] = nil
    Thread.current[:cleitin_turn] = nil
  end

  test "tools recusam execução para usuário que não é o dono" do
    Thread.current[:cleitin_actor] = { user_id: "99999", username: "intruso" }

    create_res = CreateSentimentTargetTool.new.execute(name: "Alvo Intruso", query: "query")
    assert_equal :error, create_res[:status]

    run_res = RunSentimentAnalysisTool.new.execute(target_identifier: "1")
    assert_equal :error, run_res[:status]

    status_res = SentimentStatusTool.new.execute(target_identifier: "1")
    assert_equal :error, status_res[:status]
  end

  test "tools recusam execução quando DISCORD_OWNER_IDS não está setado (fail-closed)" do
    ENV["DISCORD_OWNER_IDS"] = nil

    create_res = CreateSentimentTargetTool.new.execute(name: "Alvo Sem Env", query: "query")
    assert_equal :error, create_res[:status]
    assert_includes create_res[:reason], "Ação restrita ao dono do bot"

    run_res = RunSentimentAnalysisTool.new.execute(target_identifier: "1")
    assert_equal :error, run_res[:status]

    status_res = SentimentStatusTool.new.execute(target_identifier: "1")
    assert_equal :error, status_res[:status]
  end

  test "create_sentiment_target cria alvo com limites e saneamento" do
    tool = CreateSentimentTargetTool.new
    res = tool.execute(
      name: "Cleitin Alvo Tool",
      query: "cleitin bot",
      sources: "reddit, x",
      window_days: 30,
      bucket: "week",
      max_phrases: 600
    )

    assert_equal :success, res[:status]
    assert_equal "Cleitin Alvo Tool", res[:data][:name]

    target = SentimentTarget.find_by(name: "Cleitin Alvo Tool")
    assert_not_nil target
    assert_equal "cleitin bot", target.query
    assert_equal "reddit,x", target.sources
    assert_equal 600, target.max_phrases
  end

  test "run_sentiment_analysis enfileira job para alvo válido" do
    target = SentimentTarget.create!(name: "Alvo Run Tool", query: "query")
    SentimentAnalysisJob.expects(:perform_later).with(target.id).returns(true)

    tool = RunSentimentAnalysisTool.new
    res = tool.execute(target_identifier: target.name, async: true)

    assert_equal :success, res[:status]
    assert_equal "enqueued", res[:data][:status]
  end

  test "run_sentiment_analysis repassa run_id na execucao ou retry do job" do
    target = SentimentTarget.create!(name: "Alvo Retry Tool", query: "query")
    run = target.sentiment_runs.create!(status: "failed", error: "Timeout", frozen_spec: {})

    SentimentAnalysisJob.expects(:perform_later).with(target.id, run.id).returns(true)

    tool = RunSentimentAnalysisTool.new
    res = tool.execute(target_identifier: target.name, run_id: run.id, async: true)

    assert_equal :success, res[:status]
    assert_equal "enqueued", res[:data][:status]
    assert_equal run.id, res[:data][:run_id]
  end

  test "sentiment_status retorna lista de rodadas" do
    target = SentimentTarget.create!(name: "Alvo Status Tool", query: "query")
    target.sentiment_runs.create!(status: "completed", frozen_spec: {}, collected_count: 50)

    tool = SentimentStatusTool.new
    res = tool.execute(target_identifier: target.id.to_s)

    assert_equal :success, res[:status]
    assert_equal target.name, res[:data][:name]
    assert_equal 1, res[:data][:runs].size
  end

  test "create_sentiment_target recusa criação de 6º alvo ativo via tool com mensagem descritiva" do
    5.times do |i|
      SentimentTarget.create!(name: "Alvo Ativo #{i + 1}", query: "query_#{i + 1}", active: true)
    end

    tool = CreateSentimentTargetTool.new
    res = tool.execute(name: "Alvo Excedente 6", query: "query_6")

    assert_equal :error, res[:status]
    assert_includes res[:reason], "Limite máximo de 5 alvos de sentimento ativos foi atingido"
  end
end
