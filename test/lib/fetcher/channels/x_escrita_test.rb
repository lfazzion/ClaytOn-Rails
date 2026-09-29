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

  # Borda de cima: a conta ficou Premium em 28/09/2026, então 25.000 é ACEITO. Acima de 280 o
  # caminho é o `CreateNoteTweet` (o `CreateTweet` recusa com 186 mesmo no Premium).
  test "25.000 caracteres sao aceitos e chegam inteiros no tweet_text, pelo CreateNoteTweet" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/CreateNoteTweet" &&
        json["variables"]["tweet_text"] == "a" * E::MAX_CHARS && json["variables"]["tweet_text"].length == 25_000
    end.returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    assert_equal REST_ID, E.postar(texto: "a" * 25_000)["id"]
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

  # ── Caminho longo: CreateNoteTweet (contrato lido no bundle do X, 29/09/2026) ──────────────
  REST_ID = "2104291497428345283"

  def corpo_nota(id, chave: "notetweet_create")
    JSON.generate("data" => { chave => { "tweet_results" => { "result" => { "rest_id" => id } } } })
  end

  test "281 caracteres vao por CreateNoteTweet, 280 continuam no CreateTweet" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/CreateNoteTweet" && json["queryId"] == "QID" &&
        json["variables"]["tweet_text"] == "a" * 281
    end.returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    assert_equal({ "id" => REST_ID, "url" => "https://x.com/i/status/#{REST_ID}" }, E.postar(texto: "a" * 281))

    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.end_with?("/CreateTweet") }
                           .returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    assert_equal REST_ID, E.postar(texto: "a" * 280)["id"]
  end

  test "o texto longo leva as mesmas variaveis e as 38 features do CreateTweet" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      v = json["variables"]
      v["dark_request"] == false && v["media"] == { "media_entities" => [], "possibly_sensitive" => false } &&
        v["semantic_annotation_ids"] == [] && !v.key?("reply") &&
        json["features"] == Fetcher::Channels::XConversation::FEATURES
    end.returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    E.postar(texto: "b" * 400)
  end

  test "responder longo vai por CreateNoteTweet com o reply nas variaveis" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url.end_with?("/CreateNoteTweet") &&
        json["variables"]["reply"] == { "in_reply_to_tweet_id" => "42", "exclude_reply_user_ids" => [] }
    end.returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    assert_equal REST_ID, E.postar(texto: "c" * 500, em_resposta_a: "42")["id"]
  end

  test "responder curto continua no CreateTweet" do
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.end_with?("/CreateTweet") }
                           .returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    E.postar(texto: "oi", em_resposta_a: "42")
  end

  # O X pesa CJK/emoji como 2: 141 caracteres de peso 2 = 282 > 280, e o CreateTweet daria 186.
  test "o peso do X decide: 141 caracteres de peso 2 ja sao caminho longo, 140 nao" do
    assert_equal 282, E.peso_do_texto("汉" * 141)
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.end_with?("/CreateNoteTweet") }
                           .returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    E.postar(texto: "汉" * 141)
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.end_with?("/CreateTweet") }
                           .returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    E.postar(texto: "汉" * 140)
  end

  test "recusa 186 no caminho longo sai legivel, diz que nao publicou nem truncou, e nao cai no curto" do
    corpo = { "errors" => [{ "message" => "Tweet needs to be a bit shorter.", "code" => 186 }] }.to_json
    Fetcher::SafeHttpClient.expects(:post).once.with { |url, **| url.end_with?("/CreateNoteTweet") }
                           .returns(Resp.new(status: 403, body: corpo, headers: {}))
    erro = assert_raises(E::Recusado) { E.postar(texto: "d" * 400) }
    assert_match(/CreateNoteTweet/, erro.message)
    assert_match(/400 caracteres/, erro.message)
    assert_match(/NÃO foi publicado nem truncado/, erro.message)
    assert_match(/186/, erro.message)
  end

  test "restricao no caminho longo continua Restrito, com o codigo" do
    corpo = { "errors" => [{ "message" => "x", "code" => 226 }] }.to_json
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
    assert_raises(E::Restrito) { E.postar(texto: "e" * 400) }
  end

  test "caminho longo: 2xx sem id utilizavel e Incerto com o aviso de conferir, postar e responder" do
    [corpo_nota(""), corpo_nota(nil), '{"data":{"notetweet_create":{"tweet_results":{}}}}',
     '{"data":{"notetweet_create":"oops"}}', "<html>proxy</html>", corpo_nota((2**64).to_s),
     corpo_nota(REST_ID, chave: "create_tweet")].each do |corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      [{}, { em_resposta_a: "42" }].each do |extra|
        erro = assert_raises(E::Incerto, corpo) { E.postar(texto: "f" * 400, **extra) }
        assert_includes erro.message, E::AVISO_PODE_TER_SAIDO
      end
    end
  end

  test "caminho longo: timeout de leitura depois do envio vira Incerto, nao ResponseError" do
    rede_falha!(Net::ReadTimeout, url: "https://x.com/i/api/graphql/QID/CreateNoteTweet")
    erro = assert_raises(E::Incerto) { E.postar(texto: "g" * 400) }
    assert_includes erro.message, "CreateNoteTweet"
  end

  test "caminho longo: queryId velho (422) redescobre CreateNoteTweet uma vez" do
    Fetcher::XQueryIdResolver.any_instance.unstub(:resolve)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with { |op, **| op == "CreateNoteTweet" }
                             .returns("VELHO").then.returns("NOVO")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/VELHO/CreateNoteTweet") }
                           .returns(Resp.new(status: 422, body: "", headers: {}))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/NOVO/CreateNoteTweet") }
                           .returns(Resp.new(status: 200, body: corpo_nota(REST_ID), headers: {}))
    assert_equal REST_ID, E.postar(texto: "h" * 400)["id"]
  end

  test "acima de 25.000 continua recusado sem rede, tambem pelo caminho longo" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { E.postar(texto: "i" * 25_001, em_resposta_a: "42") }
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
    # ── a NONA, medida pela r4: FORA da faixa de 64 bits sem sinal ──
    # A forma (só dígitos, > 0) estava certa e a FAIXA faltava: um snowflake é um inteiro de
    # 64 bits sem sinal, então 2^64 não é um id que o X emitiu. Saía como SUCESSO e montava
    # `/i/status/18446744073709551616` — url que PARECE post e induz a repetir.
    "rest_id inteiro 2^64" => { "rest_id" => 2**64 },
    "rest_id string 21 digitos" => { "rest_id" => "1#{'0' * 20}" },
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
  # ── A FAIXA, que é parte da definição do snowflake (achado 1 da r4) ──────────────
  # Um id do X é um INTEIRO DE 64 BITS SEM SINAL, MAIOR QUE ZERO: de 1 a 2^64 − 1. O valor
  # mais uma vez (`2^64`) não cabe em 64 bits sem sinal, então não é snowflake.
  TETO = (2**64) - 1
  ACIMA = 2**64

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

  # ── ACHADO 1 DA r4: A FAIXA DO SNOWFLAKE (64 bits sem sinal, > 0) ──────────────
  #
  # A r3 trocou a lista de proibidos pela forma POSITIVA (só dígitos, valor > 0), e isso
  # continua certo. O que faltava era a FAIXA, e a faixa é parte da definição do snowflake:
  # um id do X é um INTEIRO DE 64 BITS SEM SINAL, MAIOR QUE ZERO — de 1 a 2^64 − 1.
  #
  # A r4 mediu o buraco: `18446744073709551616` (2^64) era aceito como SUCESSO e os quatro
  # fluxos devolviam `url` de status com esse número dentro. O número tem a FORMA certa
  # (só dígitos, > 0) e ainda assim NÃO é um id que o X emitiu — forma não é o mesmo que faixa.
  #
  # Estes testes medem as DUAS pontas da faixa (o teto e o teto mais um), nos quatro fluxos, e
  # também o lado POSITIVO do teto: 2^64 − 1 é o MAIOR id válido, e se a regra o recusasse
  # estaríamos estreitando a definição em vez de fechá-la.
  test "a faixa do snowflake e de 1 a 2^64-1: o teto entra e o teto mais um nao" do
    assert E.id_utilizavel?(TETO), "2^64-1 tem de ser utilizavel (o MAIOR id valido)"
    assert E.id_utilizavel?(TETO.to_s), "2^64-1 em string tem de ser utilizavel"
    refute E.id_utilizavel?(ACIMA), "2^64 nao cabe em 64 bits sem sinal"
    refute E.id_utilizavel?(ACIMA.to_s), "2^64 em string nao cabe em 64 bits sem sinal"
    # string de 20 digitos no teto entra; a de 21 digitos (10^20) nao
    assert E.id_utilizavel?(TETO.to_s), "20 digitos no teto entra"
    refute E.id_utilizavel?("1#{'0' * 20}"), "21 digitos (10^20) esta acima de 2^64-1"
    # o menor id valido continua entrando: a faixa nao estreitou a base
    assert E.id_utilizavel?(1)
    assert E.id_utilizavel?("1")
  end

  test "postar e responder: id fora da faixa de 64 bits e Incerto, e nunca monta url de status" do
    [ACIMA, ACIMA.to_s, "1#{'0' * 20}"].each do |fora|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_tweet("rest_id" => fora), headers: {}))
      [{}, { em_resposta_a: "42" }].each do |extra|
        erro = assert_raises(E::Incerto, "postar #{fora.inspect} #{extra}") { E.postar(texto: "oi", **extra) }
        assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "postar #{fora.inspect} #{extra}"
        assert_includes erro.message, E::CUSTO_REPETIR_POSTAR, "postar #{fora.inspect} #{extra}"
        refute_match(%r{https://x\.com/i/status/}, erro.message,
                     "o aviso nao pode oferecer url de status para #{fora.inspect}")
      end
    end
  end

  test "postar e responder: id no teto (2^64-1) continua SUCESSO, com a url montada" do
    [TETO, TETO.to_s].each do |no_teto|
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_tweet("rest_id" => no_teto), headers: {}))
      assert_equal({ "id" => no_teto.to_s, "url" => "https://x.com/i/status/#{no_teto}" },
                   E.postar(texto: "oi"), "postar com id no teto #{no_teto.inspect}")
      Fetcher::SafeHttpClient.stubs(:post)
                             .returns(Resp.new(status: 200, body: corpo_tweet("rest_id" => no_teto), headers: {}))
      assert_equal no_teto.to_s, E.postar(texto: "oi", em_resposta_a: "42")["id"],
                   "responder com id no teto #{no_teto.inspect}"
    end
  end

  test "repostar: id fora da faixa e Incerto, e id no teto continua sucesso" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_repost("rest_id" => ACIMA), headers: {}))
    erro = assert_raises(E::Incerto) { E.repostar(id: ID_REAL) }
    assert_includes erro.message, E::AVISO_PODE_TER_SAIDO

    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: corpo_repost("rest_id" => TETO.to_s), headers: {}))
    assert_equal({ "id" => ID_REAL }, E.repostar(id: ID_REAL))
  end

  # ── ACHADO 2 DA r4: CORPO INESPERADO NO 2xx E INCERTO, NUNCA TypeError ────────
  #
  # A r4 mediu que uma resposta 2xx com `result` ESCALAR (`"oops"`) levantava `TypeError` e o
  # `TypeError` ESCAPAVA do canal — nos quatro fluxos. Isso é pior que a ambiguidade que o
  # `Incerto` representa: quem chamou não descobre se o post foi publicado. Exceção que escapa
  # do canal é sempre pior que "não sei": `Incerto` é a resposta certa, porque a 2xx prova que
  # o pedido chegou ao X e a casa não tem como dizer que a ação NÃO saiu.
  #
  # A causa é `Hash#dig`: ele NÃO devolve `nil` para corpo inesperado, levanta `TypeError` no
  # primeiro nível que não é hash. O conserto é o `dig_seguro`, e o teste abaixo percorre TODAS
  # as formas de corpo inesperado em TODOS os quatro fluxos.
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
    "raiz lista" => '[]',
    "raiz escalar" => '"oops"',
    "raiz null" => 'null',
    "sem data" => '{}',
    "create_tweet vazio" => '{"data":{"create_tweet":{}}}'
  }.freeze

  test "postar e responder: 2xx com corpo inesperado e Incerto nos DOIS, nunca TypeError" do
    CORPOS_INESPERADOS.each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      [{}, { em_resposta_a: "42" }].each do |extra|
        erro = assert_raises(E::Incerto, "postar #{nome} #{extra}") { E.postar(texto: "oi", **extra) }
        assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "postar #{nome} #{extra}"
        assert_includes erro.message, E::CUSTO_REPETIR_POSTAR, "postar #{nome} #{extra}"
        refute_kind_of E::Restrito, erro, "postar #{nome} #{extra} nao pode dizer so 'suprimido'"
      end
    end
  end

  test "repostar: 2xx com corpo inesperado e Incerto, nunca TypeError" do
    CORPOS_INESPERADOS.each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, "repostar #{nome}") { E.repostar(id: ID_REAL) }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO, "repostar #{nome}"
      refute_kind_of E::Restrito, erro, "repostar #{nome}"
    end
  end

  # O `curtir` e o `apagar` passam pelo MESMO `dig_seguro` da camada compartilhada, e nao pelo
  # `Hash#dig` (que estourava). Eles NAO tem ramo de sucesso sem confirmacao, entao continuam
  # `ResponseError` — o que muda e que a duvida no FORMATO do corpo vira o erro TIPADO do
  # canal, e nao uma `TypeError` que escapa e nao diz nada sobre o que o X fez.
  #
  # A classe depende de ONDE a duvida aparece, e as DUAS sao erros tipados do canal:
  #   - corpo que nem e objeto JSON na raiz (aqui `"[]"`, `'"oops"'`, `'null'`): o `interpreta!`
  #     levanta `Incerto` ANTES do fluxo ver o corpo, porque a 2xx prova que o pedido saiu;
  #   - corpo que E objeto JSON mas com a forma errada dentro: o `dig_seguro` devolve `nil`, e o
  #     `curtir`/`apagar` caem no `ResponseError` de "sem confirmacao".
  # O que o teste fecha e o que o achado 2 exige: NENHUM dos dois e `TypeError`, e todos sao
  # `E::Error` — nada escapa do canal.
  test "curtir e apagar com corpo inesperado nunca levantam TypeError: sempre erro tipado" do
    CORPOS_INESPERADOS.each do |nome, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Error, "curtir #{nome}") { E.curtir(id: ID_REAL) }
      assert_includes erro.message, "FavoriteTweet", "curtir #{nome}"
      refute_kind_of TypeError, erro, "curtir #{nome} nao pode estourar TypeError"

      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Error, "apagar #{nome}") { E.apagar(id: ID_REAL) }
      assert_includes erro.message, "DeleteTweet", "apagar #{nome}"
      refute_kind_of TypeError, erro, "apagar #{nome} nao pode estourar TypeError"
    end
  end

  # O `dig_seguro` em si: NENHUM caminho estoura, cada nivel do MEIO tem de ser hash, e o valor
  # FINAL sai como vier (sem conversao) — quem chama e que valida a forma dele. Este e o teste
  # que fecha a regra para a proxima rodada sem precisar de exemplo nomeado, mesma ideia do
  # teste da varredura ampla do predicado.
  test "o dig seguro nunca estoura: so o meio tem de ser hash, e o valor final sai como vier" do
    # raiz ausente, ou nao hash, no PRIMEIRO nivel: nil
    assert_nil E.dig_seguro(nil, "data", "create_tweet")
    assert_nil E.dig_seguro("texto", "data", "create_tweet")
    assert_nil E.dig_seguro([], "data", "create_tweet")
    assert_nil E.dig_seguro({}, "data", "create_tweet")
    # tipo errado no MEIO do caminho: nil, e nunca `TypeError` (que e o bug do `Hash#dig`)
    assert_nil E.dig_seguro({ "data" => [] }, "data", "create_tweet")
    assert_nil E.dig_seguro({ "data" => { "create_tweet" => [] } }, "data", "create_tweet", "tweet_results")
    assert_nil E.dig_seguro({ "data" => {} }, "data", "create_tweet", "tweet_results")
    # o valor FINAL sai como vier, sem conversao: quem chama e que valida a forma
    assert_equal "oops", E.dig_seguro({ "data" => { "create_tweet" => "oops" } }, "data", "create_tweet")
    assert_equal "oops", E.dig_seguro({ "data" => { "create_tweet" => { "tweet_results" => "oops" } } },
                                    "data", "create_tweet", "tweet_results")
    assert_equal [1], E.dig_seguro({ "a" => [1] }, "a")
    # e o caminho feliz nao pode quebrar
    assert_equal "1", E.dig_seguro({ "data" => { "create_tweet" => { "tweet_results" => { "result" => { "rest_id" => "1" } } } } },
                                  "data", "create_tweet", "tweet_results", "result", "rest_id")
  end

  # A leitura segue LEITURA: uma 2xx que nem e objeto JSON continua `ResponseError` calado, sem
  # o aviso de conferir (a LEITURA nao criou nada no X, entao nao ha o que conferir). A diferenca
  # da ESCRITA e o `escrita:`, nao o `dig`.
  test "2xx sem objeto JSON de uma LEITURA continua ResponseError, sem aviso de conferir" do
    ['[]', '"oops"', "null", "<html>erro do proxy</html>", ""].each do |corpo|
      resposta = Resp.new(status: 200, body: corpo, headers: {})
      erro = assert_raises(E::ResponseError, "leitura #{corpo.inspect}") do
        E.interpreta!(resposta, "UserByScreenName")
      end
      refute_kind_of E::Incerto, erro, "leitura #{corpo.inspect}"
      refute_includes erro.message, "confira o post", "leitura #{corpo.inspect}"
    end
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

  # ── DESFAZER: descurtir e deseguir ───────────────────────────────────────────
  #
  # Contrato lido no PRÓPRIO bundle do X em 29/09/2026 (só GET do HTML de home e dos bundles de
  # JS, pelo `XQueryIdResolver` que a casa já usa; NENHUMA escrita no X), porque nome de operação
  # e caminho de endpoint não se inventam. O que o bundle diz, medido:
  #
  #   - descurtir: mutation `UnfavoriteTweet` (chunk 137832, `queryId` `ZYKSe-w7KEslx3JhSIk5LA`,
  #     resolvido por NOME em runtime como as outras, com o 404/422 rediscovering), `variables`
  #     `{ "tweet_id" => <id> }` — as MESMAS do `FavoriteTweet`, no bundle `unlike(e,r){…t.graphQL
  #     (W(), { tweet_id: n, …})}` — e resposta `data.unfavorite_tweet == "Done"`, que é o que o
  #     PRÓPRIO cliente do X compara (`"Done"!==e?.unfavorite_tweet`, "GQL Favorites: Failed to
  #     unfavorite tweet"). Os `featureSwitches`/`fieldToggles` da operação são VAZIOS no bundle,
  #     então nada é enviado além das `variables`.
  #   - deseguir: REST `friendships/destroy` (`unfollow(r,i={}){…e.post("friendships/destroy",
  #     {…user_id:n,…},{},i)}`), que o client versiona em `/1.1/` e fecha com `.json` — a MESMA
  #     montagem do `friendships/create` que o `seguir` já usa, na MESMA família de endpoint.
  #
  # O que NÃO se sabe (e por isso o teste não afirma): se o X responde alguma coisa além do
  # `id_str` do usuário, e o texto exato das recusas específicas do desfazer. As recusas
  # testadas são as da TABELA que o canal já tem, com códigos que não contradizem o desfazer.
  UNFOLLOW_ID = "1000000000000000001"

  def corpo_desfazer(valor)
    JSON.generate("data" => { "unfavorite_tweet" => valor })
  end

  test "o canal expoe os dois desfazeres" do
    assert_respond_to E, :descurtir, "XEscrita precisa expor descurtir (desfazer da curtida)"
    assert_respond_to E, :deseguir, "XEscrita precisa expor deseguir (desfazer do follow)"
  end

  test "descurtir manda o UnfavoriteTweet com o tweet_id e aceita o Done" do
    assert_respond_to E, :descurtir
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/UnfavoriteTweet" &&
        json["variables"] == { "tweet_id" => ID_REAL } && json["queryId"] == "QID" &&
        !json.key?("features")
    end.returns(Resp.new(status: 200, body: corpo_desfazer("Done"), headers: {}))
    assert_equal({ "id" => ID_REAL }, E.descurtir(id: ID_REAL))
  end

  # Sem stub de build_headers nem do SafeHttpClient: o pedido real (WebMock) prova que o
  # content-type de formulário vence o application/json do POST e que a sessão vai junto —
  # é o mesmo caminho do `seguir`, e o endpoint é irmão dele.
  test "deseguir manda formulario no friendships/destroy.json e confere o usuario na resposta" do
    assert_respond_to E, :deseguir
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    pedido = stub_request(:post, "https://x.com/i/api/1.1/friendships/destroy.json")
             .with(body: "user_id=#{UNFOLLOW_ID}",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded", "X-Csrf-Token" => "csrf-ct0-456",
                              "X-Client-Transaction-Id" => "TXID" })
             .to_return(status: 200, body: fixture("friendships_destroy_ok.json"))
    assert_equal({ "usuario_id" => UNFOLLOW_ID }, E.deseguir(usuario_id: UNFOLLOW_ID))
    assert_requested pedido
  end

  test "deseguir com resposta de outro usuario nao sai como sucesso" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: fixture("friendships_destroy_ok.json"),
                                                         headers: {}))
    erro = assert_raises(E::Error) { E.deseguir(usuario_id: "99") }
    assert_match(/friendships\/destroy/, erro.message)
  end

  # 2xx SEM CONFIRMAÇÃO é a MESMA dúvida da falha de rede depois do envio: o pedido chegou ao X
  # e a resposta não diz o que ele fez. A regra da casa é Incerto + conferir antes de repetir
  # (e aqui repetir NÃO duplica nada: descurtir/deseguir duas vezes não muda o estado final).
  #
  # A asserção do aviso é a do AVISO DO DESFAZER (`AVISO_PODE_TER_SAIDO_DESFAZER`), e não a do
  # postar: `AVISO_PODE_TER_SAIDO` manda "confira o POST", e no `deseguir` não existe post para
  # conferir. Além disso o `Incerto` NÃO pode carregar `CUSTO_REPETIR_POSTAR` ("repetir as cegas
  # cria OUTRO post") — para o desfazer isso é mentira, e foi o que este teste pegou na primeira
  # rodada GREEN: o `interpreta!` levanta o aviso genérico, e sem a tradução no canal a casa
  # mandava conferir um post que nunca existiu.
  test "2xx sem confirmacao no descurtir e Incerto com o aviso de conferir" do
    [corpo_desfazer(nil), corpo_desfazer("NotDone"), '{"data":{}}', '{"data":{"unfavorite_tweet":"oops"}}',
     '{"data":"oops"}', "[]", "<html>erro do proxy</html>"].each do |corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, "descurtir #{corpo}") { E.descurtir(id: ID_REAL) }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO_DESFAZER, "descurtir #{corpo}"
      assert_includes erro.message, E::CUSTO_REPETIR_DESFAZER, "descurtir #{corpo}"
      refute_includes erro.message, E::CUSTO_REPETIR_POSTAR, "descurtir #{corpo}: nao crea post"
      refute_includes erro.message, "confira o post", "descurtir #{corpo}: nao ha post para conferir"
      refute_kind_of TypeError, erro, "descurtir #{corpo}"
    end
  end

  test "2xx sem confirmacao no deseguir e Incerto com o aviso de conferir" do
    ['{"id_str":null}', '{"id_str":"99"}', "{}", "[]", "<html>erro do proxy</html>", ""].each do |corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      erro = assert_raises(E::Incerto, "deseguir #{corpo}") { E.deseguir(usuario_id: UNFOLLOW_ID) }
      assert_includes erro.message, E::AVISO_PODE_TER_SAIDO_DESFAZER, "deseguir #{corpo}"
      assert_includes erro.message, E::CUSTO_REPETIR_DESFAZER, "deseguir #{corpo}"
      refute_includes erro.message, E::CUSTO_REPETIR_POSTAR, "deseguir #{corpo}: nao crea post"
      refute_includes erro.message, "confira o post", "deseguir #{corpo}: nao ha post para conferir"
      refute_kind_of TypeError, erro, "deseguir #{corpo}"
    end
  end

  # O id do X é um SNOWFLAKE (`id_utilizavel?`, a definição única da casa) e aqui ele é ENTRADA:
  # sai nas `variables` do GraphQL ou no formulário do REST. Fora da definição é recusado LOCAL,
  # antes da rede — e nunca `Incerto`, porque nada saiu e a casa sabe que o X não fez nada.
  test "id fora da definicao de snowflake e recusado sem rede, no descurtir e no deseguir" do
    ids = FORMAS_NAO_UTILIZAVEIS.values.map { |h| h["rest_id"] } + [nil, "", "   ", "abc", 2**64]
    ids.uniq.each do |mau|
      Fetcher::SafeHttpClient.expects(:post).never
      erro = assert_raises(E::Recusado, "descurtir #{mau.inspect}") { E.descurtir(id: mau) }
      assert_match(/id invalido/, erro.message)
      Fetcher::SafeHttpClient.expects(:post).never
      erro = assert_raises(E::Recusado, "deseguir #{mau.inspect}") { E.deseguir(usuario_id: mau) }
      assert_match(/id invalido/, erro.message)
    end
  end

  # Sem isto o teste acima passaria com uma regra que recusa TUDO: o caminho feliz continua
  # (“id utilizável não é o mesmo que nenhum id serve”).
  test "o caminho feliz do desfazer continua: id real e id no teto saem como sucesso" do
    [ID_REAL, TETO.to_s, ID_REAL.to_i].each do |bom|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo_desfazer("Done"), headers: {}))
      assert_equal({ "id" => bom.to_s }, E.descurtir(id: bom), "descurtir #{bom.inspect}")
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: fixture("friendships_destroy_ok.json"),
                                                            headers: {}))
      assert_equal({ "usuario_id" => UNFOLLOW_ID }, E.deseguir(usuario_id: UNFOLLOW_ID), "deseguir #{bom.inspect}")
    end
  end

  # A recusa do X continua passando pela TABELA DO CANAL (mesma do postar/seguir), com códigos que
  # não contradizem o desfazer: 226 é restrição da conta; 144 é “post não existe” e 108 é “usuário
  # não existe”. O que o teste afirma é o roteamento, não o significado do X para o desfazer.
  test "recusa e restricao do X no desfazer usam a mesma tabela do canal" do
    corpo = ->(codigo) { { "errors" => [{ "message" => "x", "code" => codigo }] }.to_json }
    { 226 => E::Restrito, 144 => E::Recusado }.each do |codigo, classe|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo.call(codigo), headers: {}))
      assert_raises(classe, "descurtir #{codigo}") { E.descurtir(id: ID_REAL) }
    end
    { 161 => E::Restrito, 108 => E::Recusado, 162 => E::Recusado }.each do |codigo, classe|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 403, body: corpo.call(codigo), headers: {}))
      assert_raises(classe, "deseguir #{codigo}") { E.deseguir(usuario_id: UNFOLLOW_ID) }
    end
  end

  # As guardas de rede são as do arquivo: falha DEPOIS do envio é Incerto, falha ANTES é
  # ResponseError, e nenhuma das duas escapa do canal.
  test "falha depois do envio no desfazer e Incerto, e antes do envio e ResponseError" do
    rede_falha!(Errno::ECONNRESET, url: "https://x.com/i/api/graphql/QID/UnfavoriteTweet")
    assert_raises(E::Incerto) { E.descurtir(id: ID_REAL) }
    rede_falha!(Net::OpenTimeout, url: "https://x.com/i/api/graphql/QID/UnfavoriteTweet")
    erro = assert_raises(E::ResponseError) { E.descurtir(id: ID_REAL) }
    assert_match(/falha de rede em UnfavoriteTweet/, erro.message)

    Fetcher::SsrfGuard.unstub(:resolve_all)
    Fetcher::SsrfGuard.stubs(:resolve!).raises(Fetcher::SsrfGuard::Blocked, "bloqueado")
    erro = assert_raises(E::ResponseError) { E.deseguir(usuario_id: UNFOLLOW_ID) }
    assert_match(/friendships\/destroy/, erro.message)
  end

  test "deseguir com conexao resetada depois do envio vira Incerto" do
    rede_falha!(Errno::ECONNRESET, url: "https://x.com/i/api/1.1/friendships/destroy.json")
    assert_raises(E::Incerto) { E.deseguir(usuario_id: UNFOLLOW_ID) }
  end

  # A trava local vale para os dois desfazeres: o deseguir tem `gate!` próprio (caminho REST) e o
  # descurtir herda o do `graphql!`.
  test "a trava local barra os dois desfazeres antes da rede" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::RateLimited) { E.descurtir(id: ID_REAL) }
    assert_raises(E::RateLimited) { E.deseguir(usuario_id: UNFOLLOW_ID) }
  end

  # O queryId velho se refaz como nas outras mutações: 404/422 = id velho, redescoberta UMA vez.
  test "queryId velho do UnfavoriteTweet redescobre uma vez e repete com o id novo" do
    resolver = Fetcher::XQueryIdResolver.any_instance
    resolver.stubs(:resolve).with("UnfavoriteTweet").returns("VELHO")
    resolver.expects(:resolve).with("UnfavoriteTweet", force: true).returns("NOVO")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/VELHO/UnfavoriteTweet" }
                           .returns(Resp.new(status: 422, body: "", headers: {}))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url == "https://x.com/i/api/graphql/NOVO/UnfavoriteTweet" }
                           .returns(Resp.new(status: 200, body: corpo_desfazer("Done"), headers: {}))
    assert_equal({ "id" => ID_REAL }, E.descurtir(id: ID_REAL))
  end
end
