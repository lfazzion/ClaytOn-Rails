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
  # `rest_id`. O mesmo cuidado do Article: avisar que a edicao PODE ter saido, porque repetir
  # às cegas edita duas vezes (e cada edicao gasta uma das.allowed do Premium).
  test "2xx sem rest_id vira Incerto avisando que a edicao pode ter saido" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{"result":{}}}}}',
                                             headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "1", texto: "oi") }
    assert_match(/pode JA ter sido editado/, erro.message)
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
  end

  # `tweet_results: {}` com 200: o X engoliu a chamada (supressao) — nao e sucesso. E o caminho
  # que o codigo antigo reconhecia como "post suprimido" era o que FAZIA a barreira de retomada
  # falhar: a edicao pode ter saido e a mensagem dizia so "suprimido", mandando repetir. Agora e
  # o mesmo `Incerto` do caso sem `rest_id`, com o aviso de conferir — e nunca mais "so suprimido".
  test "tweet_results vazio vira Incerto com aviso de conferir, e nao Restrito" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{}}}}',
                                             headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "1", texto: "oi") }
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
    refute_match(/so o post suprimido/, erro.message)
  end

  # 2xx sem JSON: o `graphql!` do `XEscrita` levanta, e a edicao tem de reportar a duvida da MESMA
  # forma que os outros dois ramos — E tem de dizer que e EDICAO, porque o custo de repetir aqui
  # (outra versao) nao e o custo de repetir um postar (outro post). Sem a traducao, o operador
  # veria o aviso generico de escrita e nao saberia o que conferir.
  test "2xx sem JSON vira o mesmo Incerto avisando que a EDICAO pode ter saido" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "1", texto: "oi") }
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
    assert_includes erro.message, E::CUSTO_REPETIR_EDITAR
    assert_includes erro.message, "conferir o post 1"
  end

  # O aviso tem de mandar a ACAO, e nao so levantar duvida: quem le e decide repetir. E o repetir
  # que cria a OUTRA versao do post. A frase e a que o `postar` manda tambem — os dois caminhos
  # tem de falar a mesma coisa, senao o operador aprende que so a edicao exige conferir.
  test "o aviso manda conferir o post ANTES de repetir, e diz o custo de repetir as cegas" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{}}}}',
                                             headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "1", texto: "oi") }
    assert_match(/confira o post ANTES de repetir/, erro.message)
    assert_includes erro.message, E::CUSTO_REPETIR_EDITAR
    assert_includes erro.message, "conferir o post 1"
    refute_match(/tente de novo|repita agora/i, erro.message)
  end

  # Os tres ramos tem de ser INDISTINGUEIS pelo resultado: mesma classe, mesmo aviso. O que muda
  # entre eles e o que o X respondeu, nao o que a casa pode concluir.
  test "os tres ramos de 2xx sem id saem com a mesma classe e o mesmo aviso" do
    corpos = {
      "sem JSON" => "<html>erro do proxy</html>",
      "JSON sem rest_id" => '{"data":{"create_tweet":{"tweet_results":{"result":{}}}}}',
      "tweet_results vazio" => '{"data":{"create_tweet":{"tweet_results":{}}}}'
    }
    classes = corpos.map do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, nome) { X.editar(id: "1", texto: "oi") }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, nome
      erro.class
    end
    assert_equal 1, classes.uniq.length
  end

  # ── "ID UTILIZÁVEL": a definição POSITIVA (a forma do id), não uma lista de proibidos ────
  #
  # `XEditar` tinha a mesma condicao so-`nil?` do `postar`: com `rest_id: ""` a edicao devolvia
  # `{"id" => "", "url" => "https://x.com/i/status/"}` e SAIA COMO SUCESSO. A r1 achou o
  # `tweet_results` vazio, a r2 o `rest_id: ""` e a r3 (revisao `t_3581f942`) OITO formas a mais
  # que chegavam ao SUCESSO tambem aqui. As tres rodadas quebraram a MESMA regra, e a causa esta
  # no COMO ela foi escrita: como lista do que e PROIBIDO (ausente, `""`, `"   "`, zero). Lista
  # do que e proibido nunca fecha — cada rodada acha uma forma fora da lista. A inversao e a
  # regra: o id do X e um SNOWFLAKE, so DIGITOS com valor MAIOR QUE ZERO, e nada mais entra.
  #
  # A edicao e o fluxo que mais sofre de id nao utilizavel: ela tem DOIS ids (o pedido e o novo)
  # e monta a `url` a partir do novo, entao o que nao tem a forma do snowflake viraria
  # `/i/status/<lixo>` — uma url que PARECE post e induz a repetir a edicao (que cria OUTRA
  # versao do mesmo post, gastando a janela do Premium).
  FORMAS_NAO_UTILIZAVEIS = {
    # ── as OITO medidas pela revisao da r3 ──
    "rest_id inteiro negativo" => { "rest_id" => -1 },
    "rest_id negativo em string" => { "rest_id" => "-1" },
    "rest_id decimal em string" => { "rest_id" => "1.5" },
    "rest_id com letra" => { "rest_id" => "123abc" },
    "rest_id com espaco no meio" => { "rest_id" => "12 34" },
    "rest_id com barra" => { "rest_id" => "123/evil" },
    "rest_id com query string" => { "rest_id" => "123?x=1" },
    "rest_id float" => { "rest_id" => 1.5 },
    # ── a NONA, medida pela r4: FORA da faixa de 64 bits sem sinal ──
    # Forma certa (só dígitos, > 0) e ainda assim não é um id que o X emitiu: snowflake é um
    # inteiro de 64 bits sem sinal, e 2^64 é o valor mais uma vez. Saía como SUCESSO e montava
    # `/i/status/18446744073709551616` na edição — url que PARECE post e induz a repetir a
    # edição (que cria OUTRA versão e gasta a janela do Premium).
    "rest_id inteiro 2^64" => { "rest_id" => 2**64 },
    "rest_id string 21 digitos" => { "rest_id" => "1#{'0' * 20}" },
    # ── as QUATRO da r2, que continuam fora por ausentes/vazias/zero ──
    "rest_id ausente" => {},
    "rest_id vazio" => { "rest_id" => "" },
    "rest_id so espacos" => { "rest_id" => "   " },
    "rest_id inteiro 0" => { "rest_id" => 0 },
    # ── a borda escolhida: zero escrito, o sinal que some no `to_i`, espaco nas pontas,
    #    quebra de linha no fim (`\z`, e nao `\Z`), e os tipos que o JSON traz e nao sao numero ──
    "rest_id string 0" => { "rest_id" => "0" },
    "rest_id string 00" => { "rest_id" => "00" },
    "rest_id string -0" => { "rest_id" => "-0" },
    "rest_id com espaco nas pontas" => { "rest_id" => " 123 " },
    "rest_id com quebra de linha ao fim" => { "rest_id" => "123\n" },
    "rest_id booleano" => { "rest_id" => true },
    "rest_id lista" => { "rest_id" => [] },
    "rest_id objeto" => { "rest_id" => {} }
  }.freeze

  def corpo_com_rest_id(result)
    JSON.generate("data" => { "create_tweet" => { "tweet_results" => { "result" => result } } })
  end

  test "editar: cada forma de id novo nao utilizavel e Incerto, e NUNCA sucesso" do
    FORMAS_NAO_UTILIZAVEIS.each do |nome, result|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_com_rest_id(result), headers: {}))
      erro = assert_raises(E::Incerto, "editar #{nome}") { X.editar(id: "111", texto: "oi") }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "editar #{nome}"
      assert_includes erro.message, E::CUSTO_REPETIR_EDITAR, "editar #{nome}"
      assert_includes erro.message, "conferir o post 111", "editar #{nome}"
      refute_kind_of E::Restrito, erro, "editar #{nome} nao pode dizer so 'suprimido'"
    end
  end

  # O caminho feliz da edicao nao pode quebrar: id real continua sucesso, e a url sai do id NOVO
  # (nao do id pedido). Sem este teste os de cima passariam com uma regra que recusasse tudo.
  test "com id novo real a edicao continua sucesso, e a url sai do id novo" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: resposta_edicao("2104299999999999999", "111"),
                                             headers: {}))
    saida = X.editar(id: "111", texto: "oi")
    assert_equal "2104299999999999999", saida["id"]
    assert_equal "111", saida["id_anterior"]
    assert_equal "https://x.com/i/status/2104299999999999999", saida["url"]
  end

  # O QUE A r3 ACHOU: as formas que nao tem a forma do snowflake chegavam ao SUCESSO da edicao e
  # montavam uma `url` de status com lixo dentro (`/i/status/1.5`, `/i/status/123/evil` — esta
  # ultima ainda vira OUTRO caminho na url). Alem de recusar, a edicao nao pode devolver `url`
  # nenhuma: sem id novo nao ha post novo, e uma url que parece post e o que faz o operador
  # repetir a edicao (o que cria OUTRA versao e gasta a janela do Premium).
  test "as oito formas da r3 nao voltam como sucesso nem viram url de status" do
    ["-1", "1.5", "123abc", "12 34", "123/evil", "123?x=1"].each do |mau|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_com_rest_id("rest_id" => mau), headers: {}))
      erro = assert_raises(E::Incerto, "rest_id #{mau.inspect} saiu como sucesso") { X.editar(id: "111", texto: "oi") }
      assert_includes erro.message, mau.inspect, "o aviso tem de mostrar a forma que o X devolveu"
      refute_match(%r{https://x\.com/i/status/}, erro.message, "o aviso nao pode oferecer url de status")
    end
  end

  # A mesma coisa para os valores que o JSON traz e NAO sao numero (float, booleano, lista,
  # objeto): o `to_s` deles viraria url de qualquer jeito (`true`, `1.5`, `[]`, `{}`).
  test "rest_id que nao e numero (float, booleano, lista, objeto) tambem vira Incerto" do
    [1.5, true, false, [], {}].each do |mau|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_com_rest_id("rest_id" => mau), headers: {}))
      erro = assert_raises(E::Incerto, "rest_id #{mau.inspect} saiu como sucesso") { X.editar(id: "111", texto: "oi") }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "rest_id #{mau.inspect}"
    end
  end

  # O aviso da edicao tem de mostrar a FORMA devolvida, e dizer o que a casa faz com ela: sem o
  # id novo a `url` nao pode ser montada (url com id vazio parece um link de verdade).
  test "o Incerto da edicao mostra a forma do id devolvido e nao devolve url" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_com_rest_id("rest_id" => "   "), headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "111", texto: "oi") }
    assert_includes erro.message, 'rest_id="   "'
    assert_match(/pode JA ter sido editado/, erro.message)
  end

  # ── ACHADO 1 DA r4: A FAIXA DO SNOWFLAKE (64 bits sem sinal, > 0) ──────────────
  #
  # A forma POSITIVA da r3 (só dígitos, valor > 0) está certa e continua; o que faltava era a
  # FAIXA, e a faixa é parte da definição do snowflake: um id do X é um INTEIRO DE 64 BITS SEM
  # SINAL, MAIOR QUE ZERO — de 1 a 2^64 − 1. A r4 mediu `18446744073709551616` (2^64) saindo
  # como SUCESSO: `url` de status com esse número dentro, que PARECE post e induz a repetir a
  # edição (OUTRA versão, gastando uma das `.allowed` da janela do Premium).
  TETO = (2**64) - 1
  ACIMA = 2**64

  test "editar: id novo fora da faixa de 64 bits e Incerto, e nao monta url de status" do
    [ACIMA, ACIMA.to_s, "1#{'0' * 20}"].each do |fora|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_com_rest_id("rest_id" => fora), headers: {}))
      erro = assert_raises(E::Incerto, "editar rest_id #{fora.inspect}") { X.editar(id: "111", texto: "oi") }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "editar #{fora.inspect}"
      assert_includes erro.message, E::CUSTO_REPETIR_EDITAR, "editar #{fora.inspect}"
      assert_includes erro.message, "conferir o post 111", "editar #{fora.inspect}"
      refute_match(%r{https://x\.com/i/status/}, erro.message,
                   "o aviso nao pode oferecer url de status para #{fora.inspect}")
    end
  end

  test "editar: id novo no teto (2^64-1) continua SUCESSO, e a url sai do id novo" do
    [TETO, TETO.to_s].each do |no_teto|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: resposta_edicao(no_teto.to_s, "111"), headers: {}))
      saida = X.editar(id: "111", texto: "oi")
      assert_equal no_teto.to_s, saida["id"], "editar com id no teto #{no_teto.inspect}"
      assert_equal "111", saida["id_anterior"]
      assert_equal "https://x.com/i/status/#{no_teto}", saida["url"]
    end
  end

  # ── ACHADO 2 DA r4: CORPO INESPERADO NO 2xx E INCERTO, NUNCA TypeError ────────
  #
  # `Hash#dig` NÃO devolve `nil` para corpo inesperado: levanta `TypeError` no primeiro nível
  # que não é hash. Com `result` ESCALAR (`"oops"`) o `TypeError` ESCAPAVA do canal da edição
  # como `TypeError` — e isso é pior que a ambiguidade do `Incerto`, porque quem chamou não
  # descobre se a edição saiu. A 2xx prova que o pedido chegou ao X; a casa não sabe dizer que
  # a edição NÃO saiu, então tem de dizer que não sabe.
  #
  # São DUAS camadas, e as duas são `Incerto` — o que muda é a frase, porque muda ONDE a duvida
  # apareceu (e o que o operador precisa ler):
  #   - corpo que nem e objeto JSON na raiz (`[]`, `"oops"`, `null`): o `interpreta!` levanta o
  #     aviso generico de escrita, e o `graphql_da_edicao!` traduz para o custo da EDICAO;
  #   - objeto JSON com a forma errada DENTRO: o `dig_seguro` devolve `nil`, e a edicao levanta o
  #     `Incerto` dela, que nomeia o post a conferir e o `rest_id` que o X devolveu.
  # Nenhuma das duas pode estourar `TypeError`, e nenhuma pode oferecer `url` de status.
  CORPOS_INESPERADOS = {
    "result escalar" => '{"data":{"create_tweet":{"tweet_results":{"result":"oops"}}}}',
    "result inteiro" => '{"data":{"create_tweet":{"tweet_results":{"result":123}}}}',
    "result lista" => '{"data":{"create_tweet":{"tweet_results":{"result":[]}}}}',
    "result null" => '{"data":{"create_tweet":{"tweet_results":{"result":null}}}}',
    "tweet_results escalar" => '{"data":{"create_tweet":{"tweet_results":"oops"}}}',
    "tweet_results lista" => '{"data":{"create_tweet":{"tweet_results":[]}}}',
    "create_tweet escalar" => '{"data":{"create_tweet":"oops"}}',
    "data escalar" => '{"data":"oops"}',
    "data lista" => '{"data":[]}',
    "sem data" => '{}',
    "create_tweet vazio" => '{"data":{"create_tweet":{}}}'
  }.freeze
  # A raiz que nem e objeto JSON: a duvida aparece ANTES do fluxo ver o corpo.
  CORPOS_NAO_OBJETO_JSON = {
    "raiz lista" => '[]',
    "raiz escalar" => '"oops"',
    "raiz null" => 'null',
    "raiz nao-JSON" => "<html>erro do proxy</html>",
    "raiz vazia" => ""
  }.freeze

  test "editar: 2xx com corpo inesperado e sempre Incerto, nunca TypeError" do
    classes = {}
    CORPOS_INESPERADOS.merge(CORPOS_NAO_OBJETO_JSON).each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, "editar #{nome}") { X.editar(id: "111", texto: "oi") }
      refute_kind_of TypeError, erro, "editar #{nome} nao pode estourar TypeError"
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "editar #{nome}"
      assert_includes erro.message, E::CUSTO_REPETIR_EDITAR, "editar #{nome}"
      assert_includes erro.message, "conferir o post 111", "editar #{nome}"
      refute_kind_of E::Restrito, erro, "editar #{nome} nao pode dizer so 'suprimido'"
      refute_match(%r{https://x\.com/i/status/}, erro.message, "editar #{nome} nao pode oferecer url de status")
      classes[nome] = erro.class
    end
    # O QUE O CASO PRECISA: uma classe so. As duas camadas (dentro do JSON e na raiz) podem ter
    # frase diferente, mas o desfecho e o mesmo `Incerto` — quem chamou trata igual.
    assert_equal [E::Incerto], classes.values.uniq, "corpo inesperado nao pode virar outra classe: #{classes.inspect}"
  end

  # O `dig_seguro` como a edicao usa: `result` escalar tem de virar `nil` (e nao `TypeError`),
  # e o `edit_control` de tipo errado tem de virar `nil` no estado — nunca um estado inventado.
  test "editar: dig_seguro no meio do caminho nao estoura, e o estado nao e inventado" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{"result":"oops"}}}}',
                                             headers: {}))
    erro = assert_raises(E::Incerto) { X.editar(id: "111", texto: "oi") }
    assert_includes erro.message, "rest_id=nil"
    assert_includes erro.message, "conferir o post 111"
    # `edit_control` de tipo inesperado no caminho feliz: os ids saem, o estado sai nil. O corpo
    # e montado a mao porque o `resposta_edicao` sempre poe o `edit_control` DEPOIS do `extra`
    # — o que nao deixa substituir o campo por um valor de tipo errado.
    corpo = JSON.generate("data" => { "create_tweet" => { "tweet_results" => { "result" => {
      "rest_id" => "2104299999999999999", "edit_control" => "oops"
    } } } })
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
    saida = X.editar(id: "111", texto: "oi")
    assert_equal "2104299999999999999", saida["id"]
    assert_equal({ "versoes" => nil, "edicoes_restantes" => nil, "editavel_ate_ms" => nil },
                 saida.slice("versoes", "edicoes_restantes", "editavel_ate_ms"))
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
