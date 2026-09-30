# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_notificacoes"

class Fetcher::Channels::XNotificacoesTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  N = Fetcher::Channels::XNotificacoes
  E = Fetcher::Channels::XEscrita
  DONO = "9000000000000000001"

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))
  def ok(corpo) = Resp.new(status: 200, body: corpo, headers: {})

  setup do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns([{ "name" => "ct0", "value" => "c" }])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::XQueryIdResolver.any_instance.stubs(:resolve).returns("QID")
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(Class.new { def evidence_header(**) = "T" }.new)
  end

  # Tweets REAIS (fixture home_latest_timeline.json, conta_g: um post e uma resposta). O ENVELOPE em volta é
  # sintético: a conta do porteiro não tinha nenhuma menção quando o contrato foi medido (a fixture
  # notifications_mentions.json, real e podada, é a timeline vazia), então a forma das entradas com
  # posts (`content.itemContent.tweet_results`, a do TimelineTweet do cliente web) é a do resto da
  # família de timelines, não uma captura de menção.
  def tweets_reais
    coleta = []
    Fetcher::Channels::XConta.coleta(JSON.parse(fixture("home_latest_timeline.json")), coleta)
    coleta.select { |t| t.dig("core", "user_results", "result", "core", "screen_name") == "conta_g" }
  end

  def corpo_com(tweets, extras: [])
    entradas = tweets.each_with_index.map do |t, i|
      { "entryId" => "notification-#{i}", "content" => { "entryType" => "TimelineTimelineItem",
        "itemContent" => { "itemType" => "TimelineTweet", "tweet_results" => { "result" => t } } } }
    end
    entradas.unshift({ "entryId" => "cursor-top-1", "content" => { "cursorType" => "Top", "value" => "C" } })
    envelope(entradas + extras)
  end

  def envelope(entradas)
    JSON.generate("data" => { "viewer_v2" => { "user_results" => { "result" => {
      "rest_id" => DONO, "notification_timeline" => { "timeline" => { "instructions" => [
        { "type" => "TimelineClearCache" }, { "type" => "TimelineAddEntries", "entries" => entradas }
      ] } } } } } })
  end

  test "vai por POST em NotificationsTimeline com timeline_type Mentions e as flags do cliente web" do
    Fetcher::SafeHttpClient.expects(:get).never
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      v = json["variables"]
      url == "https://x.com/i/api/graphql/QID/NotificationsTimeline" && json["queryId"] == "QID" &&
        v == { "timeline_type" => "Mentions", "count" => 40 } &&
        json["features"]["rweb_cashtags_enabled"] == false && json["features"]["articles_preview_enabled"] == true &&
        headers.is_a?(Hash)
    end.returns(ok(fixture("notifications_mentions.json")))

    N.mencoes
  end

  test "usa a trava local propria, separada da de posts e do feed" do
    assert_equal({ scope: "graphql_notif", max: 4, per_hour: 30 }, N::BUDGET)
    Fetcher::HostRateLimiter.unstub(:exceeded?)
    Fetcher::HostRateLimiter.expects(:exceeded?).with("x.com", scope: "graphql_notif", max: 4, per_hour: 30).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(E::RateLimited) { N.mencoes }
  end

  test "timeline vazia reconhecida (fixture real medida) devolve []" do
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(fixture("notifications_mentions.json")))
    assert_equal [], N.mencoes
  end

  test "menção e resposta saem com as chaves do contrato; url, resposta e data no formato certo" do
    tweets = tweets_reais
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(corpo_com(tweets)))
    posts = N.mencoes
    assert_equal tweets.size, posts.size
    posts.each { |p| assert_equal %w[id autor texto criado_em url em_resposta_a e_resposta], p.keys }

    resposta = posts.find { |p| p["e_resposta"] }
    mencao = posts.find { |p| !p["e_resposta"] }
    refute_nil resposta
    refute_nil mencao
    assert_equal "conta_g", mencao["autor"]
    assert_equal "https://x.com/conta_g/status/#{mencao['id']}", mencao["url"]
    assert_nil mencao["em_resposta_a"]
    assert_equal false, mencao["e_resposta"]
    assert_match(/\A\d+\z/, resposta["em_resposta_a"])
    assert_equal true, resposta["e_resposta"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, mencao["criado_em"])
    assert_kind_of String, mencao["texto"]
  end

  test "posts da propria conta ficam de fora" do
    tweets = tweets_reais
    proprio = Marshal.load(Marshal.dump(tweets.first))
    proprio["legacy"]["user_id_str"] = DONO
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(corpo_com([proprio, *tweets.drop(1)])))
    ids = N.mencoes.map { |p| p["id"] }
    refute_includes ids, proprio["rest_id"]
    assert_equal tweets.drop(1).map { |t| t["rest_id"] }, ids
  end

  test "post repetido em duas entradas sai uma vez e o limite corta a saida" do
    tweets = tweets_reais
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(corpo_com(tweets + tweets)))
    assert_equal tweets.map { |t| t["rest_id"] }.uniq, N.mencoes.map { |p| p["id"] }
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(corpo_com(tweets)))
    assert_equal 1, N.mencoes(limite: 1).size
  end

  test "limite fora de 1..40 e recusado antes de qualquer rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    [0, 41, -1].each { |l| assert_raises(ArgumentError) { N.mencoes(limite: l) } }
  end

  test "forma nao reconhecida NUNCA vira lista vazia" do
    [{ "data" => {} }, { "data" => { "viewer_v2" => { "user_results" => { "result" => { "rest_id" => DONO } } } } },
     { "data" => { "viewer_v2" => { "user_results" => { "result" => { "rest_id" => DONO,
                   "notification_timeline" => { "timeline" => { "instructions" => "x" } } } } } } },
     { "data" => { "viewer_v2" => { "user_results" => { "result" => {
       "notification_timeline" => { "timeline" => { "instructions" => [] } } } } } } }].each do |corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(ok(JSON.generate(corpo)))
      assert_raises(E::ResponseError, corpo.inspect) { N.mencoes }
    end
  end

  test "entradas de notificação sem nenhum post reconhecível levantam ResponseError, não []" do
    entrada = { "entryId" => "notification-1", "content" => { "entryType" => "TimelineTimelineItem",
                "itemContent" => { "itemType" => "TimelineNotification", "template" => { "from_users" => [] } } } }
    Fetcher::SafeHttpClient.stubs(:post).returns(ok(envelope([entrada])))
    erro = assert_raises(E::ResponseError) { N.mencoes }
    assert_match(/sem posts reconhec/, erro.message)
  end

  test "sessão sem cookie levanta CookieJar::Expired antes da rede" do
    Fetcher::CookieJar.unstub(:valid?)
    Fetcher::CookieJar.stubs(:valid?).returns(false)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(Fetcher::CookieJar::Expired) { N.mencoes }
  end

  test "HTTP 401 e 429 e corpo que nao e JSON viram erros tipados" do
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 401, body: "", headers: {}))
    assert_raises(E::AuthError) { N.mencoes }
    Fetcher::SafeHttpClient.stubs(:post).returns(Resp.new(status: 429, body: "", headers: {}))
    assert_raises(E::RateLimitedRemote) { N.mencoes }
    Fetcher::SafeHttpClient.stubs(:post).returns(ok("<html>"))
    assert_raises(E::ResponseError) { N.mencoes }
  end

  test "falha de rede vira ResponseError" do
    Fetcher::SafeHttpClient.stubs(:post).raises(Fetcher::SafeHttpClient::Error, "boom")
    assert_raises(E::ResponseError) { N.mencoes }
  end
end
