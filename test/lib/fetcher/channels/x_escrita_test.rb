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

  test "texto vazio ou acima de 280 e recusado sem rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::Recusado) { E.postar(texto: "   ") }
    assert_raises(E::Recusado) { E.postar(texto: "a" * 281) }
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

  test "curtir, repostar e apagar sem o campo de resultado viram ResponseError" do
    { curtir: '{"data":{"favorite_tweet":"NotDone"}}', repostar: '{"data":{"create_retweet":{}}}',
      apagar: '{"data":{}}' }.each do |acao, corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: corpo, headers: {}))
      assert_raises(E::ResponseError, "#{acao} aceitou #{corpo}") { E.public_send(acao, id: "1") }
    end
  end

  test "resultado vazio no CreateTweet e no CreateRetweet vira Restrito (supressao)" do
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_tweet":{"tweet_results":{}}}}', headers: {}))
    assert_raises(E::Restrito) { E.postar(texto: "oi") }
    Fetcher::SafeHttpClient.stubs(:post)
                           .returns(Resp.new(status: 200, body: '{"data":{"create_retweet":{"retweet_results":{}}}}', headers: {}))
    assert_raises(E::Restrito) { E.repostar(id: "1") }
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
