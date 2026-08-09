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
    assert sorted.first["relevance_score"] > sorted.last["relevance_score"]
  end

  test "nao muta os hashes originais da lista" do
    item = { "title" => "Ruby on Rails tutorial", "url" => "https://reddit.com/r/ruby/1" }
    items = [item]

    sorted = Research::Scorer.sort(items, query: "ruby")

    refute item.key?("relevance_score"), "Hash original não deve conter a chave 'relevance_score'"
    assert sorted.first.key?("relevance_score"), "Novo hash deve conter a chave 'relevance_score'"
  end

  test "item sem campos de texto nao derruba e recebe score" do
    item_vazio = { "url" => "https://example.com" }
    score = Research::Scorer.score(item_vazio, query: "test")

    assert score >= 0.0
    assert score <= 1.0
  end

  test "item nao-hash e nil nao derrubam o sort" do
    bom = { "title" => "React hooks guide", "url" => "https://youtube.com/watch?v=1" }
    sorted = Research::Scorer.sort([nil, "lixo", bom], query: "react hooks")

    assert_equal 1, sorted.size, "nil e string são descartados; só o hash pontua"
    assert_equal "React hooks guide", sorted.first["title"]
  end

  test "fonte desconhecida e sem engajamento nao derrubam o score" do
    item = { "title" => "Coisa qualquer sobre react", "url" => "https://site-estranho.example/x" }
    score = Research::Scorer.score(item, query: "react")

    assert score >= 0.0
    assert score <= 1.0
  end
end
