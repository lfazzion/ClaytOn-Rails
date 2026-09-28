# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_feed"

class Fetcher::Channels::XFeedTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  F = Fetcher::Channels::XFeed
  E = Fetcher::Channels::XEscrita

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))
  def ok(corpo) = Resp.new(status: 200, body: corpo, headers: {})

  setup do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns([{ "name" => "ct0", "value" => "c" }])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(Class.new { def evidence_header(**) = "T" }.new)
  end

  # Fixtures home_timeline.json e home_latest_timeline.json: captura REAL de 2026-09-28 (conta do
  # porteiro, só leitura), podadas: autores anonimizados (conta_a..), texto cortado em 40 caracteres,
  # cursores trocados por marcadores. Trazem promovido, módulo "Who to follow", conversa (post + resposta),
  # repost, texto longo (note_tweet) e cursores Top/Bottom.
  test "para_voce vai por POST em HomeTimeline com as variaveis do cliente web e ignora o promovido" do
    Fetcher::SafeHttpClient.expects(:get).never
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      v = json["variables"]
      url == "https://x.com/i/api/graphql/QID/HomeTimeline" && json["queryId"] == "QID" &&
        v == { "count" => 20, "includePromotedContent" => false, "latestControlAvailable" => true,
               "requestContext" => "launch", "withCommunity" => true } &&
        json["features"]["rweb_cashtags_enabled"] == false && headers.is_a?(Hash)
    end.returns(ok(fixture("home_timeline.json")))

    feed = F.ler(tipo: "para_voce")
    assert_equal %w[2104337822350221795 2104387164704588077 2104329978146115998], feed["posts"].map { |p| p["id"] }
    assert_equal "CURSOR_BOTTOM_REAL_PODADO", feed["proximo_cursor"]
    assert_equal({ "id" => "2104337822350221795", "autor" => "conta_a",
                   "texto" => "Ladies and gentlemen, agents and assista",
                   "criado_em" => "2026-09-27T22:30:08Z", "impressoes" => feed["posts"][0]["impressoes"],
                   "respostas" => 40, "curtidas" => 542, "reposts" => 50,
                   "url" => "https://x.com/conta_a/status/2104337822350221795",
                   "e_resposta" => false, "e_repost" => false, "repostado_por" => nil }, feed["posts"][0])
    assert_kind_of Integer, feed["posts"][0]["impressoes"]
  end

  test "texto longo vem do note_tweet, nao do full_text cortado" do
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(fixture("home_timeline.json")))
    post = F.ler(tipo: "para_voce")["posts"].find { |p| p["id"] == "2104329978146115998" }
    assert post["texto"].end_with?("(texto longo)"), post["texto"]
  end

  test "seguindo vai em HomeLatestTimeline; conversa entra inteira, repost vira o original marcado" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, **|
      url.end_with?("/QID/HomeLatestTimeline") &&
        json["variables"] == { "count" => 20, "includePromotedContent" => false, "latestControlAvailable" => true,
                               "requestContext" => "launch", "enableRanking" => false }
    end.returns(ok(fixture("home_latest_timeline.json")))

    feed = F.ler(tipo: "seguindo")
    posts = feed["posts"]
    refute_includes posts.map { |p| p["id"] }, "2103071524790165563" # promovido
    conversa = posts.select { |p| p["autor"] == "conta_g" }.map { |p| [p["id"], p["e_resposta"]] }
    assert_equal [["2104354839627026909", false], ["2104355556064444657", true],
                  ["2103922653585162248", false], ["2103939679397585115", true]], conversa

    repost = posts.find { |p| p["e_repost"] }
    assert_equal "conta_c", repost["repostado_por"]
    refute_equal "2104340411598995854", repost["id"] # o id é do original, para responder/curtir o post certo
    refute repost["texto"].start_with?("RT @"), repost["texto"]
    assert_equal "https://x.com/#{repost['autor']}/status/#{repost['id']}", repost["url"]
    assert_equal "CURSOR_BOTTOM_REAL_PODADO", feed["proximo_cursor"]
  end

  test "com cursor manda o cursor e nao manda requestContext; limite vira count e corta a saida" do
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, **|
      v = json["variables"]
      v["cursor"] == "C1" && !v.key?("requestContext") && v["count"] == 2
    end.returns(ok(fixture("home_timeline.json")))
    assert_equal 2, F.ler(tipo: "para_voce", cursor: "C1", limite: 2)["posts"].size
  end

  # Forma DERIVADA (página seguinte): o cursor de baixo vem num TimelineReplaceEntry, post com
  # visibilidade embrulhada, tombstone sem legacy e post sem views/métricas.
  PAGINA_2 = <<~JSON
    {"data":{"home":{"home_timeline_urt":{"instructions":[
     {"type":"TimelineAddEntries","entries":[
      {"entryId":"tweet-1","content":{"itemContent":{"tweet_results":{"result":{"__typename":"TweetWithVisibilityResults","tweet":{"rest_id":"1","core":{"user_results":{"result":{"core":{"screen_name":"alguem"}}}},"views":{"count":"77"},"legacy":{"full_text":"embrulhado","created_at":"Sun Sep 28 01:00:00 +0000 2026","reply_count":1,"favorite_count":2,"retweet_count":3}}}}}}},
      {"entryId":"tweet-2","content":{"itemContent":{"tweet_results":{"result":{"__typename":"TweetTombstone"}}}}},
      {"entryId":"tweet-3","content":{"itemContent":{"tweet_results":{"result":{"__typename":"Tweet","rest_id":"3","legacy":{"full_text":"sem nada"}}}}}}]},
     {"type":"TimelineReplaceEntry","entry_id_to_replace":"cursor-bottom-0","entry":{"entryId":"cursor-bottom-9","content":{"cursorType":"Bottom","value":"C2"}}}
    ]}}}}
  JSON

  test "pagina seguinte: cursor em TimelineReplaceEntry, visibilidade, tombstone e metricas ausentes como nil" do
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(PAGINA_2))
    feed = F.ler(tipo: "para_voce", cursor: "C1")
    assert_equal "C2", feed["proximo_cursor"]
    assert_equal %w[1 3], feed["posts"].map { |p| p["id"] }
    assert_equal 77, feed["posts"][0]["impressoes"]
    assert_equal "alguem", feed["posts"][0]["autor"]
    sem = feed["posts"][1]
    assert_nil sem["impressoes"]
    assert_nil sem["curtidas"]
    assert_nil sem["autor"]
    assert_nil sem["criado_em"]
    assert_equal "https://x.com/i/status/3", sem["url"]
  end

  test "promovido dentro de modulo tambem fica de fora" do
    corpo = { "data" => { "home" => { "home_timeline_urt" => { "instructions" => [{ "entries" => [
      { "entryId" => "home-conversation-5", "content" => { "items" => [
        { "item" => { "itemContent" => { "promotedMetadata" => {}, "tweet_results" => { "result" => {
          "rest_id" => "5", "legacy" => { "full_text" => "anuncio" } } } } } }
      ] } }
    ] }] } } } }.to_json
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(corpo))
    assert_equal({ "posts" => [], "proximo_cursor" => nil }, F.ler(tipo: "para_voce"))
  end

  test "tipo e limite invalidos sao ArgumentError, sem pedido ao X" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(ArgumentError) { F.ler(tipo: "tudo") }
    assert_raises(ArgumentError) { F.ler(tipo: "para_voce", limite: 0) }
    assert_raises(ArgumentError) { F.ler(tipo: "para_voce", limite: 41) }
  end

  test "trava local propria do feed" do
    Fetcher::HostRateLimiter.unstub(:exceeded?)
    Fetcher::HostRateLimiter.expects(:exceeded?).with("x.com", scope: "graphql_feed", max: 6, per_hour: 120).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::RateLimited) { F.ler(tipo: "seguindo") }
  end

  test "404 redescobre o queryId e repete uma vez" do
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).with("HomeTimeline").returns("VELHO")
    Fetcher::XQueryIdResolver.any_instance.expects(:resolve).with("HomeTimeline", force: true).returns("NOVO")
    ordem = sequence("queryId")
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/VELHO/") }.in_sequence(ordem)
                           .returns(Resp.new(status: 404, body: "", headers: {}))
    Fetcher::SafeHttpClient.expects(:post).with { |url, **| url.include?("/NOVO/") }.in_sequence(ordem)
                           .returns(ok(fixture("home_timeline.json")))
    assert_equal 3, F.ler(tipo: "para_voce")["posts"].size
  end

  test "resposta sem home_timeline_urt e falha de rede viram ResponseError; 429 vira RateLimitedRemote" do
    Fetcher::SafeHttpClient.stubs(:post).returns(ok('{"data":{}}'))
    assert_raises(E::ResponseError) { F.ler(tipo: "para_voce") }

    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 429, body: "", headers: {}))
    assert_raises(E::RateLimitedRemote) { F.ler(tipo: "para_voce") }

    Fetcher::SafeHttpClient.stubs(:post).raises(Fetcher::SafeHttpClient::Error, "caiu")
    assert_raises(E::ResponseError) { F.ler(tipo: "para_voce") }
  end
end
