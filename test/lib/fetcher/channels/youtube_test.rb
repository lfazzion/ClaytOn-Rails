# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "tempfile"
require_relative "../../../../lib/fetcher/channels/youtube"

class Fetcher::Channels::YoutubeTest < ActiveSupport::TestCase
  EVENTS = {
    "events" => [
      { "segs" => [{ "utf8" => "primeira linha" }] },
      { "segs" => [{ "utf8" => "primeira linha" }] },
      { "segs" => [{ "utf8" => "segunda " }, { "utf8" => "linha" }] },
      { "segs" => [{ "utf8" => "\n" }] }
    ]
  }.freeze

  INFO = {
    "id" => "X", "title" => "Aula", "channel" => "Canal",
    "subtitles" => {}, "automatic_captions" => { "pt-BR" => [{}] }
  }.freeze

  # `call` roda o binário do yt-dlp; o que se testa aqui é o que o canal faz COM
  # o que ele escreveu — os arquivos de legenda no disco e o JSON compacto que
  # o `--print` devolve em stdout. Por isso `build_from` é público e o teste
  # entra por lá — sem binário, sem rede, sem cookie.
  def com_dir(info: INFO, subs: { "pt-BR" => EVENTS })
    Dir.mktmpdir("ytt") do |dir|
      subs.each { |lang, payload| File.write(File.join(dir, "#{info['id']}.#{lang}.json3"), JSON.generate(payload)) }
      yield dir, info
    end
  end

  test "monta a transcricao deduplicando linha repetida" do
    com_dir do |dir, info|
      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "Aula", result[:title]
      assert_equal "youtube", result[:metadata]["source"]
      assert_equal "transcript", result[:metadata]["kind"]
      assert_equal "pt-BR", result[:metadata]["lang"]
      assert_equal true, result[:metadata]["auto_generated"]
      assert_equal "X", result[:metadata]["video_id"]
      assert_equal "Canal", result[:metadata]["channel"]
      assert_equal "primeira linha\nsegunda linha", result[:content]
    end
  end

  test "legenda enviada pelo autor nao e marcada como automatica" do
    info = INFO.merge("subtitles" => { "pt-BR" => [{}] }, "automatic_captions" => {})

    com_dir(info: info) do |dir, info|
      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal false, result[:metadata]["auto_generated"]
    end
  end

  test "respeita a ordem de preferencia de idioma" do
    com_dir(subs: { "en" => EVENTS, "pt-BR" => EVENTS }) do |dir, info|
      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "pt-BR", result[:metadata]["lang"], "pt-BR vem antes de en em PREFERRED_LANGS"
    end
  end

  test "video sem faixa de legenda levanta NoTranscript" do
    com_dir(subs: {}) do |dir, info|
      assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
        Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)
      end
    end
  end

  test "faixa vazia levanta NoTranscript, nunca conteudo vazio" do
    com_dir(subs: { "pt-BR" => { "events" => [] } }) do |dir, info|
      assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
        Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)
      end
    end
  end

  test "NoTranscript e um erro de canal, que o ExtractService sabe pegar" do
    assert Fetcher::Channels::Youtube::NoTranscript < Fetcher::Channels::Error
  end

  test "reconhece as tres formas de URL de video" do
    %w[
      https://www.youtube.com/watch?v=abc123
      https://youtu.be/abc123
      https://www.youtube.com/shorts/abc123
    ].each do |url|
      assert_equal "abc123", Fetcher::Channels::Youtube.video_id_from(url), url
    end
  end

  test "URL de canal e de playlist nao sao video" do
    %w[
      https://www.youtube.com/@algum
      https://www.youtube.com/playlist?list=PL123
    ].each do |url|
      assert_nil Fetcher::Channels::Youtube.video_id_from(url), url
    end
  end

  test "URL que nao e de video devolve nil sem tocar no jar" do
    Fetcher::CookieJar.expects(:require!).never

    assert_nil Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/@algum")
  end

  test "sem sessao em nenhuma das duas fontes levanta Expired, sem gastar processo" do
    Fetcher::BrowserCookies.stubs(:for).returns([])
    Fetcher::CookieJar.stubs(:for).returns([])
    Open3.expects(:capture3).never

    erro = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end

    assert_equal "youtube.com", erro.domain
    assert_includes erro.message, "renovar"
  end
  # A regressao que isto guarda: sessao rejeitada saia como "video sem legenda".
  # O yt-dlp sai com status 0 e sem faixa nenhuma nos dois casos; o unico sinal
  # e o arquivo de cookie que ele reescreve.
  def com_arquivo_de_cookie(nomes)
    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      nomes.each { |n| f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, n, "v"].join("\t") }
      f.flush
      yield f.path
    end
  end

  test "sessao viva passa pela verificacao" do
    com_arquivo_de_cookie(%w[VISITOR_INFO1_LIVE SID PREF]) do |path|
      assert_nothing_raised { Fetcher::Channels::Youtube.send(:verify_session!, path) }
    end
  end

  test "sessao rejeitada vira Expired, nunca NoTranscript" do
    com_arquivo_de_cookie(%w[VISITOR_INFO1_LIVE VISITOR_PRIVACY_METADATA PREF GPS YSC]) do |path|
      erro = assert_raises(Fetcher::CookieJar::Expired) do
        Fetcher::Channels::Youtube.send(:verify_session!, path)
      end

      assert_equal "youtube.com", erro.domain
      assert_includes erro.message, "renovar"
    end
  end

  test "sessao invalidada de verdade: 3PSID sobrevive mas a sessao morreu" do
    # Conjunto EXATO que o YouTube devolveu em 04/08 ao rejeitar a sessao.
    # `__Secure-3PSID` continua la; se ele fosse sentinela, isto passaria batido.
    mortos = %w[GPS PREF VISITOR_INFO1_LIVE VISITOR_PRIVACY_METADATA SOCS
                __Secure-1PSIDTS __Secure-3PAPISID __Secure-3PSID
                __Secure-3PSIDCC __Secure-3PSIDTS __Secure-ROLLOUT_TOKEN __Secure-YNID]

    com_arquivo_de_cookie(mortos) do |path|
      assert_raises(Fetcher::CookieJar::Expired) do
        Fetcher::Channels::Youtube.send(:verify_session!, path)
      end
    end
  end

  # Medido em 05/08: com `--ignore-no-formats-error` o yt-dlp sai com status 0 e
  # reporta a sessao morta so como WARNING no stderr. A checagem tem que rodar
  # independente do status, senao a sessao rotacionada passa como "sem legenda".
  test "sessao rejeitada e detectada mesmo com exit 0" do
    aviso = "WARNING: [youtube] The provided YouTube account cookies are no longer valid. " \
            "They have likely been rotated in the browser as a security measure."
    ok = Struct.new(:success?).new(true)
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(['{"id":"X"}', aviso, ok])

    erro = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end

    assert_equal "youtube.com", erro.domain
  end

  test "bot-check tambem e sessao rejeitada, nao video sem legenda" do
    ok = Struct.new(:success?).new(true)
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(["{}", "ERROR: Sign in to confirm you are not a bot.", ok])

    assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end
  end

  test "stderr limpo nao e confundido com sessao rejeitada" do
    ok = Struct.new(:success?).new(true)
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(["{}", "WARNING: n challenge solving failed", ok])
    Fetcher::CookieJar.stubs(:parse_netscape).returns([{ "name" => "SID" }])

    # Sem faixa no diretorio temporario, o erro correto e NoTranscript.
    assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end
  end
end
