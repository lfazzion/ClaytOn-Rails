# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/youtube"

class Fetcher::Channels::YoutubeAgenteTest < ActiveSupport::TestCase
  Y = Fetcher::Channels::Youtube
  Status = Struct.new(:ok) { def success? = ok; def exitstatus = ok ? 0 : 1 }

  setup do
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "s", "domain" => ".youtube.com" }], :jar])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
  end

  test "video_id! aceita id cru e as tres formas de link" do
    assert_equal "dQw4w9WgXcQ", Y.video_id!("dQw4w9WgXcQ")
    assert_equal "dQw4w9WgXcQ", Y.video_id!("https://youtu.be/dQw4w9WgXcQ")
    assert_equal "dQw4w9WgXcQ", Y.video_id!("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30")
    assert_equal "dQw4w9WgXcQ", Y.video_id!("https://youtube.com/shorts/dQw4w9WgXcQ")
  end

  test "video_id! recusa lixo sem rede" do
    Open3.expects(:capture3).never
    %w[0 abc https://www.youtube.com/@canal https://example.com/watch?v=dQw4w9WgXcQ].each do |ruim|
      assert_raises(ArgumentError) { Y.video_id!(ruim) }
    end
  end

  test "feed le a pagina inicial (:ytrec) e devolve a forma do agente, duracao ausente vira nil" do
    saida = File.read(Rails.root.join("test/fixtures/x/yt_feed.txt"))
    Open3.expects(:capture3).with { |*cmd| cmd.include?(":ytrec") && cmd.include?("--flat-playlist") && cmd.include?("5") }
         .returns([saida, "", Status.new(true)])
    videos = Y.feed(limit: 5)
    assert_equal 5, videos.size
    primeiro = videos.first
    assert_equal %w[canal duracao id titulo url], primeiro.keys.sort
    assert_match(/\A[A-Za-z0-9_-]{11}\z/, primeiro["id"])
    assert_equal "https://www.youtube.com/watch?v=#{primeiro["id"]}", primeiro["url"]
    assert(videos.any? { |v| v["duracao"].nil? }, "duracao ausente precisa virar nil, nunca 0")
  end

  test "feed com sessao morta sai Expired, nunca lista vazia" do
    Open3.stubs(:capture3).returns(["", "ERROR: Sign in to confirm you're not a bot", Status.new(true)])
    assert_raises(Fetcher::CookieJar::Expired) { Y.feed(limit: 5) }
  end

  test "feed sem cookie de autenticacao sai Expired mesmo sem marca no stderr, nunca lista vazia" do
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "PREF", "value" => "x", "domain" => ".youtube.com" },
                                                  { "name" => "YSC", "value" => "y", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(["", "", Status.new(true)])
    assert_raises(Fetcher::CookieJar::Expired) { Y.feed(limit: 5) }
  end

  test "assistir marca como assistido e devolve a forma do agente" do
    Y.expects(:run).with { |url, _dir, _cookie, mark_watched:| url.include?("dQw4w9WgXcQ") && mark_watched == true }
     .returns({ "id" => "dQw4w9WgXcQ", "title" => "T", "channel" => "C" })
    Y.stubs(:verify_session!)
    Y.stubs(:build_from).returns({ url: "u", title: "T", content: "texto da legenda",
                                   metadata: { "lang" => "en", "auto_generated" => true, "video_id" => "dQw4w9WgXcQ",
                                               "channel" => "C" } })
    r = Y.assistir(url: "https://youtu.be/dQw4w9WgXcQ")
    assert_equal({ "id" => "dQw4w9WgXcQ", "titulo" => "T", "canal" => "C", "idioma" => "en",
                   "automatica" => true, "texto" => "texto da legenda" }, r)
  end
end
