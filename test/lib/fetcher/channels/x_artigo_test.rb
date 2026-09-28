# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_artigo"

# Publicação de X Article pelo caminho de cookies (GraphQL interno):
#   ArticleEntityDraftCreate -> ArticleEntityUpdateTitle -> ArticleEntityUpdateContent -> ArticleEntityPublish
# A conversão texto -> content_state é PURA (sem rede); a ordem das quatro chamadas é testada com a
# camada de sessão/HTTP stubada, no mesmo padrão dos testes de XEscrita (mocha + Struct de resposta).
class Fetcher::Channels::XArtigoTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  A = Fetcher::Channels::XArtigo
  E = Fetcher::Channels::XEscrita

  def ok(corpo) = Resp.new(status: 200, body: corpo, headers: {})

  # Mocha NÃO enfileira `.stubs(:post)` sucessivos: o último define todos e vale para toda chamada.
  # Este helper casa cada passo pelo que vai na URL (que é o que distingue uma chamada da outra,
  # já que as quatro vão para o mesmo método) e devolve a resposta AQUele passo.
  def passo(operacao, resposta)
    Fetcher::SafeHttpClient.stubs(:post).with { |url, **| url.include?(operacao) }.returns(resposta)
  end

  # Respostas no formato que a referência (edihasaj/slash-x, MIT, src/twitter/articles.ts) lê:
  # `article_entity_results.result.rest_id` e, no publish, `metadata.tweet_results.result.rest_id`.
  def draft(id = "1888000000000000001")
    ok({ "data" => { "articleentity_create_draft" => { "article_entity_results" => { "result" => { "rest_id" => id } } } } }.to_json)
  end

  def titulo(id = "1888000000000000001")
    ok({ "data" => { "articleentity_update_title" => { "rest_id" => id } } }.to_json)
  end

  def conteudo(id = "1888000000000000001")
    ok({ "data" => { "articleentity_update_content_state" => { "rest_id" => id } } }.to_json)
  end

  def publicado(id = "1888000000000000001", tweet = "1888999999999999999")
    corpo = { "data" => { "articleentity_publish" => { "article_entity_results" => { "result" => {
      "rest_id" => id, "metadata" => { "tweet_results" => { "result" => { "rest_id" => tweet } } }
    } } } } }
    ok(corpo.to_json)
  end

  setup do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns([{ "name" => "auth_token", "value" => "segredo-auth-123" },
                                            { "name" => "ct0", "value" => "csrf-ct0-456" }])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(Class.new { def evidence_header(**) = "TXID" }.new)
  end

  # ── 1. Conversão texto -> content_state (PURA, sem rede) ────────────────────
  #
  # Fixtures de DEPOIS: o texto do bloco é o texto VISÍVEL (sem os marcadores) e os offsets
  # contam sobre ele — é assim que o DraftJS indexa `entity_ranges`/`inline_style_ranges`.

  test "conversao pura nao toca a rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    A.content_state("# Titulo\n\nparagrafo")
    A.content_state("- a\n- b")
  end

  test "paragrafos: linhas soltas viram UM bloco e a linha em branco fecha" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("Primeira linha\nsegunda do mesmo paragrafo.\n\nOutro paragrafo.")
    assert_equal ["Primeira linha segunda do mesmo paragrafo.", "Outro paragrafo."],
                 estado["blocks"].map { |b| b["text"] }
    assert(estado["blocks"].all? { |b| b["type"] == "unstyled" && b["data"] == {} &&
                                    b["entity_ranges"] == [] && b["inline_style_ranges"] == [] })
    assert_equal({ "blocks" => estado["blocks"], "entity_map" => [] }, estado)
  end

  test "bloco tem a forma DraftJS: data, text, key, type, entity_ranges, inline_style_ranges" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("oi")["blocks"].first
    assert_equal %w[data text key type entity_ranges inline_style_ranges].sort, bloco.keys.sort
    assert_equal 5, bloco["key"].length, "key de 5 caracteres hex (mesma forma da referencia)"
    assert_match(/\A[0-9a-f]{5}\z/, bloco["key"])
  end

  test "titulos: # e ## viram header-one/header-two e o nivel satura em header-three" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("# Um\n## Dois\n### Tres\n#### Quatro")
    assert_equal %w[header-one header-two header-three header-three], estado["blocks"].map { |b| b["type"] }
    assert_equal %w[Um Dois Tres Quatro], estado["blocks"].map { |b| b["text"] }
  end

  test "listas: - vira unordered-list-item e 1. vira ordered-list-item" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("- alpha\n* beta\n+ gama\n\n1. um\n2) dois")
    assert_equal %w[unordered-list-item unordered-list-item unordered-list-item
                    ordered-list-item ordered-list-item], estado["blocks"].map { |b| b["type"] }
    assert_equal %w[alpha beta gama um dois], estado["blocks"].map { |b| b["text"] }
  end

  test "citacao: > vira blockquote" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("> citacao do autor")
    assert_equal ["blockquote"], estado["blocks"].map { |b| b["type"] }
    assert_equal "citacao do autor", estado["blocks"].first["text"]
  end

  test "link markdown vira entidade LINK com o texto do rotulo e o offset do rotulo" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("Veja [o repo](https://example.com/a) do dia.")
    bloco = estado["blocks"].first
    assert_equal "Veja o repo do dia.", bloco["text"]
    assert_equal [{ "key" => 0, "offset" => 5, "length" => 6 }], bloco["entity_ranges"]
    assert_equal [{ "key" => 0,
                    "value" => { "data" => { "url" => "https://example.com/a", "caption" => "o repo" },
                                 "mutability" => "MUTABLE", "type" => "LINK" } }], estado["entity_map"]
  end

  test "negrito e italico inline viram inline_style_ranges sobre o texto visivel" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("Um **grosso** e um *fino* e um ~~riscado~~.")["blocks"].first
    assert_equal "Um grosso e um fino e um riscado.", bloco["text"]
    assert_equal [{ "offset" => 3, "length" => 6, "style" => "BOLD" },
                  { "offset" => 15, "length" => 4, "style" => "ITALIC" },
                  { "offset" => 25, "length" => 7, "style" => "STRIKETHROUGH" }], bloco["inline_style_ranges"]
    assert_equal [], bloco["entity_ranges"]
  end

  test "snake_case com sublinhado NAO vira italico" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("o campo user_id_str fica assim")["blocks"].first
    assert_equal "o campo user_id_str fica assim", bloco["text"]
    assert_equal [], bloco["inline_style_ranges"]
  end

  test "link e estilo no mesmo bloco: offsets nao se atropelam" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("A [um](https://a.example) e **dois**.")
    bloco = estado["blocks"].first
    assert_equal "A um e dois.", bloco["text"]
    assert_equal [{ "key" => 0, "offset" => 2, "length" => 2 }], bloco["entity_ranges"]
    assert_equal [{ "offset" => 7, "length" => 4, "style" => "BOLD" }], bloco["inline_style_ranges"]
    assert_equal "https://a.example", estado["entity_map"][0]["value"]["data"]["url"]
  end

  # ── Offsets em unidades UTF-16 ────────────────────────────────────────────
  #
  # DraftJS é JavaScript: `offset` e `length` contam UNIDADES DE CÓDIGO UTF-16 (`"😀".length`
  # é 2 em JS), enquanto o Ruby conta pontos de código. Emoji vive fora do BMP e vale 2
  # unidades: contado como 1, todo range depois dele sai deslocado e o X marca a palavra errada
  # (ou recusa o content_state). Os números abaixo são o cálculo à mão, não derivado do código.

  test "offset em UTF-16: emoji ANTES do trecho marca desloca em 2 unidades" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("😀 **grosso** e [link](https://a.example) e ~~fim~~ 😎")["blocks"].first
    assert_equal "😀 grosso e link e fim 😎", bloco["text"]
    # "😀 " = 2 unidades de emoji + 1 de espaço; o rótulo do link começa depois de "😀 grosso e ".
    assert_equal [{ "key" => 0, "offset" => 12, "length" => 4 }], bloco["entity_ranges"]
    assert_equal [{ "offset" => 3, "length" => 6, "style" => "BOLD" },
                  { "offset" => 19, "length" => 3, "style" => "STRIKETHROUGH" }],
                 bloco["inline_style_ranges"]
  end

  test "offset em UTF-16: emoji DENTRO do trecho marcado dobra o length" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("antes **😀😀** depois")["blocks"].first
    assert_equal "antes 😀😀 depois", bloco["text"]
    assert_equal [{ "offset" => 6, "length" => 4, "style" => "BOLD" }], bloco["inline_style_ranges"]
  end

  test "offset em UTF-16: entity_range com dois emoji antes aponta para a palavra certa" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("🚀 🚀 [doc](https://d.example) e **fim**")
    bloco = estado["blocks"].first
    assert_equal "🚀 🚀 doc e fim", bloco["text"]
    # "🚀 🚀 doc e " = 2+1+2+1+3+1+1+1 = 12 unidades (8 pontos de código).
    assert_equal [{ "key" => 0, "offset" => 6, "length" => 3 }], bloco["entity_ranges"]
    assert_equal [{ "offset" => 12, "length" => 3, "style" => "BOLD" }], bloco["inline_style_ranges"]
    assert_equal "https://d.example", estado["entity_map"][0]["value"]["data"]["url"]
  end

  # O `length` do `entity_range` é a MESMA medida do `length` do estilo — o rótulo do link é
  # conteúdo visível e o X o marca como entidade. Contando em pontos de código, um emoji
  # dentro do rótulo encurta a marcação e o link sai apontando para a palavra errada (o X
  # também recusa o content_state). Faltava prova desse lado: os de cima põem emoji ANTES do
  # range ou DENTRO do estilo, nunca dentro do rótulo.
  test "offset em UTF-16: emoji DENTRO do rotulo do link conta no length do entity_range" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("🚀 veja o [doc 😀 final](https://d.example) 🚀")
    bloco = estado["blocks"].first

    assert_equal "🚀 veja o doc 😀 final 🚀", bloco["text"]
    # offset: "🚀 veja o " = 2+1+4+1+1+1 = 10 unidades; rótulo "doc 😀 final" = 3+1+2+1+5 = 12.
    assert_equal [{ "key" => 0, "offset" => 10, "length" => 12 }], bloco["entity_ranges"]
    assert_equal "https://d.example", estado["entity_map"][0]["value"]["data"]["url"]
    # A entidade carrega o rótulo INTEIRO (com o emoji), como o `caption` que o X mostra.
    assert_equal "doc 😀 final", estado["entity_map"][0]["value"]["data"]["caption"]
  end

  test "varios links: cada um com sua entidade e sua chave" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("[um](https://a.example) e [dois](https://b.example)")
    bloco = estado["blocks"].first
    assert_equal "um e dois", bloco["text"]
    assert_equal [{ "key" => 0, "offset" => 0, "length" => 2 }, { "key" => 1, "offset" => 5, "length" => 4 }],
                 bloco["entity_ranges"]
    assert_equal %w[https://a.example https://b.example],
                 estado["entity_map"].map { |e| e["value"]["data"]["url"] }
  end

  # O `entity_ranges.key` é índice do `entity_map` DO ARTIGO. Se cada bloco renumerasse a partir
  # do zero, o segundo bloco com link apontaria para a entidade do primeiro — link trocado, e o
  # leitor do artigo clicaria na URL errada.
  test "links em blocos diferentes: as chaves do entity_map sao do artigo inteiro" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("primeiro [a](https://a.example)\n\nsegundo [b](https://b.example)\n\nterceiro [c](https://c.example)")
    assert_equal [{ "key" => 0, "offset" => 9, "length" => 1 }, { "key" => 1, "offset" => 8, "length" => 1 },
                  { "key" => 2, "offset" => 9, "length" => 1 }],
                 estado["blocks"].map { |b| b["entity_ranges"].first }
    assert_equal %w[https://a.example https://b.example https://c.example],
                 estado["entity_map"].map { |e| e["value"]["data"]["url"] }
    assert_equal [0, 1, 2], estado["entity_map"].map { |e| e["key"] }
  end

  test "o bloco que vai para o X tem SO as seis chaves do DraftJS" do
    Fetcher::SafeHttpClient.expects(:post).never
    bloco = A.content_state("veja [a](https://a.example)")["blocks"].first
    assert_equal %w[data entity_ranges inline_style_ranges key text type], bloco.keys.sort
    refute(bloco.key?("_entidades"), "a chave local de entidade nao pode vazar para o X")
  end

  test "link dentro de lista e de titulo tambem vira entidade" do
    Fetcher::SafeHttpClient.expects(:post).never
    estado = A.content_state("# [repo](https://r.example)\n\n- item com [doc](https://d.example)")
    assert_equal %w[header-one unordered-list-item], estado["blocks"].map { |b| b["type"] }
    assert_equal %w[https://r.example https://d.example], estado["entity_map"].map { |e| e["value"]["data"]["url"] }
    assert_equal [0, 1], estado["blocks"].map { |b| b["entity_ranges"].first["key"] }
  end

  test "recusa o que o content_state NAO suporta: bloco de codigo, tabela e imagem" do
    Fetcher::SafeHttpClient.expects(:post).never
    ["```ruby\nputs 1\n```", "| a | b |\n| --- | --- |\n| 1 | 2 |", "![foto](https://i.example/f.png)"].each do |texto|
      erro = assert_raises(A::FormatoInvalido, "aceitou #{texto.inspect}") { A.content_state(texto) }
      assert_match(/nao suportado/, erro.message)
    end
  end

  test "recusa corpo vazio ou so com branco" do
    Fetcher::SafeHttpClient.expects(:post).never
    ["", "   \n\n\t"].each { |vazio| assert_raises(A::FormatoInvalido) { A.content_state(vazio) } }
  end

  # ── 2. Ordem das quatro chamadas (sessão/HTTP stubada) ───────────────────────
  #
  # A ordem é o contrato do caminho: rascunho -> título -> conteúdo -> publicar. O id do rascunho
  # é o que vai para as três chamadas seguintes, e nenhum passo publica antes do conteúdo.

  test "publicar faz rascunho, titulo, conteudo e publish nessa ordem, com o id do rascunho" do
    ordem = sequence("artigo")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/QID/ArticleEntityDraftCreate" }
                           .in_sequence(ordem).returns(draft("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/ArticleEntityUpdateTitle" &&
        json["variables"] == { "articleEntityId" => "42", "title" => "Meu artigo" } &&
        json["queryId"] == "QID" && json["features"].is_a?(Hash) && headers.is_a?(Hash)
    end.in_sequence(ordem).returns(titulo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url == "https://x.com/i/api/graphql/QID/ArticleEntityUpdateContent" &&
        json["variables"]["article_entity"] == "42" &&
        json["variables"]["content_state"]["blocks"].first["text"] == "corpo do artigo" &&
        json["variables"]["content_state"]["entity_map"] == []
    end.in_sequence(ordem).returns(conteudo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url == "https://x.com/i/api/graphql/QID/ArticleEntityPublish" &&
        json["variables"] == { "articleEntityId" => "42", "visibilitySetting" => "Public",
                               "conversationControl" => { "mode" => "ByInvitation" } }
    end.in_sequence(ordem).returns(publicado("42", "77"))

    assert_equal({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" },
                 A.publicar(titulo: "Meu artigo", corpo: "corpo do artigo"))
  end

  test "o rascunho nasce VAZIO: sem titulo e sem conteudo no primeiro passo" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, **|
      json["variables"] == { "content_state" => { "blocks" => [], "entity_map" => [] }, "title" => "" }
    end.returns(draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    passo("ArticleEntityPublish", publicado("42", "77"))
    A.publicar(titulo: "T", corpo: "C")
  end

  test "o queryId vem do resolver por OPERACAO, nunca de um id fixo" do
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("ArticleEntityDraftCreate").returns("QID_DRAFT")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("ArticleEntityUpdateTitle").returns("QID_TITULO")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("ArticleEntityUpdateContent").returns("QID_CONTEUDO")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("ArticleEntityPublish").returns("QID_PUBLISH")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with(anything, force: true).never

    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/QID_DRAFT/") }.returns(draft("42"))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/QID_TITULO/") }.returns(titulo("42"))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/QID_CONTEUDO/") }.returns(conteudo("42"))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/QID_PUBLISH/") }.returns(publicado("42", "77"))

    A.publicar(titulo: "T", corpo: "C")
  end

  test "queryId nao descoberto na DIFFER na etapa em que falta, sem chamar o X" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with("ArticleEntityUpdateContent").returns(nil)
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("ArticleEntityUpdateContent") }.never
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityUpdateContent/, erro.message)
  end

  test "titulo vazio, corpo vazio e corpo com valor de cookie sao recusados SEM rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(A::FormatoInvalido) { A.publicar(titulo: "  ", corpo: "corpo") }
    assert_raises(A::FormatoInvalido) { A.publicar(titulo: "T", corpo: "\n\n") }
    assert_raises(E::Recusado) { A.publicar(titulo: "T", corpo: "olha segredo-auth-123") }
  end

  # ── O que SAI para o X precisa passar pela conferência, não só o texto visível ──
  #
  # O texto visível é uma das coisas enviadas; a URL do link é OUTRA, e mora no `entity_map`.
  # Conferir só `texto_cheio` deixava passar `[doc](https://x.com/a?auth_token=segredo-auth-123)`.
  # A conferência roda sobre o JSON do `content_state` inteiro — é o que de fato vai no corpo do
  # POST — e ANTES da trava local e da rede (contador de chamadas em zero é a prova).
  test "segredo na URL do link e recusado ANTES de qualquer chamada" do
    Fetcher::SafeHttpClient.expects(:post).never
    Fetcher::HostRateLimiter.expects(:exceeded?).never
    erro = assert_raises(E::Recusado) do
      A.publicar(titulo: "T", corpo: "olha o [doc](https://a.example/?auth_token=segredo-auth-123) da casa")
    end
    assert_match(/valor da sessão do X/, erro.message)
  end

  test "segredo na URL com user:senha@host tambem e recusado antes da rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    erro = assert_raises(E::Recusado) do
      A.publicar(titulo: "T", corpo: "[repo](https://segredo-auth-123:senha@a.example/x)")
    end
    assert_match(/valor da sessão do X/, erro.message)
  end

  # O caminho de continua: um link NORMAL (sem segredo na URL) tem de passar e chegar inteiro na
  # terceira chamada. A conferência não pode ser o que impede o artigo de existir.
  test "link sem segredo na URL passa e a entidade chega no content_state enviado" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.include?("ArticleEntityUpdateContent") &&
        json["variables"]["content_state"]["entity_map"].first["value"]["data"]["url"] == "https://a.example/ok?x=1" &&
        json["variables"]["content_state"]["blocks"].first["entity_ranges"] == [{ "key" => 0,
                                                                                 "offset" => 5,
                                                                                 "length" => 5 }]
    end.returns(conteudo("42"))
    passo("ArticleEntityPublish", publicado("42", "77"))
    assert_equal "77", A.publicar(titulo: "T", corpo: "veja [o doc](https://a.example/ok?x=1)")["tweet_id"]
  end

  # ── Falha parcial: o rascunho já existe no X e a retomada tem de ser possível ──
  #
  # Sem isto, quem re-executa a task depois de uma falha no passo 3 cria OUTRO rascunho e publica
  # o artigo duas vezes. A mensagem de erro precisa dizer o que ficou e como voltar.

  test "falha no 3o passo: a mensagem carrega o id do rascunho e o caminho de retomada" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", ok('{"data":{}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/rascunho 42 ja criado/, erro.message)
    assert_match(/RASCUNHO=42/, erro.message)
    assert_match(/publicaria duplicado/, erro.message)
  end

  # No `Incerto` do publish o pedido PODE ter chegado ao X: a dica de retomar precisa dizer isso,
  # senão o "RASCUNHO=" vira convite a publicar o segundo.
  test "falha incerta no publish avisa que pode ja ter publicado e ainda da a retomada" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    Fetcher::SafeHttpClient.stubs(:post).with { |url, **| url.include?("ArticleEntityPublish") }
                           .raises(Fetcher::SafeHttpClient::BodyTooLarge, "corpo grande demais")
    erro = assert_raises(E::Incerto) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/RASCUNHO=42/, erro.message)
  end

  # ── Publish ambíguo: resposta 2xx que não confirma se publicou ───────────────
  #
  # `Incerto` cobre a resposta que PERDEU. A 2xx malformada é o outro lado da mesma Doubt: o
  # X respondeu 200, o pedido saiu, e o corpo não traz o `rest_id` do artigo — o publish PODE
  # ter saído e a casa não tem como dizer que não saiu. Dizer "só o rascunho está criado" ali é
  # afirmar o que não se sabe, e retomar às cegas publica o artigo duas vezes.
  test "publish com 2xx sem rest_id avisa que pode ter publicado, e nao diz que so o rascunho ficou" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    passo("ArticleEntityPublish", ok('{"data":{}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/confira o artigo 42 antes de retomar/, erro.message)
    assert_match(/RASCUNHO=42/, erro.message)
    refute_match(/so o rascunho esta criado/, erro.message)
  end

  # Corpo que nem é JSON é a mesma Doubt por outro caminho (mesmo `interpreta!` do XEscrita,
  # x_escrita.rb:199-209): o X respondeu 2xx e a casa não sabe o que ele fez com o pedido.
  test "publish com 2xx malformado (corpo nao-JSON) avisa que pode ter publicado" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    passo("ArticleEntityPublish", Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/confira o artigo 42 antes de retomar/, erro.message)
  end

  # O contraponto que impede o aviso de virar texto genérico: quando o X DIZ QUE NÃO (código de
  # recusa), o artigo não saiu e retomar é seguro. Avisar "pode ter publicado" aqui faria quem lê
  # a mensagem ir conferir um artigo que com certeza não existe.
  test "publish recusado pelo X NAO e tratado como possivelmente publicado: o X disse que nao" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    passo("ArticleEntityPublish", ok({ "errors" => [{ "message" => "duplicado", "code" => 187 }] }.to_json))
    erro = assert_raises(E::Recusado) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/so o rascunho esta criado/, erro.message)
    refute_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/RASCUNHO=42/, erro.message)
  end

  # O passo 3 continua sendo o que é: falha de escrita de conteúdo NÃO publica nada, mesmo com
  # resposta 2xx malformada. O aviso de "pode ter publicado" é do passo 4, não de todo 2xx.
  test "falha no 3o passo com 2xx malformado NAO avisa que pode ter publicado" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/so o rascunho esta criado/, erro.message)
    refute_match(/pode JA ter acontecido no X/, erro.message)
  end

  # A trava local do artigo (HostRateLimiter) é NOSSA e dispara ANTES do envio: no passo 4, o
  # pedido do publish nem saiu. Avisar "pode ter publicado" ali seria mandar quem lê a mensagem
  # conferir um artigo que com certeza não existe — e a sobre-aviso cansa: é ela que faz o aviso
  # parecer ruído quando é sinal.
  test "trava local no passo 4 nao avisa que pode ter publicado: o pedido nem saiu" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    chamadas = 0
    # `gate!` roda uma vez por chamada GraphQL: 1=rascunho, 2=título, 3=conteúdo, 4=publicar.
    Fetcher::HostRateLimiter.stubs(:exceeded?).with { |*| chamadas += 1; chamadas > 3 }.returns(true)
    erro = assert_raises(E::RateLimited) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/so o rascunho esta criado/, erro.message)
    refute_match(/pode JA ter acontecido no X/, erro.message)
  end

  # O inverso do teste acima, e o motivo de `passo` existir: a MESMA trava local disparando no
  # passo 2 não pode produzir a mensagem do passo 4. Se o passo não fosse rastreado, qualquer
  # falha no artigo sairia com o texto do publish.
  test "trava local no passo 2 nao vira a mensagem do publish" do
    passo("ArticleEntityDraftCreate", draft("42"))
    chamadas = 0
    Fetcher::HostRateLimiter.stubs(:exceeded?).with { |*| chamadas += 1; chamadas > 1 }.returns(true)
    erro = assert_raises(E::RateLimited) { A.publicar(titulo: "T", corpo: "C") }

    refute_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/so o rascunho esta criado/, erro.message)
  end

  # Falha de rede ANTES do envio (SsrfGuard bloqueia antes de sair) no passo 4: o pedido não
  # chegou ao X, então o artigo NÃO foi publicado. Este teste amarra a promessa do prefixo —
  # se `x_escrita.rb#falha_de_rede!` mudar essa frase, o teste avisa em vez de o aviso virar falso.
  test "falha de rede ANTES do envio no passo 4 nao avisa que pode ter publicado" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    Fetcher::SafeHttpClient.stubs(:post).with { |url, **| url.include?("ArticleEntityPublish") }
                           .raises(Fetcher::SsrfGuard::Blocked, "bloqueado")
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/falha de rede em ArticleEntityPublish/, erro.message)
    refute_match(/pode JA ter acontecido no X/, erro.message)
  end

  # QueryId NÃO DESCOBERTO no passo 4 é o outro pré-envio, e o mais sutil dos dois: o `ResponseError`
  # nasce dentro de `XEscrita#com_query_id` (x_escrita.rb:146-149), ou seja, ANTES de existir URL
  # para o POST — `SafeHttpClient.post` nem é chamado. O passo 4 ser o da publicação não muda isso:
  # o que saiu (ou não saiu) para o X foi a leitura dos bundles, não o publish. Avisar "pode ter
  # publicado" ali manda quem lê a mensagem conferir um artigo que com certeza não está no ar, e é
  # o mesmo ruído que o teste da trava local acima descreve. O texto certo é o de "só o rascunho
  # está criado", e o id do rascunho continua na mensagem — ele segue existindo no X, e é por ele
  # que a retomada acontece.
  test "queryId nao descoberto no passo 4 nao avisa que pode ter publicado: o POST nem saiu" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with("ArticleEntityPublish").returns(nil)
    # Se o POST do publish saísse, o stub de `passo` do passo 3 responderia 200 e o teste
    # passaria por um caminho que não é o do erro: o `never` é o que prova que não houve envio.
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("ArticleEntityPublish") }.never
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    assert_match(/não encontrado nos bundles do X/, erro.message)
    assert_match(/so o rascunho esta criado/, erro.message)
    refute_match(/pode JA ter acontecido no X/, erro.message)
    assert_match(/rascunho 42 ja criado/, erro.message)
    assert_match(/RASCUNHO=42/, erro.message)
  end

  # 401/403 e 429 são o X RESPONDENDO que não executou: não é resposta ambígua, é recusa com
  # status. O aviso de "pode ter publicado" seria falso. (O stub de `passo` é re-declarado a cada
  # volta: o do último `passo(...)` do laço é o que vale, e aqui ele é o do publish.)
  test "publish com 403 ou 429 NAO avisa que pode ter publicado: o X respondeu que nao" do
    [403, 429].each do |status|
      passo("ArticleEntityDraftCreate", draft("42"))
      passo("ArticleEntityUpdateTitle", titulo("42"))
      passo("ArticleEntityUpdateContent", conteudo("42"))
      passo("ArticleEntityPublish", Resp.new(status: status, body: "", headers: {}))
      erro = assert_raises(E::Error, "status #{status}") { A.publicar(titulo: "T", corpo: "C") }

      assert_match(/so o rascunho esta criado/, erro.message, "status #{status}")
      refute_match(/pode JA ter acontecido no X/, erro.message, "status #{status}")
    end
  end

  # O primeiro passo é o único em que NADA ficou: uma dica de retomar ali seria mentira, e o id
  # que ela carregaria nem existe.
  test "falha no 1o passo nao sugere retomar: nao ha rascunho para retomar" do
    passo("ArticleEntityDraftCreate", ok('{"data":{}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }

    refute_match(/RASCUNHO=/, erro.message)
  end

  test "retomar com RASCUNHO=42 nao cria segundo rascunho: tres chamadas, o id do rascunho dado" do
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("ArticleEntityDraftCreate") }.never
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.include?("ArticleEntityUpdateTitle") && json["variables"]["articleEntityId"] == "42"
    end.returns(titulo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.include?("ArticleEntityUpdateContent") && json["variables"]["article_entity"] == "42"
    end.returns(conteudo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.include?("ArticleEntityPublish") && json["variables"]["articleEntityId"] == "42"
    end.returns(publicado("42", "77"))

    assert_equal({ "id" => "42", "tweet_id" => "77", "url" => "https://x.com/i/status/77" },
                 A.publicar(titulo: "T", corpo: "C", rascunho: "42"))
  end

  # A retomada NÃO pode furar a conferência de segredo nem a trava: ela roda antes da rede, como
  # no caminho normal.
  test "retomar com RASCUNHO= nao pula a conferencia de vazamento" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { A.publicar(titulo: "T", corpo: "[doc](https://a.example/?t=segredo-auth-123)",
                                             rascunho: "42") }
  end

  test "RASCUNHO que nao sao digitos e recusado com ArgumentError, sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    ["", "abc", "42; DROP", "42 "].each do |invalido|
      erro = assert_raises(ArgumentError, "aceitou #{invalido.inspect}") do
        A.publicar(titulo: "T", corpo: "C", rascunho: invalido)
      end
      assert_match(/digitos/, erro.message)
    end
  end

  test "rascunho sem rest_id nao publica nada: ResponseError no primeiro passo" do
    Fetcher::SafeHttpClient.expects(:post).once.returns(ok('{"data":{"articleentity_create_draft":{}}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityDraftCreate/, erro.message)
  end

  # Um teste por etapa, e NÃO um laço: stub do mocha sobrevive entre as voltas do laço, e o
  # stub do primeiro caso continuaria casando o segundo passo — o teste passaria por acidente
  # medindo a etapa errada.
  test "ArticleEntityUpdateTitle sem rest_id vira ResponseError na etapa" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", ok('{"data":{"articleentity_update_title":{}}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityUpdateTitle/, erro.message)
  end

  test "ArticleEntityUpdateContent sem rest_id vira ResponseError na etapa" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", ok('{"data":{"articleentity_update_content_state":{}}}'))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityUpdateContent/, erro.message)
  end

  test "rest_id que volta diferente do rascunho e ResponseError na etapa" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("99"))
    erro = assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityUpdateTitle/, erro.message)
  end

  test "publicar sem tweet_id na resposta devolve url nil, nao url inventada" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    passo("ArticleEntityPublish", ok({ "data" => { "articleentity_publish" => { "article_entity_results" => {
      "result" => { "rest_id" => "42" }
    } } } }.to_json))
    assert_equal({ "id" => "42", "tweet_id" => nil, "url" => nil }, A.publicar(titulo: "T", corpo: "C"))
  end

  test "publicar aceita visibilidade e modo de conversa do padrao da referencia" do
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.include?("ArticleEntityPublish") && json["variables"]["visibilitySetting"] == "Followers" &&
        json["variables"]["conversationControl"] == { "mode" => "All" }
    end.returns(publicado("42", "77"))
    A.publicar(titulo: "T", corpo: "C", visibilidade: "Followers", conversa: "All")
  end

  test "visibilidade ou conversa fora do enum e erro de argumento, sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(ArgumentError) { A.publicar(titulo: "T", corpo: "C", visibilidade: "Secreto") }
    assert_raises(ArgumentError) { A.publicar(titulo: "T", corpo: "C", conversa: "Todos") }
  end

  test "erro de codigo do X (187 duplicado) vira Recusado e 429 vira RateLimitedRemote" do
    corpo = { "errors" => [{ "message" => "x", "code" => 187 }] }.to_json
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
    assert_raises(E::Recusado) { A.publicar(titulo: "T", corpo: "C") }
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 429, body: "", headers: {}))
    assert_raises(E::RateLimitedRemote) { A.publicar(titulo: "T", corpo: "C") }
  end

  test "403 vira AuthError e nunca redescobre o queryId" do
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with(anything, force: true).never
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 403, body: "", headers: {}))
    assert_raises(E::AuthError) { A.publicar(titulo: "T", corpo: "C") }
  end

  test "404 no meio redescobre o queryId uma vez e repete so aquele passo" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with("ArticleEntityPublish").returns("VELHO")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("ArticleEntityPublish", force: true).returns("NOVO")
    passo("ArticleEntityDraftCreate", draft("42"))
    passo("ArticleEntityUpdateTitle", titulo("42"))
    passo("ArticleEntityUpdateContent", conteudo("42"))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/VELHO/") }
                           .returns(Resp.new(status: 404, body: "", headers: {}))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/NOVO/") }.returns(publicado("42", "77"))
    assert_equal "77", A.publicar(titulo: "T", corpo: "C")["tweet_id"]
  end

  test "falha de rede DEPOIS do envio e Incerto; ANTES do envio e ResponseError" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    stub_request(:post, "https://x.com/i/api/graphql/QID/ArticleEntityDraftCreate").to_raise(Errno::ECONNRESET)
    erro = assert_raises(E::Incerto) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/ArticleEntityDraftCreate/, erro.message)

    Fetcher::SsrfGuard.stubs(:resolve!).raises(Fetcher::SsrfGuard::Blocked, "bloqueado")
    passo("ArticleEntityDraftCreate", draft("42"))
    Fetcher::SafeHttpClient.stubs(:post).with { |url, **| url.include?("ArticleEntityUpdateTitle") }
                           .raises(Fetcher::SsrfGuard::Blocked, "bloqueado")
    assert_raises(E::ResponseError) { A.publicar(titulo: "T", corpo: "C") }
  end

  # ── Trava local e sessão ────────────────────────────────────────────────────

  test "trava local propria do artigo (scope graphql_artigo) e RateLimited" do
    Fetcher::HostRateLimiter.expects(:exceeded?).with("x.com", **A::BUDGET).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    erro = assert_raises(E::RateLimited) { A.publicar(titulo: "T", corpo: "C") }
    assert_match(/graphql_artigo/, erro.message)
  end

  test "sem sessao no jar, nada sai para a rede" do
    Fetcher::CookieJar.stubs(:valid?).returns(false)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(Fetcher::CookieJar::Expired) { A.publicar(titulo: "T", corpo: "C") }
  end
end
