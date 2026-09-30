# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/youtube_escrita"

class Fetcher::Channels::YoutubeEscritaTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body, :headers, keyword_init: true)
  Y = Fetcher::Channels::YoutubeEscrita
  ID = "ZELPNFXJ4_o"

  def fixture(nome) = File.read(Rails.root.join("test/fixtures/x/#{nome}"))
  def resposta(status, corpo) = Resp.new(status: status, body: corpo, headers: {})

  def jar(*nomes)
    nomes.map { |n| { "name" => n, "value" => "valor-falso-#{n}-123" } }
  end

  setup do
    Fetcher::SessionCookies.stubs(:for).with("youtube.com")
                           .returns([jar("SID", "LOGIN_INFO", "SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"), :jar])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
  end

  # yt_like_ok.json: captura REAL de 2026-09-29 (conta descartável, podada de ids de rastreio e da conta).
  test "curtir manda POST em like/like com videoId e SAPISIDHASH e devolve o id" do
    Fetcher::SafeHttpClient.expects(:post).with do |url, json:, headers:|
      h = headers.transform_keys { |k| k.to_s.downcase }
      url == "https://www.youtube.com/youtubei/v1/like/like?prettyPrint=false" &&
        json["target"] == { "videoId" => ID } && json["context"]["client"]["clientName"] == "WEB" &&
        json["context"]["client"]["clientVersion"].to_s.match?(/\A\d+\.\d{8}\.\d+\.\d+\z/) &&
        h["authorization"].start_with?("SAPISIDHASH ") &&
        h["authorization"].match?(/\ASAPISIDHASH \d+_[0-9a-f]{40} SAPISID1PHASH \d+_[0-9a-f]{40} SAPISID3PHASH \d+_[0-9a-f]{40}\z/) &&
        h["x-origin"] == "https://www.youtube.com" && h["origin"] == "https://www.youtube.com" &&
        h["x-goog-authuser"] == "0" &&
        h["cookie"].include?("SAPISID=valor-falso-SAPISID-123") && h["cookie"].include?("LOGIN_INFO=")
    end.returns(resposta(200, fixture("yt_like_ok.json")))
    assert_equal({ "id" => ID }, Y.curtir(id: ID))
  end

  test "hash da autorizacao e sha1 de 'ts SAPISID origem'" do
    Time.stubs(:now).returns(Time.at(1_790_710_202))
    esperado = Digest::SHA1.hexdigest("1790710202 valor-falso-SAPISID-123 https://www.youtube.com")
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      headers.transform_keys { |k| k.to_s.downcase }["authorization"].start_with?("SAPISIDHASH 1790710202_#{esperado} ")
    end.returns(resposta(200, fixture("yt_like_ok.json")))
    Y.curtir(id: ID)
  end

  test "sem SAPISID usa o __Secure-3PAPISID, como o yt-dlp" do
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([jar("SID", "__Secure-3PAPISID"), :jar])
    Fetcher::SafeHttpClient.expects(:post).with do |_url, json:, headers:|
      headers.transform_keys { |k| k.to_s.downcase }["authorization"].start_with?("SAPISIDHASH ")
    end.returns(resposta(200, fixture("yt_like_ok.json")))
    assert_equal({ "id" => ID }, Y.curtir(id: ID))
  end

  test "id invalido e ArgumentError antes de qualquer rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    Fetcher::SessionCookies.expects(:for).never
    assert_raises(ArgumentError) { Y.curtir(id: "0") }
  end

  test "sem SAPISID nem 3PAPISID na sessao e CookieJar::Expired sem POST" do
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([jar("SID", "LOGIN_INFO"), :jar])
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(Fetcher::CookieJar::Expired) { Y.curtir(id: ID) }
  end

  test "sem sessao nenhuma propaga CookieJar::Expired sem POST" do
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").raises(Fetcher::CookieJar::Expired.new("youtube.com"))
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(Fetcher::CookieJar::Expired) { Y.curtir(id: ID) }
  end

  test "401 e 403 viram CookieJar::Expired" do
    [401, 403].each do |status|
      Fetcher::SafeHttpClient.stubs(:post).returns(resposta(status, "{}"))
      assert_raises(Fetcher::CookieJar::Expired, "HTTP #{status}") { Y.curtir(id: ID) }
    end
  end

  test "outro 4xx vira Recusado" do
    Fetcher::SafeHttpClient.stubs(:post).returns(resposta(400, '{"error":{"code":400,"status":"INVALID_ARGUMENT"}}'))
    assert_raises(Y::Recusado) { Y.curtir(id: ID) }
  end

  test "429 vira RateLimited e 5xx vira ResponseError" do
    Fetcher::SafeHttpClient.stubs(:post).returns(resposta(429, ""))
    assert_raises(Y::RateLimited) { Y.curtir(id: ID) }
    Fetcher::SafeHttpClient.stubs(:post).returns(resposta(503, ""))
    assert_raises(Y::ResponseError) { Y.curtir(id: ID) }
  end

  test "2xx sem o marcador likeStatus LIKE vira ResponseError" do
    corpos = [
      "{}", "nao e json", "[]", '{"frameworkUpdates":"x"}',
      '{"frameworkUpdates":{"entityBatchUpdate":{"mutations":[]}}}',
      '{"frameworkUpdates":{"entityBatchUpdate":{"mutations":[{"payload":{"likeStatusEntity":{"likeStatus":"INDIFFERENT"}}}]}}}',
      '{"frameworkUpdates":{"entityBatchUpdate":{"mutations":"oops"}}}',
      '{"frameworkUpdates":{"entityBatchUpdate":{"mutations":[7,null]}}}'
    ]
    corpos.each do |corpo|
      Fetcher::SafeHttpClient.stubs(:post).returns(resposta(200, corpo))
      assert_raises(Y::ResponseError, corpo) { Y.curtir(id: ID) }
    end
  end

  test "LIKE de OUTRO video nao confirma este" do
    Fetcher::SafeHttpClient.stubs(:post).returns(resposta(200, fixture("yt_like_ok.json")))
    assert_raises(Y::ResponseError) { Y.curtir(id: "dQw4w9WgXcQ") }
  end

  test "falha de rede depois do envio vira Incerto" do
    erro = begin
      raise Net::ReadTimeout
    rescue Net::ReadTimeout
      begin
        raise Fetcher::SafeHttpClient::RequestTimeout, "timeout de rede"
      rescue Fetcher::SafeHttpClient::RequestTimeout => e
        e
      end
    end
    Fetcher::SafeHttpClient.stubs(:post).raises(erro)
    assert_raises(Y::Incerto) { Y.curtir(id: ID) }
  end

  test "corpo grande demais depois do envio vira Incerto" do
    Fetcher::SafeHttpClient.stubs(:post).raises(Fetcher::SafeHttpClient::BodyTooLarge, "grande")
    assert_raises(Y::Incerto) { Y.curtir(id: ID) }
  end

  test "falha de rede antes do envio vira ResponseError" do
    Fetcher::SafeHttpClient.stubs(:post).raises(Fetcher::SafeHttpClient::Error, "dns")
    assert_raises(Y::ResponseError) { Y.curtir(id: ID) }
  end

  test "trava local estourada vira RateLimited sem POST" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(Y::RateLimited) { Y.curtir(id: ID) }
  end

  test "as tres classes de erro sao do canal" do
    [Y::Recusado, Y::ResponseError, Y::Incerto].each { |k| assert_operator k, :<, Fetcher::Channels::Error }
  end
end
