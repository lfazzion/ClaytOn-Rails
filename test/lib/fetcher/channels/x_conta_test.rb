# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_conta"

class Fetcher::Channels::XContaTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  C = Fetcher::Channels::XConta

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))

  setup do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns([{ "name" => "ct0", "value" => "c" }])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(Class.new { def evidence_header(**) = "T" }.new)
  end

  # Fixtures user_by_screen_name.json e user_tweets_and_replies.json: captura REAL de 2026-09-27
  # (@daemon403, podada; o módulo "Who to follow" com usuário anonimizado). A timeline traz o post
  # de teste e o repost que a própria conta fez dele; os dois já foram apagados.
  test "perfil le id e contadores da forma real (relationship_counts/tweet_counts)" do
    Fetcher::SafeHttpClient.expects(:get).with { |url, headers:| url.include?("/QID/UserByScreenName?") }
                           .returns(Resp.new(status: 200, body: fixture("user_by_screen_name.json"), headers: {}))
    assert_equal({ "id" => "2084679070856384512", "usuario" => "daemon403", "seguidores" => 0,
                   "seguindo" => 12, "posts" => 0 }, C.perfil(usuario: "daemon403"))
  end

  test "perfil ainda le a forma antiga (legacy)" do
    corpo = { "data" => { "user" => { "result" => { "rest_id" => "9", "core" => { "screen_name" => "velho" },
                                                    "legacy" => { "followers_count" => 3, "friends_count" => 4,
                                                                  "statuses_count" => 5 } } } } }.to_json
    Fetcher::SafeHttpClient.stubs(:get).returns(Resp.new(status: 200, body: corpo, headers: {}))
    assert_equal({ "id" => "9", "usuario" => "velho", "seguidores" => 3, "seguindo" => 4, "posts" => 5 },
                 C.perfil(usuario: "velho"))
  end

  test "perfil sem relationship_counts, tweet_counts e legacy devolve contadores nil (nunca 0)" do
    corpo = { "data" => { "user" => { "result" => { "rest_id" => "9", "core" => { "screen_name" => "vazio" } } } } }.to_json
    Fetcher::SafeHttpClient.stubs(:get).returns(Resp.new(status: 200, body: corpo, headers: {}))
    assert_equal({ "id" => "9", "usuario" => "vazio", "seguidores" => nil, "seguindo" => nil, "posts" => nil },
                 C.perfil(usuario: "vazio"))
  end

  test "posts vai por POST em UserTweetsAndReplies e ignora o repost da propria conta (timeline real)" do
    Fetcher::SafeHttpClient.expects(:get).never
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      url == "https://x.com/i/api/graphql/QID/UserTweetsAndReplies" && json["queryId"] == "QID" &&
        json["variables"]["userId"] == "2084679070856384512" && json["variables"]["withCommunity"] == true &&
        json["features"].is_a?(Hash)
    end.returns(Resp.new(status: 200, body: fixture("user_tweets_and_replies.json"), headers: {}))
    posts = C.posts(usuario_id: "2084679070856384512", limite: 5)
    assert_equal([{ "id" => "2104297723893571643", "texto" => "hello, world. second boot.",
                    "criado_em" => "2026-09-27T19:50:47Z", "impressoes" => nil, "respostas" => 0,
                    "curtidas" => 1, "reposts" => 1 }], posts)
  end

  test "posts: 404 redescobre o queryId e repete uma vez" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with("UserTweetsAndReplies").returns("VELHO")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("UserTweetsAndReplies", force: true).returns("NOVO")
    ordem = sequence("queryId")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/VELHO/") }.in_sequence(ordem)
                           .returns(Resp.new(status: 404, body: "", headers: {}))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/NOVO/") }.in_sequence(ordem)
                           .returns(Resp.new(status: 200, body: fixture("user_tweets_and_replies.json"), headers: {}))
    assert_equal ["2104297723893571643"], C.posts(usuario_id: "2084679070856384512").map { |p| p["id"] }
  end

  # Forma DERIVADA (a conta não tinha resposta): conversa do perfil com o post de terceiro e a
  # resposta da conta, e um repost antigo marcado só por "RT @" no texto.
  TIMELINE_RESPOSTAS = <<~JSON
    {"data":{"user":{"result":{"timeline":{"timeline":{"instructions":[{"type":"TimelineAddEntries","entries":[
     {"entryId":"profile-conversation-1","content":{"items":[
       {"item":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"10","legacy":{"user_id_str":"555","full_text":"post de terceiro","created_at":"Sat Sep 27 10:00:00 +0000 2026","reply_count":1,"favorite_count":0,"retweet_count":0}}}}}},
       {"item":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"11","legacy":{"user_id_str":"1800000000000000000","in_reply_to_status_id_str":"10","full_text":"@terceiro minha resposta","created_at":"Sat Sep 27 11:00:00 +0000 2026","reply_count":0,"favorite_count":2,"retweet_count":0}}}}}}]}},
     {"entryId":"tweet-12","content":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"12","legacy":{"user_id_str":"1800000000000000000","full_text":"RT @terceiro: algo","created_at":"Sat Sep 27 12:00:00 +0000 2026","reply_count":0,"favorite_count":0,"retweet_count":7}}}}}}
    ]}]}}}}}}
  JSON

  test "posts inclui as respostas da conta e deixa de fora terceiros e reposts" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: TIMELINE_RESPOSTAS, headers: {}))
    posts = C.posts(usuario_id: "1800000000000000000")
    assert_equal ["11"], posts.map { |p| p["id"] }
    assert_equal 2, posts[0]["curtidas"]
  end

  # Forma DERIVADA (a conta tinha um post só): visibilidade embrulhada, post de terceiro, views com contagem.
  TIMELINE_DERIVADA = <<~JSON
    {"data":{"user":{"result":{"timeline":{"timeline":{"instructions":[{"type":"TimelineAddEntries","entries":[
     {"entryId":"tweet-1","content":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"1","views":{"count":"150"},"legacy":{"user_id_str":"1800000000000000000","full_text":"primeiro","created_at":"Sat Sep 27 12:00:00 +0000 2026","reply_count":3,"favorite_count":5,"retweet_count":1}}}}}},
     {"entryId":"tweet-2","content":{"itemContent":{"tweet_results":{"result":{"__typename":"TweetWithVisibilityResults","tweet":{"rest_id":"2","views":{"count":"40"},"legacy":{"user_id_str":"1800000000000000000","full_text":"segundo","created_at":"Sat Sep 27 13:00:00 +0000 2026","reply_count":0,"favorite_count":1,"retweet_count":0}}}}}}},
     {"entryId":"tweet-3","content":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"3","legacy":{"user_id_str":"555","full_text":"de outro","created_at":"Sat Sep 27 14:00:00 +0000 2026","reply_count":0,"favorite_count":0,"retweet_count":0}}}}}},
     {"entryId":"tweet-4","content":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"4","legacy":{"user_id_str":"1800000000000000000","full_text":"sem views","created_at":"Sat Sep 27 15:00:00 +0000 2026","reply_count":0,"favorite_count":0,"retweet_count":0}}}}}}
    ]}]}}}}}}
  JSON

  test "posts desembrulha visibilidade, ignora terceiros e deixa views ausente como nil" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 200, body: TIMELINE_DERIVADA, headers: {}))
    posts = C.posts(usuario_id: "1800000000000000000")
    assert_equal %w[1 2 4], posts.map { |p| p["id"] }
    assert_equal 150, posts[0]["impressoes"]
    assert_equal 3, posts[0]["respostas"]
    assert_nil posts[2]["impressoes"]
    assert_equal "2026-09-27T12:00:00Z", posts[0]["criado_em"]
  end

  test "usuario inexistente vira ResponseError" do
    Fetcher::SafeHttpClient.stubs(:get).returns(Resp.new(status: 200, body: '{"data":{}}', headers: {}))
    assert_raises(Fetcher::Channels::XEscrita::ResponseError) { C.perfil(usuario: "naoexiste") }
  end
end
