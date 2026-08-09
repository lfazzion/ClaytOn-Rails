# frozen_string_literal: true

require "test_helper"

class PromptLoaderConversationTest < ActiveSupport::TestCase
  test "conversation_summary carrega e injeta o transcript" do
    prompt = Llm::PromptLoader.load(
      "conversation_summary",
      transcript: "usuario: qual o preco do bitcoin?",
      shared: false,
      budget_tokens: 2000
    )

    assert_includes prompt[:user], "qual o preco do bitcoin?"
    assert_includes prompt[:system], "## Pedido em aberto"
  end

  test "system exige as seções obrigatórias" do
    prompt = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                            budget_tokens: 2000)

    ["## Pedido em aberto", "## Objetivo", "## Preferências e restrições do usuário",
     "## Já respondido", "## Fatos críticos"].each do |secao|
      assert_includes prompt[:system], secao
    end
  end

  test "seção Quem é quem só aparece em conversa compartilhada" do
    individual = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                                budget_tokens: 2000)
    compartilhada = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: true,
                                                                   budget_tokens: 2000)

    assert_not_includes individual[:user], "## Quem é quem"
    assert_includes compartilhada[:user], "## Quem é quem"
  end

  test "system manda preservar a fala do usuário literalmente" do
    prompt = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                            budget_tokens: 2000)

    assert_includes prompt[:system], "palavras exatas"
  end

  test "system manda escrever em português e redigir segredos" do
    prompt = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                            budget_tokens: 2000)

    assert_includes prompt[:system], "português"
    assert_includes prompt[:system], "[REDACTED]"
  end

  test "system cobre sinal de reversão" do
    prompt = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                            budget_tokens: 2000)

    assert_includes prompt[:system], "esquece"
  end

  test "orçamento aparece no user" do
    prompt = Llm::PromptLoader.load("conversation_summary", transcript: "x", shared: false,
                                                            budget_tokens: 4321)

    assert_includes prompt[:user], "4321"
  end

  test "partial compaction_notice avisa que é referência e não instrução" do
    texto = Llm::PromptLoader.partial("compaction_notice")

    assert_includes texto, "referência"
    assert_not_equal "", texto
  end

  test "partial multi_user explica o formato de autor" do
    texto = Llm::PromptLoader.partial("multi_user")

    assert_includes texto, "<autor>:"
    assert_not_equal "", texto
  end
end
