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

  test "postar devolve id e url" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/CreateTweet" &&
        json["variables"]["tweet_text"] == "hello world" && json["queryId"] == "QID" &&
        json["features"].is_a?(Hash) && !json["variables"].key?("reply")
    end.returns(Resp.new(status: 200, body: fixture("create_tweet_ok.json"), headers: {}))
    assert_equal({ "id" => "1970000000000000001", "url" => "https://x.com/i/status/1970000000000000001" },
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

  test "seguir usa REST de formulario com txid do caminho REST" do
    Fetcher::Channels::XGraphql.expects(:build_headers)
      .with({}, {}, query_id: nil, operation: "friendships/create", method: "POST", path: "/i/api/1.1/friendships/create.json")
      .returns({})
    Fetcher::SafeHttpClient.expects(:post)
      .with("https://x.com/i/api/1.1/friendships/create.json", form: { "user_id" => "99" }, headers: {})
      .returns(Resp.new(status: 200, body: { "id_str" => "99" }.to_json, headers: {}))
    assert_equal({ "usuario_id" => "99" }, E.seguir(usuario_id: "99"))
  end
end
