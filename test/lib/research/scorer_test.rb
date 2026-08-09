# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/research/scorer"

class ResearchScorerTest < ActiveSupport::TestCase
  test "ordena itens por score decrescente" do
    item_relevante = { "title" => "Aprenda React Hooks do zero", "url" => "https://youtube.com/watch?v=1", "likes" => 100 }
    item_irrelevante = { "title" => "Receita de bolo", "url" => "https://youtube.com/watch?v=2", "likes" => 10 }

    items = [item_irrelevante, item_relevante]
    sorted = Research::Scorer.sort(items, query: "react hooks")

    assert_equal "Aprenda React Hooks do zero", sorted.first["title"]
    assert sorted.first["score"] > sorted.last["score"]
  end

  test "nao muta os hashes originais da lista" do
    item = { "title" => "Ruby on Rails tutorial", "url" => "https://reddit.com/r/ruby/1" }
    items = [item]

    sorted = Research::Scorer.sort(items, query: "ruby")

    refute item.key?("score"), "Hash original não deve conter a chave 'score'"
    assert sorted.first.key?("score"), "Novo hash deve conter a chave 'score'"
  end

  test "item sem campos de texto nao derruba e recebe score" do
    item_vazio = { "url" => "https://example.com" }
    score = Research::Scorer.score(item_vazio, query: "test")

    assert score >= 0.0
    assert score <= 1.0
  end
end
