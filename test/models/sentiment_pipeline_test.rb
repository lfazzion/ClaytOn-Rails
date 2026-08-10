# frozen_string_literal: true

require "test_helper"

class SentimentPipelineModelTest < ActiveSupport::TestCase
  test "cria sentiment_target com validações válidas" do
    target = SentimentTarget.new(
      name: "Cleitin Bot",
      query: "cleitin",
      sources: "reddit,x",
      window_days: 30,
      bucket: "week",
      max_phrases: 600
    )
    assert target.valid?
    target.save!
  end

  test "recusa sentiment_target com bucket inválido" do
    target = SentimentTarget.new(
      name: "Teste",
      query: "teste",
      bucket: "year"
    )
    assert_not target.valid?
    assert_includes target.errors[:bucket], "is not included in the list"
  end

  test "recusa sentiment_target com nome duplicado" do
    SentimentTarget.create!(name: "Duplicado", query: "q1")
    target2 = SentimentTarget.new(name: "Duplicado", query: "q2")
    assert_not target2.valid?
  end

  test "impõe teto máximo de 5 alvos de sentimento ativos" do
    5.times do |i|
      SentimentTarget.create!(name: "Target Ativo #{i}", query: "q#{i}", active: true)
    end

    sexto = SentimentTarget.new(name: "Target Ativo 6", query: "q6", active: true)
    assert_not sexto.valid?
    assert_includes sexto.errors[:base], "Limite máximo de 5 alvos de sentimento ativos foi atingido"
  end

  test "cria sentiment_run e associações" do
    target = SentimentTarget.create!(name: "Target Run", query: "query")
    run = target.sentiment_runs.create!(
      status: "pending",
      frozen_spec: { "name" => "Target Run" },
      started_at: Time.current
    )
    assert run.persisted?
    assert_equal target, run.sentiment_target

    phrase = run.sentiment_phrases.create!(
      source: "reddit",
      external_id: "ext123",
      text: "Frase de teste",
      collected_at: Time.current
    )
    assert phrase.persisted?

    label = phrase.sentiment_labels.create!(
      run_id: run.id,
      pass: 1,
      attempt: 1,
      label: "positive"
    )
    assert label.persisted?
  end

  test "impõe unicidade de (run_id, external_id) em sentiment_phrases" do
    target = SentimentTarget.create!(name: "Target Uniq", query: "q")
    run = target.sentiment_runs.create!(status: "pending", frozen_spec: {})
    run.sentiment_phrases.create!(source: "x", external_id: "ext1", text: "t1", collected_at: Time.current)

    assert_raises(ActiveRecord::RecordNotUnique) do
      run.sentiment_phrases.create!(source: "x", external_id: "ext1", text: "t2", collected_at: Time.current)
    end
  end
end
