# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_escrita"

class Fetcher::Channels::XEscritaTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  E = Fetcher::Channels::XEscrita

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))

  setup do
    cookies = [{ "name" => "auth_token", "value" => "segredo-auth-123" }, { "name" => "ct0", "value" => "csrf-ct0-456" }]
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns(cookies)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    fake = Class.new { def evidence_header(**) = "TXID" }.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake)
  end

  # create_tweet_ok.json: captura REAL de 2026-09-27 (@daemon403, podada; post apagado em seguida).
  test "postar devolve id e url" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/CreateTweet" &&
        json["variables"]["tweet_text"] == "hello world" && json["queryId"] == "QID" &&
        json["features"].is_a?(Hash) && !json["variables"].key?("reply")
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    assert_equal({ "id" => "2104291497428345283", "url" => "https://x.com/i/status/2104291497428345283" },
                 E.postar(texto: "hello world"))
  end

  test "responder manda in_reply_to_tweet_id" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      json["variables"]["reply"] == { "in_reply_to_tweet_id" => "42", "exclude_reply_user_ids" => [] }
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    E.postar(texto: "oi", em_resposta_a: "42")
  end

  test "erro 226 em HTTP 200 vira Restrito" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: fixture("create_tweet_226.json"), headers: {}))
    erro = assert_raises(E::Restrito) { E.postar(texto: "oi") }
    assert_match(/226/, erro.message)
  end

  test "duplicado 187 e longo 186 viram Recusado" do
    [187, 186].each do |codigo|
      corpo = { "errors" => [{ "message" => "x", "code" => codigo }] }.to_json
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 403, body: corpo, headers: {}))
      assert_raises(E::Recusado) { E.postar(texto: "oi") }
    end
  end

  test "429 vira RateLimitedRemote e 401 vira AuthError" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 429, body: "", headers: {}))
    assert_raises(E::RateLimitedRemote) { E.curtir(id: "1") }
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 401, body: "", headers: {}))
    assert_raises(E::AuthError) { E.curtir(id: "1") }
  end

  test "texto com valor de cookie e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { E.postar(texto: "olha isso segredo-auth-123") }
  end

  test "texto vazio ou acima de 25.000 e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { E.postar(texto: "   ") }
    erro = assert_raises(E::Recusado) { E.postar(texto: "a" * 25_001) }
    assert_match(/25001 caracteres/, erro.message)
    assert_match(/máx\. 25000/, erro.message)
  end

  # Borda de cima: a conta ficou Premium em 28/09/2026, então 25.000 é ACEITO (o X manda pro
  # GraphQL). Com o teto antigo de 280 este teste caía no Recusado local antes de qualquer rede.
  test "25.000 caracteres sao aceitos e chegam inteiros no tweet_text" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      json["variables"]["tweet_text"] == "a" * E::MAX_CHARS && json["variables"]["tweet_text"].length == 25_000
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    assert_equal "2104291497428345283", E.postar(texto: "a" * 25_000)["id"]
  end

  # O texto curto de sempre (280) continua entrando: subir o teto não pode ter quebrado o post comum.
  test "280 caracteres continuam aceitos" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      json["variables"]["tweet_text"] == "a" * 280
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    assert_equal "2104291497428345283", E.postar(texto: "a" * 280)["id"]
  end

  test "o teto e 25.000 e o post vai inteiro para o X" do
    assert_equal 25_000, E::MAX_CHARS
  end

  test "queryId nao descoberto da erro claro" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns(nil)
    Fetcher::SafeHttpClient.expects(:post).never
    erro = assert_raises(E::ResponseError) { E.repostar(id: "1") }
    assert_match(/CreateRetweet/, erro.message)
  end

  test "limite local estourado vira RateLimited" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)
    assert_raises(E::RateLimited) { E.apagar(id: "1") }
  end

  # Sem stub de build_headers nem do SafeHttpClient: o pedido real (WebMock) prova que o
  # content-type de formulário vence o application/json padrão do POST e que a sessão vai junto.
  test "seguir manda formulario com headers reais e confere o usuario na resposta" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    pedido = stub_request(:post, "https://x.com/i/api/1.1/friendships/create.json")
             .with(body: "user_id=1000000000000000001",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded", "X-Csrf-Token" => "csrf-ct0-456",
                              "X-Client-Transaction-Id" => "TXID" })
             .to_return(status: 200, body: fixture("friendships_create_ok.json"))
    assert_equal({ "usuario_id" => "1000000000000000001" }, E.seguir(usuario_id: "1000000000000000001"))
    assert_requested pedido
  end

  test "seguir com resposta de outro usuario vira ResponseError" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: fixture("friendships_create_ok.json"), headers: {}))
    assert_raises(E::ResponseError) { E.seguir(usuario_id: "99") }
  end

  # ── I1/I6: falha de rede ─────────────────────────────────────────────────────
  # Pedido real pelo SafeHttpClient (WebMock): a classificação usa a CAUSA que o cliente guarda.
  def rede_falha!(excecao, metodo: :post, url: "https://x.com/i/api/graphql/QID/FavoriteTweet")
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    stub_request(metodo, url).to_raise(excecao)
  end

  test "seguir com falha de rede antes do envio sai como ResponseError (nao escapa)" do
    Fetcher::SsrfGuard.stubs(:resolve!).raises(Fetcher::SsrfGuard::Blocked, "bloqueado")
    erro = assert_raises(E::ResponseError) { E.seguir(usuario_id: "99") }
    assert_match(/friendships\/create/, erro.message)
  end

  test "seguir com conexao resetada depois do envio vira Incerto" do
    rede_falha!(Errno::ECONNRESET, url: "https://x.com/i/api/1.1/friendships/create.json")
    assert_raises(E::Incerto) { E.seguir(usuario_id: "99") }
  end

  test "timeout de leitura numa escrita vira Incerto" do
    rede_falha!(Net::ReadTimeout)
    erro = assert_raises(E::Incerto) { E.curtir(id: "1") }
    assert_match(/FavoriteTweet/, erro.message)
  end

  # O teto total do SafeHttpClient (`Timeout.timeout` no `post`) vira RequestTimeout com causa
  # Timeout::Error: o pedido pode ter saído, então é Incerto.
  test "timeout total do cliente numa escrita vira Incerto" do
    erro = begin
      begin
        raise Timeout::Error, "execution expired"
      rescue Timeout::Error
        raise Fetcher::SafeHttpClient::RequestTimeout, "timeout de 25s"
      end
    rescue Fetcher::SafeHttpClient::RequestTimeout => e
      e
    end
    assert_kind_of Timeout::Error, erro.cause
    assert_raises(E::Incerto) { E.falha_de_rede!(erro, "CreateTweet") }
  end

  test "conexao resetada depois do envio vira Incerto" do
    rede_falha!(Errno::ECONNRESET)
    assert_raises(E::Incerto) { E.curtir(id: "1") }
  end

  test "falha antes do envio (connect) numa escrita e ResponseError, nao Incerto" do
    [Net::OpenTimeout, Errno::ECONNREFUSED].each do |excecao|
      rede_falha!(excecao)
      erro = assert_raises(E::ResponseError) { E.curtir(id: "1") }
      assert_match(/falha de rede em FavoriteTweet/, erro.message)
    end
  end

  # ── I2: resultado conferido ──────────────────────────────────────────────────
  # favorite_tweet_ok / create_retweet_ok / delete_tweet_ok: captura REAL de 2026-09-27 (@daemon403
  # curtiu e repostou o próprio post de teste, que foi apagado em seguida).
  test "curtir, repostar e apagar aceitam as respostas reais" do
    { curtir: "favorite_tweet_ok.json", repostar: "create_retweet_ok.json", apagar: "delete_tweet_ok.json" }.each do |acao, arq|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: fixture(arq), headers: {}))
      assert_equal({ "id" => "2104297723893571643" }, E.public_send(acao, id: "2104297723893571643"))
    end
  end

  # AJUSTE DE 28/09 (fechando o REPROVADO do editar, card t_dabd8768): o `repostar` saiu daqui.
  # Este teste cristalizava o comportamento VELHO — 2xx sem id utilizável como `ResponseError`,
  # que é "falhou, pode repetir". Repetir às cegas refazia o repost e a casa afirmava o que
  # não sabe: a 2xx prova que o pedido chegou ao X, e sem `retweet_results` não há como dizer que
  # o repost NÃO saiu. Agora é `Incerto` com o aviso de conferir (ver o bloco "RESPOSTA CHEGOU E NAO
  # CONFIRMA" mais abaixo, que cobre os três ramos do repostar). O `curtir` e o `apagar` seguem
  # `ResponseError`: os dois conferem o resultado SEMPRE (nenhum deles tem ramo de sucesso sem
  # confirmação), e não são o caminho que duplica post.
  test "curtir e apagar sem o campo de resultado continuam ResponseError" do
    { curtir: '{"data":{"favorite_tweet":"NotDone"}}', apagar: '{"data":{}}' }.each do |acao, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      assert_raises(E::ResponseError, "#{acao} aceitou #{corpo}") { E.public_send(acao, id: "1") }
    end
  end

  # ── RESPOSTA CHEGOU E NÃO CONFIRMA: pode ter saido, e repetir as cegas duplica ──
  #
  # O `Incerto` ja cobre a resposta que PERDEU depois do envio (`falha_de_rede!`). A 2xx sem id
  # utilizavel e o outro lado da MESMA duvida: o X respondeu 200, o pedido saiu, e o corpo nao diz
  # o que ele fez com ele. Reportar isso como "falhou" e afirmar o que nao se sabe, e repetir as
  # cegas cria OUTRA versao do post no X. Por isso os tres ramos (sem JSON, JSON sem `rest_id`,
  # `tweet_results` vazio) saem como `Incerto` com o mesmo aviso — e `Incerto` e nao um tipo novo
  # porque o porteiro JA conta `erro:Incerto` como "pode ter chegado ao X".
  test "2xx sem JSON no postar vira Incerto mandando conferir o post antes de repetir" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::Incerto) { E.postar(texto: "oi") }
    assert_match(/pode TER saido no X/, erro.message)
    assert_match(/confira o post ANTES de repetir/, erro.message)
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
  end

  test "2xx sem JSON no responder e a mesma duvida do postar" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::Incerto) { E.postar(texto: "oi", em_resposta_a: "42") }
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
  end

  # Os TRES ramos de uma vez, no postar e no responder: a classe e a frase tem de ser as mesmas,
  # senao o operador aprende que "vazio" e falha normal e "sem rest_id" e que precisa conferir.
  test "2xx sem id utilizavel e sempre o mesmo Incerto, com o mesmo aviso, no postar e no responder" do
    corpos = {
      "2xx sem JSON" => "<html>erro do proxy</html>",
      "JSON sem rest_id" => '{"data":{"create_tweet":{"tweet_results":{"result":{}}}}}',
      "tweet_results vazio" => '{"data":{"create_tweet":{"tweet_results":{}}}}'
    }
    corpos.each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      [{}, { em_resposta_a: "42" }].each do |extra|
        erro = assert_raises(E::Incerto, "postar #{nome} #{extra}") { E.postar(texto: "oi", **extra) }
        assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "postar #{nome} #{extra}"
        refute_kind_of E::Restrito, erro, "#{nome} #{extra} nao pode dizer so 'suprimido'"
      end
    end
  end

  test "no repostar os mesmos tres ramos tambem sao Incerto" do
    corpos = {
      "2xx sem JSON" => "<html>erro do proxy</html>",
      "sem rest_id do repost" => '{"data":{"create_retweet":{"retweet_results":{"result":{}}}}}',
      "retweet_results vazio" => '{"data":{"create_retweet":{"retweet_results":{}}}}'
    }
    corpos.each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, "repostar #{nome}") { E.repostar(id: "1") }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "repostar #{nome}"
      refute_kind_of E::Restrito, erro, "repostar #{nome}"
    end
  end

  # ── "ID UTILIZÁVEL": a definição POSITIVA (a forma do id), não uma lista de proibidos ────
  #
  # A r1 achou `tweet_results` vazio, a r2 achou `rest_id: ""` e a r3 (revisão `t_3581f942`)
  # achou OITO formas a mais que chegavam ao SUCESSO dos quatro fluxos. As três rodadas
  # quebraram a MESMA regra, e a causa está no COMO ela foi escrita: como lista do que é
  # PROIBIDO (ausente, `""`, `"   "`, zero). Lista do que é proibido nunca fecha — cada rodada
  # acha uma forma fora da lista. A inversão é a regra: o id do X é um SNOWFLAKE, ou seja,
  # SÓ DÍGITOS com valor MAIOR QUE ZERO, e nada mais entra.
  #
  # As 8 formas medidas pela r3 estão aqui nominalmente, mas elas não são casos especiais: são
  # consequência de não terem a forma do snowflake (sinal, ponto, letra, espaço, pontuação) ou de
  # não serem nem número (float, booleano).
  FORMAS_NAO_UTILIZAVEIS = {
    # ── as OITO medidas pela revisão da r3 ──
    "rest_id inteiro negativo" => { "rest_id" => -1 },
    "rest_id negativo em string" => { "rest_id" => "-1" },
    "rest_id decimal em string" => { "rest_id" => "1.5" },
    "rest_id com letra" => { "rest_id" => "123abc" },
    "rest_id com espaco no meio" => { "rest_id" => "12 34" },
    "rest_id com barra" => { "rest_id" => "123/evil" },
    "rest_id com query string" => { "rest_id" => "123?x=1" },
    "rest_id float" => { "rest_id" => 1.5 },
    # ── as QUATRO da r2, que continuam fora por ausentes/vazias/zero ──
    "rest_id ausente" => {},
    "rest_id vazio" => { "rest_id" => "" },
    "rest_id so espacos" => { "rest_id" => "   " },
    "rest_id inteiro 0" => { "rest_id" => 0 },
    # ── a borda escolhida: zero escrito, o sinal que some no `to_i`, espaço nas pontas,
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
  # A forma boa: o `rest_id` real que o X devolve (19 dígitos, string).
  ID_REAL = "2104291497428345283"

  def corpo_tweet(result)
    JSON.generate("data" => { "create_tweet" => { "tweet_results" => { "result" => result } } })
  end

  def corpo_repost(result)
    JSON.generate("data" => { "create_retweet" => { "retweet_results" => { "result" => result } } })
  end

  test "postar e responder: cada forma de id nao utilizavel e Incerto, e NUNCA sucesso" do
    FORMAS_NAO_UTILIZAVEIS.each do |nome, result|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo_tweet(result), headers: {}))
      [{}, { em_resposta_a: "42" }].each do |extra|
        erro = assert_raises(E::Incerto, "postar #{nome} #{extra}") { E.postar(texto: "oi", **extra) }
        assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "postar #{nome} #{extra}"
        assert_includes erro.message, E::CUSTO_REPETIR_POSTAR, "postar #{nome} #{extra}"
        refute_kind_of E::Restrito, erro, "postar #{nome} #{extra} nao pode dizer so 'suprimido'"
      end
    end
  end

  test "repostar: cada forma de id do repost nao utilizavel e Incerto, e NUNCA sucesso" do
    FORMAS_NAO_UTILIZAVEIS.each do |nome, result|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo_repost(result), headers: {}))
      erro = assert_raises(E::Incerto, "repostar #{nome}") { E.repostar(id: ID_REAL) }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "repostar #{nome}"
      refute_kind_of E::Restrito, erro, "repostar #{nome}"
    end
  end

  # O caminho feliz nao pode quebrar: id real continua SUCESSO, com a url montada. Sem isto os
  # testes acima passariam tambem com uma regra que recusasse tudo.
  test "com id real o postar e o repostar continuam sucesso" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_tweet("rest_id" => ID_REAL), headers: {}))
    assert_equal({ "id" => ID_REAL, "url" => "https://x.com/i/status/#{ID_REAL}" }, E.postar(texto: "oi"))

    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_repost("rest_id" => "2104297723893571643"),
                                             headers: {}))
    assert_equal({ "id" => ID_REAL }, E.repostar(id: ID_REAL))
  end

  # A DEFINICAO em si, escrita POSITIVA, para o proximo revisor nao ter que adivinhar o limite:
  # entra o que tem a FORMA do snowflake (so digitos, valor > 0) e sai tudo o mais. O teste
  # mede as duas pontas da definicao, e nao a lista do que e proibido.
  test "a definicao de id utilizavel aceita so a forma do snowflake: digitos com valor > 0" do
    FORMAS_NAO_UTILIZAVEIS.each do |nome, result|
      refute E.id_utilizavel?(result["rest_id"]), "#{nome} (#{result['rest_id'].inspect}) passou como utilizavel"
    end
    # o caminho feliz, nas duas formas em que o id real chega: a string que o X devolve e o inteiro
    assert E.id_utilizavel?(ID_REAL)
    assert E.id_utilizavel?(ID_REAL.to_i)
  end

  # A varredura e POSITIVA de verdade: nenhuma string com sinal, ponto, letra, espaco ou
  # pontuacao entra, e nenhum valor que nao seja inteiro > 0. Este e o teste que fecha a regra
  # para a proxima rodada sem precisar de exemplo novo.
  test "nenhuma forma que nao seja snowflake entra: nem sinal, ponto, letra, espaco ou pontuacao" do
    ["-1", "+1", "1.0", "1.5", ".5", "1e3", "0x10", "123abc", "abc123", "12 34", " 12", "12 ",
     "123/evil", "123?x=1", "123#f", "1,5", "123;", "123\n", "\t123", "1 OR 1=1"].each do |mau|
      refute E.id_utilizavel?(mau), "#{mau.inspect} passou como utilizavel"
    end
    [0, -1, 1.5, 0.0, 1e3, true, false, nil, [], {}, :"123", 2104291497428345283.0].each do |mau|
      refute E.id_utilizavel?(mau), "#{mau.inspect} passou como utilizavel"
    end
  end

  # O que o predicado FECHA e a forma; e essa forma e a que a url usa. Um id nao utilizavel nunca
  # pode virar `/i/status/<algo>`: essa url PARECE post, e e o que induz o operador a repetir.
  test "um id nao utilizavel nunca monta uma url de status que pareca post" do
    ["", "   ", "0", "1.5", "123abc", "12 34", "123/evil", "123?x=1"].each do |mau|
      refute E.id_utilizavel?(mau), "id #{mau.inspect} passou como utilizavel"
    end
  end

  # O aviso precisa carregar a FORMA que o X mandou: se a casa so diz "sem id", quem for conferir
  # o post no X nao tem como saber que o X devolveu `""` em vez de nao devolver nada.
  test "o Incerto de id nao utilizavel mostra a forma que o X devolveu" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_tweet("rest_id" => ""), headers: {}))
    erro = assert_raises(E::Incerto) { E.postar(texto: "oi") }
    assert_includes erro.message, 'rest_id=""'
  end

  # O conserto e na camada COMPARTILHADA, entao vale para toda escrita, nao so para o postar:
  # aqui o `curtir` e o exemplo, e o aviso e o mesmo.
  test "o aviso e o mesmo em qualquer escrita 2xx sem id, e nao so no postar" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: "", headers: {}))
    erro = assert_raises(E::Incerto) { E.curtir(id: "1") }
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
  end

  # A metrica do aviso: a resposta tem de mandar conferIR, e nao apenas avisar que houve duvida.
  test "o aviso de 2xx sem id diz o que fazer: conferir antes de repetir" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {}))
    erro = assert_raises(E::Incerto) { E.postar(texto: "oi") }
    refute_match(/tente de novo|repita agora|so tent(e|ar) de novo/i, erro.message)
    assert_includes erro.message, E::CUSTO_REPETIR_POSTAR
  end

  # LEITURA e o outro lado: `XConta` passa pelo mesmo `interpreta!` e nao tem post para conferir,
  # nem nada criado no X. A diferença e o `escrita:` que o chamador passa — sem ele, o 2xx sem
  # JSON continua `ResponseError` calado, como antes.
  test "2xx sem JSON de uma LEITURA continua ResponseError, sem aviso de conferir" do
    resposta = Resp.new(status: 200, body: "<html>erro do proxy</html>", headers: {})
    erro = assert_raises(E::ResponseError) { E.interpreta!(resposta, "UserByScreenName") }
    refute_kind_of E::Incerto, erro
    refute_includes erro.message, "confira o post"
  end

  # ── Minors 1-2: códigos ──────────────────────────────────────────────────────
  test "161 vira Restrito e 162/108/160/139/327/144 viram Recusado, tambem com 403 no follow" do
    corpo = ->(codigo) { { "errors" => [{ "message" => "x", "code" => codigo }] }.to_json }
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 403, body: corpo.call(161), headers: {}))
    assert_raises(E::Restrito) { E.seguir(usuario_id: "99") }
    [162, 108, 160].each do |codigo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 403, body: corpo.call(codigo), headers: {}))
      assert_raises(E::Recusado, "codigo #{codigo}") { E.seguir(usuario_id: "99") }
    end
    { 139 => :curtir, 327 => :repostar, 144 => :apagar }.each do |codigo, acao|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo.call(codigo), headers: {}))
      assert_raises(E::Recusado, "codigo #{codigo}") { E.public_send(acao, id: "1") }
    end
  end

  # ── I5: queryId velho ────────────────────────────────────────────────────────
  test "404 ou 422 redescobre o queryId uma vez e repete com o id novo" do
    [404, 422].each do |status|
      resolver = Fetcher::XQueryIdResolver.any_instance
      resolver.stubs(:resolve).with("FavoriteTweet").returns("VELHO")
      resolver.expects(:resolve).with("FavoriteTweet", force: true).returns("NOVO")
      ordem = sequence("queryId #{status}")
      Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/VELHO/FavoriteTweet" }
                             .in_sequence(ordem).returns(Resp.new(status: status, body: "", headers: {}))
      Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/NOVO/FavoriteTweet" }
                             .in_sequence(ordem)
                             .returns(Resp.new(status: 200, body: fixture("favorite_tweet_ok.json"), headers: {}))
      assert_equal({ "id" => "1" }, E.curtir(id: "1"))
    end
  end

  test "404 repetido ou id igual depois da redescoberta: uma tentativa so, ResponseError" do
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("DeleteTweet", force: true).returns("QID")
    Fetcher::SafeHttpClient.expects(:post).once.returns(Resp.new(status: 404, body: "", headers: {}))
    assert_raises(E::ResponseError) { E.apagar(id: "1") }
  end

  test "403 e 429 nao redescobrem nem repetem" do
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with(anything, force: true).never
    Fetcher::SafeHttpClient.expects(:post).once.returns(Resp.new(status: 403, body: "", headers: {}))
    assert_raises(E::AuthError) { E.curtir(id: "1") }
    Fetcher::SafeHttpClient.expects(:post).once.returns(Resp.new(status: 429, body: "", headers: {}))
    assert_raises(E::RateLimitedRemote) { E.curtir(id: "1") }
  end
end
