# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/research/relevance"

class ResearchRelevanceTest < ActiveSupport::TestCase
  test "query react hooks com texto correspondente pontua alto" do
    score = Research::Relevance.token_overlap_relevance("react hooks", "Um guia sobre react hooks para iniciantes")
    assert score > 0.8, "Esperado score alto para match completo, obtido: #{score}"
  end

  test "texto sem overlap retorna 0.0" do
    score = Research::Relevance.token_overlap_relevance("react hooks", "Cozinhando receitas de bolo de cenoura")
    assert_equal 0.0, score
  end

  test "query apenas com tokens genericos limita score em ate 0.24" do
    score = Research::Relevance.token_overlap_relevance("best", "The best guide for everything")
    assert score <= 0.24, "Tokens genéricos devem ficar <= 0.24, obtido: #{score}"
  end

  test "phrase bonus exato para multi-token (0.12) e single token (0.16)" do
    # Texto com tokens extras para a base NÃO capar em 1.0 antes do bonus
    # (senão o bonus some no cap e a diferença medida fica ~0.07, não 0.12).
    pq_multi = Research::Relevance::PreparedQuery.build("react hooks")
    score_with_phrase = Research::Relevance.token_overlap_relevance(pq_multi, "react hooks guide for beginners in 2026 with examples")
    score_without_phrase = Research::Relevance.token_overlap_relevance(pq_multi, "hooks for react in 2026 with many extra tokens")
    assert_in_delta 0.12, (score_with_phrase - score_without_phrase), 0.04

    pq_single = Research::Relevance::PreparedQuery.build("react")
    score_single_phrase = Research::Relevance.token_overlap_relevance(pq_single, "react framework")
    assert score_single_phrase > 0.5
  end

  test "stopwords sao ignoradas" do
    score1 = Research::Relevance.token_overlap_relevance("the react", "react framework")
    score2 = Research::Relevance.token_overlap_relevance("react", "react framework")
    assert_equal score1, score2
  end

  test "expansao de sinonimos funciona para js e javascript" do
    score_js = Research::Relevance.token_overlap_relevance("js", "A complete guide to javascript")
    assert score_js > 0.5, "js deve bater com javascript via sinônimo"

    score_ts = Research::Relevance.token_overlap_relevance("typescript", "Intro to ts programming")
    assert score_ts > 0.5, "typescript deve bater com ts via sinônimo"
  end

  test "query vazia retorna 0.5" do
    assert_equal 0.5, Research::Relevance.token_overlap_relevance("", "algum texto")
    assert_equal 0.5, Research::Relevance.token_overlap_relevance("   ", "algum texto")
  end
end
