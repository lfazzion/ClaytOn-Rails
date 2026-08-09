# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/web_search_tools"

class WebSearchToolOperatorsTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "query com operador de dominio estreita a categoria para general" do
    assert_equal "general", WebSearchTool.new.send(:categories_for, "site:x.com EXM7777")
  end

  # CONTROLE: query sem operador mantem `it`, que e onde stackoverflow e github
  # moram. Sem este controle o conserto poderia ser um recuo da decisao de 05/08.
  test "CONTROLE: query sem operador mantem general,it,science" do
    assert_equal "general,it,science", WebSearchTool.new.send(:categories_for, "ruby 3.4 pattern matching")
  end

  # O teste acima chama o helper privado; ele nao prende o que sai NO FIO. Sem este,
  # `categories: CATEGORIES` de volta na linha 110 deixa a suite verde com o bug de
  # 06/08 inteiro (site:x.com trazendo 10 do Docker Hub e 10 da MDN). Molde de
  # web_search_tools_test.rb:37-47, que e o controle da LARGURA — este e o do
  # ESTREITAMENTO.
  test "o fio HTTP leva categories=general quando a query tem operador de dominio" do
    stub = stub_request(:get, "http://searxng:8080/search")
           .with(query: hash_including(q: "site:x.com EXM7777", categories: "general"))
           .to_return(status: 200, body: { results: [] }.to_json)

    WebSearchTool.new.execute(query: "site:x.com EXM7777")

    assert_requested stub
  end

  test "o token do operador nao conta como termo significativo" do
    termos = WebSearchTool::RelevanceGuard.significant_terms("site:x.com EXM7777")
    refute_includes termos, "site"
    assert_includes termos, "exm7777"
  end

  # CONTROLE do critério simétrico: `categories_for` só estreita com `site:`
  # (operador COM dois-pontos); a palavra solta "site" numa query é termo de
  # busca e a guarda tem de julgar com ela inteira — derrubá-la sem estreitar a
  # categoria era o uso assimétrico que a revisão apontou.
  test "operador sem dois-pontos nao e derrubado dos termos significativos" do
    assert_includes WebSearchTool::RelevanceGuard.significant_terms("site de noticias"), "site"
    refute_includes WebSearchTool::RelevanceGuard.significant_terms("site:x.com EXM7777"), "site",
                   "com os dois-pontos continua sendo operador"
  end

  # CONTROLE: uma palavra comum de tamanho parecido continua contando, senao o
  # filtro estaria derrubando termo bom junto.
  test "CONTROLE: palavra comum continua sendo termo significativo" do
    assert_includes WebSearchTool::RelevanceGuard.significant_terms("ruby performance"), "ruby"
  end

  test "resultado parcial reporta os engines que cairam, sem mudar a forma de data" do
    tool = WebSearchTool.new
    tool.stubs(:fetch).returns(
      results: [{ title: "Is ruby really slow?", url: "https://reddit.com/r/ruby/x", content: "ruby performance", engine: "duckduckgo" }],
      unresponsive: ["brave"]
    )

    resposta = tool.run(query: "ruby performance", limit: 5)

    assert_equal :success, resposta[:status]
    assert_equal ["brave"], resposta[:unresponsive]
    assert_kind_of Array, resposta[:data], "data continua Array — 14 asserts existentes dependem disso"
    assert_equal "https://reddit.com/r/ruby/x", resposta[:data].first[:url]
  end

  # CONTROLE: sem engine caida, `unresponsive` vem vazio — nao um campo que
  # sempre lista alguma coisa.
  test "CONTROLE: sem engine fora, unresponsive vem vazio" do
    tool = WebSearchTool.new
    tool.stubs(:fetch).returns(
      results: [{ title: "Is ruby really slow?", url: "https://reddit.com/r/ruby/x", content: "ruby performance", engine: "duckduckgo" }],
      unresponsive: []
    )

    assert_empty tool.run(query: "ruby performance", limit: 5)[:unresponsive]
  end

  # Acerto de cache nao mede engine nenhum. Reportar [] afirmaria "nenhum caiu",
  # que e medicao que nao aconteceu — metrica ausente e nil, nunca zero.
  test "acerto de cache reporta unresponsive nil, nao lista vazia" do
    tool = WebSearchTool.new
    tool.stubs(:fetch).returns(
      results: [{ title: "t", url: "https://exemplo.dev/a", content: "ruby performance", engine: "duckduckgo" }],
      unresponsive: []
    )
    tool.run(query: "ruby performance", limit: 5)

    segunda = WebSearchTool.new
    segunda.expects(:fetch).never
    resposta = segunda.run(query: "ruby performance", limit: 5)

    # `assert_nil` sozinho passa tambem quando a chave NAO existe (Hash indexa
    # ausente como nil) — e o `Responder.estruturar` ramifica em `key?`.
    assert resposta.key?(:unresponsive),
           "a chave irma tem de EXISTIR valendo nil — Responder.estruturar ramifica em key?"
    assert_nil resposta[:unresponsive]
  end
end
