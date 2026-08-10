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

  test "empate apos arredondamento segue os valores brutos" do
    # Dois itens com BRUTOS distintos (0.504 / 0.501) que o round(2) expõe
    # como o MESMO 0.5: a ordem final tem que seguir os brutos, não o exibido.
    alto  = { "title" => "React hooks em profundidade", "url" => "https://youtube.com/watch?v=1" }
    baixo = { "title" => "React hooks para iniciantes", "url" => "https://youtube.com/watch?v=2" }

    # Stub POR ITEM (não sequencial): o alto tem o bruto maior mesmo entrando
    # DEPOIS do baixo — aí o sort prova que reverte uma entrada desordenada.
    Research::Scorer.stubs(:score).with(has_entry("title" => "React hooks em profundidade"), anything).returns(0.504)
    Research::Scorer.stubs(:score).with(has_entry("title" => "React hooks para iniciantes"), anything).returns(0.501)

    sorted = Research::Scorer.sort([baixo, alto], query: "react hooks")

    assert_equal "React hooks em profundidade", sorted.first["title"], "bruto maior vem primeiro (entrada revertida)"
    assert_equal 0.5, sorted.first["relevance_score"]
    assert_equal 0.5, sorted.last["relevance_score"]
  end

  test "desempate no sort de itens com mesmo score e deterministico" do
    item_a = { "title" => "B item", "url" => "https://example.com/b" }
    item_b = { "title" => "A item", "url" => "https://example.com/a" }

    Research::Scorer.stubs(:score).returns(0.0)

    # 2 rodadas com ordem de entrada diferente devem produzir a MESMA ordem de saida
    run1 = Research::Scorer.sort([item_a, item_b], query: "xyz")
    run2 = Research::Scorer.sort([item_b, item_a], query: "xyz")

    assert_equal run1.map { |i| i["url"] }, run2.map { |i| i["url"] }
    assert_equal ["https://example.com/a", "https://example.com/b"], run1.map { |i| i["url"] }
  end
end
