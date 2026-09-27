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

  test "perfil le id e contadores" do
    Fetcher::SafeHttpClient.expects(:get).with { |url, headers:| url.include?("/QID/UserByScreenName?") }
                           .returns(Resp.new(status: 200, body: fixture("user_by_screen_name.json"), headers: {}))
    assert_equal({ "id" => "1800000000000000000", "usuario" => "daemon403", "seguidores" => 12,
                   "seguindo" => 30, "posts" => 7 }, C.perfil(usuario: "daemon403"))
  end

  test "posts desembrulha visibilidade, ignora terceiros e deixa views ausente como nil" do
    Fetcher::SafeHttpClient.stubs(:get).returns(Resp.new(status: 200, body: fixture("user_tweets.json"), headers: {}))
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
