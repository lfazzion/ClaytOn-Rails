# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_editar"

class Fetcher::Channels::XEditarTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  X = Fetcher::Channels::XEditar
  E = Fetcher::Channels::XEscrita

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))

  # edit_tweet_ok.json: forma de RESPOSTA montada do grafo que o proprio bundle do X devolve para
  # `edit_control` (main.d0bb33e09c6a2565a.js, os campos `edit_tweet_ids`/`initial_tweet_id`/
  # `editable_until_msecs`/`edits_remaining`) mais o `create_tweet.tweet_results.result.rest_id`
  # medido em 27/09/2026. O corpo do POST e o mesmo do postar: a mutacao e a mesma, so que com
  # `edit_options.previous_tweet_id` (ver o comentario do arquivo).
  def resposta_edicao(id_novo, id_antigo, extra = {})
    controle = { "initial_tweet_id" => id_antigo, "edit_tweet_ids" => [id_antigo, id_novo],
                 "editable_until_msecs" => "1790639000000", "is_edit_eligible" => true, "edits_remaining" => 2 }
    tweet = { "rest_id" => id_novo, "legacy" => { "id_str" => id_novo, "full_text" => "texto novo" },
              "core" => { "user_results" => { "result" => { "legacy" => { "screen_name" => "daemon403" } } } } }
      .merge(extra)
    JSON.generate("data" => { "create_tweet" => { "tweet_results" => { "result" => tweet.merge("edit_control" => controle) } } })
  end

  # A mutação pode devolver o `edit_control` já achatado, sob `initial`, ou aninhado em
  # `edit.edit_control_initial` (as três formas que o cliente do X normaliza, main.d0bb33e09c6a2565a.js).
  # As duas últimas são a MESMA informação, e o canal tem de ler as três.
  def resposta_edit_control_aninhada(id_novo, id_antigo)
    interno = { "edit_tweet_ids" => [id_antigo, id_novo], "editable_until_msecs" => 1_790_639_000_000,
                "is_edit_eligible" => true, "edits_remaining" => "2" }
    JSON.generate("data" => {
                    "create_tweet" => { "tweet_results" => { "result" => {
                      "rest_id" => id_novo,
                      "edit_control" => { "edit" => { "initial_tweet_id" => id_antigo,
                                                    "edit_control_initial" => interno } }
                    } } }
                  })
  end

  setup do
    cookies = [{ "name" => "auth_token", "value" => "segredo-auth-123" }, { "name" => "ct0", "value" => "csrf-ct0-456" }]
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns(cookies)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    fake = Class.new { def evidence_header(**) = "TXID" }.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake)
  end

  # ── O CAMINHO: a mutacao e a mesma do postar, com `edit_options.previous_tweet_id` ──
  test "editar manda CreateTweet com edit_options.previous_tweet_id e o texto novo" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/CreateTweet" &&
        json["variables"]["edit_options"] == { "previous_tweet_id" => "2104291497428345283" } &&
        json["variables"]["tweet_text"] == "texto novo" &&
        json["queryId"] == "QID"
    end.returns(Resp.new(status: 200, body: resposta_edicao("999", "2104291497428345283"), headers: {}))
    X.editar(id: "2104291497428345283", texto: "texto novo")
  end

  # A prova de que a edicao NAO tem caminho proprio: a URL e o operationName sao os do postar,
  # e o queryId continua resolvido em RUNTIME (nada de id fixo no codigo).
  test "a operacao e CreateTweet, a mesma do postar, e o queryId e o do postar" do
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("CreateTweet").returns("QID")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/QID/CreateTweet" }
                                         .returns(Resp.new(status: 200,
                                                            body: resposta_edicao("999", "1"), headers: {}))
    X.editar(id: "1", texto: "oi")
  end

  # A prova de que a variável é o que separa "editar" de "postar": o `postar` NUNCA manda
  # `edit_options`, e o `editar` SEMPRE manda. Sem ela a mesma mutação é um post novo.
  test "o postar nunca manda edit_options e o editar sempre manda" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      !json["variables"].key?("edit_options") && json["variables"]["tweet_text"] == "post comum"
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    E.postar(texto: "post comum")

    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      json["variables"]["edit_options"] == { "previous_tweet_id" => "1" }
    end.returns(Resp.new(status: 200, body: resposta_edicao("999", "1"), headers: {}))
    X.editar(id: "1", texto: "editado")
  end

  # ── O RETORNO: id novo, id do original e se o original continua acessivel ──────
  test "devolve o id NOVO, o id do post original e a url canonica do novo" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: resposta_edicao("2104299999999999999", "2104291497428345283"),
                                             headers: {}))
    saida = X.editar(id: "2104291497428345283", texto: "texto novo")
    assert_equal "2104299999999999999", saida["id"]
    assert_equal "2104291497428345283", saida["id_anterior"]
    assert_equal "https://x.com/i/status/2104299999999999999", saida["url"]
  end

  # O `edit_control.edit_tweet_ids` do X e a CADEIA de versoes: o cliente canonico do proprio X
  # resolve o permalink como o ULTIMO elemento (main.d0bb33e09c6a2565a.js, `getTweetLatestVersionId`).
  test "o edit_control devolve a cadeia de versoes e a janela de edicao" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: resposta_edicao("999", "111"), headers: {}))
    saida = X.editar(id: "111", texto: "oi")
    assert_equal %w[111 999], saida["versoes"]
    assert_equal 2, saida["edicoes_restantes"]
    assert_equal "1790639000000", saida["editavel_ate_ms"]
  end

  # A forma aninhada (`edit.edit_control_initial`) e a MESMA informacao: se o canal so lesse a
  # achatada, devolveria nil num caso em que o X mandou o estado. E o `edits_remaining` que vem
  # como String tem de sair Integer, como o cliente ja-publishedo.
  test "o edit_control aninhado em edit.edit_control_initial tambem e lido" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: resposta_edit_control_aninhada("999", "111"), headers: {}))
    saida = X.editar(id: "111", texto: "oi")
    assert_equal "999", saida["id"]
    assert_equal %w[111 999], saida["versoes"]
    assert_equal 2, saida["edicoes_restantes"]
    assert_equal "1790639000000", saida["editavel_ate_ms"]
  end

  # Sem `edit_control` na resposta: os ids saem (eles vem do `rest_id` e do argumento), e o
  # estado sai nil. Id ausente do estado e melhor do que estado inventado.
  test "sem edit_control na resposta os ids saem e o estado sai nil" do
    corpo = JSON.generate("data" => { "create_tweet" => { "tweet_results" => { "result" => { "rest_id" => "999" } } } })
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
    saida = X.editar(id: "111", texto: "oi")
    assert_equal({ "id" => "999", "id_anterior" => "111", "url" => "https://x.com/i/status/999",
                   "versoes" => nil, "edicoes_restantes" => nil, "editavel_ate_ms" => nil }, saida)
  end

  # ── TETO DE TEXTO: o mesmo de `postar`, com erro tipado ───────────────────────
  test "texto acima de 25.000 e recusado com erro tipado, sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    erro = assert_raises(E::Recusado) { X.editar(id: "1", texto: "a" * (X::MAX_CHARS + 1)) }
    assert_match(/25001 caracteres/, erro.message)
    assert_match(/m[áa]x\. 25000/, erro.message)
  end

  test "o teto e o mesmo do postar (25.000, conta Premium)" do
    assert_equal E::MAX_CHARS, X::MAX_CHARS
    assert_equal 25_000, X::MAX_CHARS
  end

  test "25.000 caracteres chegam inteiros no tweet_text" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      json["variables"]["tweet_text"] == "a" * X::MAX_CHARS
    end.returns(Resp.new(status: 200, body: resposta_edicao("999", "1"), headers: {}))
    assert_equal "999", X.editar(id: "1", texto: "a" * X::MAX_CHARS)["id"]
  end

  test "texto vazio e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { X.editar(id: "1", texto: "   ") }
  end

  test "texto com valor de cookie e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { X.editar(id: "1", texto: "olha isso segredo-auth-123") }
  end

  # ── O ID DO POST: entrada nao confiavel, como o `RASCUNHO=` do artigo ──────────
  test "id do post que nao e so digitos e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    ["", "  ", "abc", "1 OR 1=1", "12/34", "1;2", "-1"].each do |mau|
      erro = assert_raises(ArgumentError, "id #{mau.inspect} passou") { X.editar(id: mau, texto: "oi") }
      assert_match(/id do post/, erro.message)
    end
  end

  test "id valido (so digitos) e aceito" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: resposta_edicao("2", "1"), headers: {}))
    assert_equal "2", X.editar(id: "1", texto: "oi")["id"]
  end

  # ── O QUE A RESPOSTA DO X PODE DIZER (a janela de 1h e o numero de edicoes) ────
  # O X recusa a edicao fora da janela com codigo de recusa; a casa nao pode chamar isso de
  # sucesso nem de "post novo": o texto novo NAO saiu. Estes sao os codigos medidos nas capturas
  # de erro do X para escrita (a lista viva esta em `XEscrita::CODIGOS_RECUSA`).
  test "recusa do X vira Recusado e nao devolve id novo" do
    [187, 186, 144].each do |codigo|
      corpo = { "errors" => [{ "message" => "fora da janela", "code" => codigo }] }.to_json
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      assert_raises(E::Recusado, "codigo #{codigo}") { X.editar(id: "1", texto: "oi") }
    end
  end

  # 2xx CHEGOU ao X e o corpo nao confirma: `tweet_results` existe mas o `result` nao tem
  # `rest_id`. O mesmo cuidado do Article: avisar que a edicao PODE ter saído, porque repetir
  # às cegas edita duas vezes (e cada edicao gasta uma das.allowed do Premium).
  test "2xx sem rest_id vira ResponseError avisando que a edicao pode ter saido" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{"result":{}}}}}',
                                             headers: {}))
    erro = assert_raises(E::ResponseError) { X.editar(id: "1", texto: "oi") }
    assert_match(/pode JA ter sido editado/, erro.message)
  end

  # `tweet_results: {}` com 200: o X engoliu (supressao da conta) — nao e sucesso. DISTINTO do
  # caso acima: aqui o X disse que nao postou, ali ele respondeu sem dizer o que fez.
  test "tweet_results vazio vira Restrito (supressao)" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{}}}}',
                                             headers: {}))
    assert_raises(E::Restrito) { X.editar(id: "1", texto: "oi") }
  end

  # ── queryId velho: o mecanismo do repo, sem id fixo ──────────────────────────
  test "404 ou 422 redescobre o queryId uma vez e repete com o id novo" do
    [404, 422].each do |status|
      resolver = Fetcher::XQueryIdResolver.any_instance
      resolver.stubs(:resolve).with("CreateTweet").returns("VELHO")
      resolver.expects(:resolve).with("CreateTweet", force: true).returns("NOVO")
      ordem = sequence("queryId #{status}")
      Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/VELHO/CreateTweet" }
                             .in_sequence(ordem).returns(Resp.new(status: status, body: "", headers: {}))
      Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/NOVO/CreateTweet" }
                             .in_sequence(ordem)
                             .returns(Resp.new(status: 200, body: resposta_edicao("999", "1"), headers: {}))
      assert_equal "999", X.editar(id: "1", texto: "oi")["id"]
    end
  end

  test "queryId nao descoberto da erro claro e nada e enviado" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns(nil)
    Fetcher::SafeHttpClient.expects(:post).never
    erro = assert_raises(E::ResponseError) { X.editar(id: "1", texto: "oi") }
    assert_match(/CreateTweet/, erro.message)
    assert_match(/não encontrado nos bundles do X/, erro.message)
  end

  # ── Trava local: a de `postar` (mesma balde de escrita) ────────────────────────
  test "limite local estourado vira RateLimited" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::RateLimited) { X.editar(id: "1", texto: "oi") }
  end

  # ── Falha de rede depois do envio: pode ter editado ─────────────────────────
  test "conexao resetada depois do envio vira Incerto" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    stub_request(:post, "https://x.com/i/api/graphql/QID/CreateTweet").to_raise(Errno::ECONNRESET)
    assert_raises(E::Incerto) { X.editar(id: "1", texto: "oi") }
  end
end
