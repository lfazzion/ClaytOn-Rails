# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/discord_message_chunker"

# Unit test do ALGORITMO de chunking (Achado 5, PR #36).
# O algoritmo mora aqui, no helper único; os jobs só delegam (ver testes de
# jobs). Cobre o furo das variantes antigas: linha isolada > limite estourava
# o limite do Discord (URL longa, bloco de código, tabela).
class DiscordMessageChunkerTest < ActiveSupport::TestCase
  test "mensagem curta retorna array com a mensagem unica" do
    message = "Resumo simples"

    assert_equal [message], DiscordMessageChunker.chunk(message)
  end

  test "mensagem vazia retorna array vazio" do
    assert_equal [], DiscordMessageChunker.chunk("")
  end

  test "mensagem nil retorna array vazio" do
    assert_equal [], DiscordMessageChunker.chunk(nil)
  end

  test "mensagem de exatamente limit chars retorna um unico chunk" do
    message = "a" * 1900

    assert_equal [message], DiscordMessageChunker.chunk(message)
  end

  test "mensagem multi-linha acima do limite quebra em chunks <= limit preservando o conteudo" do
    lines = ["a" * 800, "b" * 800, "c" * 800]
    message = lines.join("\n")

    chunks = DiscordMessageChunker.chunk(message)

    assert chunks.size > 1, "mensagem de #{message.length} chars deve gerar mais de 1 chunk"
    chunks.each { |c| assert c.length <= 1900, "chunk tem #{c.length} chars, limite 1900" }
    assert_equal message, chunks.join("\n"),
                 "join dos chunks deve reproduzir a mensagem sem perder linhas"
  end

  test "linha isolada maior que o limite sofre hard split em pedacos <= limit" do
    long_line = "x" * 1950

    chunks = DiscordMessageChunker.chunk(long_line)

    assert_equal ["x" * 1900, "x" * 50], chunks
    chunks.each { |c| assert c.length <= 1900, "chunk tem #{c.length} chars, limite 1900" }
    assert_equal long_line, chunks.join,
                 "a concatenacao dos fragmentos deve reproduzir a linha longa (nada truncado)"
  end

  test "borda: mensagem de limit + 1 chars vira 2 chunks (limit + resto)" do
    message = "y" * 1901

    assert_equal ["y" * 1900, "y"], DiscordMessageChunker.chunk(message)
  end

  test "linha longa no meio da mensagem nao engole as linhas vizinhas" do
    message = "inicio\n" + ("z" * 1950) + "\nfim"

    chunks = DiscordMessageChunker.chunk(message)

    chunks.each { |c| assert c.length <= 1900, "chunk tem #{c.length} chars, limite 1900" }
    assert_equal "inicio", chunks.first
    assert_equal "fim", chunks.last
  end
end