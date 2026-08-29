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

    com_dir(info: info, subs: {}) do |dir, info|
      File.write(File.join(dir, "#{info['id']}.pt-BR.json3"), JSON.generate(EVENTS))
      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal false, result[:metadata]["auto_generated"]
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
    mortos = %w[GPS PREF VISITOR_INFO1_LIVE VISITOR_PRIVACY_METADATA SOCS
                __Secure-1PSIDTS __Secure-3PAPISID __Secure-3PSID
                __Secure-3PSIDCC __Secure-3PSIDTS __Secure-ROLLOUT_TOKEN __Secure-YNID]

    com_arquivo_de_cookie(mortos) do |path|
      assert_raises(Fetcher::CookieJar::Expired) do
        Fetcher::Channels::Youtube.send(:verify_session!, path)
      end
    end
  end

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
    Open3.stubs(:capture3).returns(["{}", "WARNING: no challenge solving failed", ok])
    Fetcher::CookieJar.stubs(:parse_netscape).returns([{ "name" => "SID" }])

    assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end
  end

  test "exit não-zero com sessão válida levanta YtdlpError, nunca NoTranscript" do
    ok = Struct.new(:success?, :exitstatus).new(false, 1)
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(["{}", "", ok])

    erro = assert_raises(Fetcher::Channels::Youtube::YtdlpError) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end
    assert_match(/exit 1/, erro.message)
    assert_kind_of Fetcher::Channels::Error, erro
    refute_kind_of Fetcher::Channels::Youtube::NoTranscript, erro
  end

  test "exit não-zero com stderr de sessão rejeitada preserva CookieJar::Expired" do
    ok = Struct.new(:success?, :exitstatus).new(false, 1)
    aviso = "ERROR: Sign in to confirm you are not a bot."
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])
    Open3.stubs(:capture3).returns(["{}", aviso, ok])

    erro = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end

    assert_equal "youtube.com", erro.domain
  end

  test "YtdlpError é subclasse de Channels::Error" do
    assert Fetcher::Channels::Youtube::YtdlpError < Fetcher::Channels::Error
  end

  # ── Busca (Youtube.search) ─────────────────────────────────────────────────
  def stubbed_search(cookies:, origem:)
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([cookies, origem])
    Fetcher::Channels::Youtube.stubs(:resultados).returns([])
  end

  test "search usa a sessao do SessionCookies (Chrome vivo antes do jar)" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    stubbed_search(cookies: [{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], origem: :browser)
    assert_equal [], Fetcher::Channels::Youtube.search(query: "ruby")
  end

  test "search barra rajada com rate limit antes de gastar processo" do
    Fetcher::HostRateLimiter.stubs(:exceeded?)
                            .with("youtube.com", max: Fetcher::Channels::Youtube::MAX_PER_WINDOW)
                            .returns(true)
    Fetcher::CookieJar.expects(:with_netscape_file).never

    erro = assert_raises(Fetcher::Channels::Youtube::RateLimited) do
      Fetcher::Channels::Youtube.search(query: "ruby")
    end

    assert_includes erro.message, "youtube.com"
    assert Fetcher::Channels::Youtube::RateLimited < Fetcher::Channels::Error
  end

  test "search sem sessao em fonte nenhuma levanta Expired nomeando o dominio" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::BrowserCookies.stubs(:for).returns([])
    Fetcher::CookieJar.stubs(:for).returns([])

    erro = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::Youtube.search(query: "ruby")
    end

    assert_equal "youtube.com", erro.domain
  end

  test "search com query vazia devolve lista vazia sem gastar nada" do
    Fetcher::HostRateLimiter.expects(:exceeded?).never
    Fetcher::CookieJar.expects(:with_netscape_file).never
    assert_equal [], Fetcher::Channels::Youtube.search(query: "   ")
  end

  # ── RED CASE 1: comando yt-dlp usa --sub-langs all em UMA unica execucao ────
  # Intercepta a construcao do comando e exige --sub-langs all. O codigo
  # anterior (2-pass com PREFERRED_LANGS) falha este teste — passa com
  # PREFERRED_LANGS.join(",") no primeiro download, nao "all".
  test "run usa --sub-langs all em unica execucao (sem 2-pass, sem PREFERRED_LANGS)" do
    captured_commands = []
    ok = Struct.new(:success?, :exitstatus).new(true, 0)
    Fetcher::SessionCookies.stubs(:for).returns([[{ "name" => "SID", "value" => "v", "domain" => ".youtube.com" }], :jar])

    # Abre a moqueira da cookie jar para que `with_netscape_file` execute e
    # `verify_session!` veja um cookie de sessao.
    Fetcher::CookieJar.stubs(:with_netscape_file).yields(Tempfile.create(["jar", ".txt"]).path).returns({"id" => "X", "title" => "T"})
    Fetcher::CookieJar.stubs(:refresh_from_netscape!)
    Fetcher::CookieJar.stubs(:parse_netscape).returns([{ "name" => "SID" }])

    Open3.expects(:capture3).with { |*args|
      captured_commands << args
      true
    }.returns(['{"id":"X","title":"T"}', "", ok])

    # capture3 mock devolve info sem legendas — build_from levanta NoTranscript
    # porque o dir esta vazio. O foco deste teste e o COMANDO emitido, nao o
    # resultado do parse.
    assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
      Fetcher::Channels::Youtube.call(url: "https://www.youtube.com/watch?v=X")
    end

    # Deve ter exatamente uma chamada a capture3 (unico download)
    assert_equal 1, captured_commands.length, "deve rodar yt-dlp uma unica vez, nao 2-pass"

    cmd = captured_commands.first
    assert_includes cmd, "--sub-langs"
    idx = cmd.index("--sub-langs")
    assert_equal "all", cmd[idx + 1], "deve passar --sub-langs all, nao PREFERRED_LANGS"

    # PREFERRED_LANGS nao deve existir mais
    refute Fetcher::Channels::Youtube.const_defined?(:PREFERRED_LANGS),
           "PREFERRED_LANGS deve ser removida completamente"
  end

  # ── RED CASE 2: idiomas arbitrarios sem hardcoded ────────────────────────────
  # ja.vtt, ar.vtt, zu.vtt, hi.vtt — cada um sozinho, cada um deve ser
  # reconhecido e servir. Sem nenhuma constante de preferencia.
  ["ja", "ar", "zu", "hi"].each do |lang|
    test "idioma arbitrario #{lang} funciona sem lista de preferencia" do
      Dir.mktmpdir("ytt-arbitrario") do |dir|
        info = INFO.merge("subtitles" => {}, "automatic_captions" => { lang => [{}] })
        write_vtt(dir, info, lang)

        result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

        assert_equal lang, result[:metadata]["lang"], "idioma #{lang} deve servir sem hardcoded"
        assert_operator result[:content].length, :>, 0
      end
    end
  end

  # ── RED CASE 3: duas legendas automaticas → escolha determinista ────────────
  # Ordenacao lexicografica: "es" < "pt" (e < p).
  test "duas legendas automaticas: escolha determinista por ordem lexica" do
    Dir.mktmpdir("ytt-deterministic") do |dir|
      info = INFO.merge("subtitles" => {}, "automatic_captions" => { "es" => [{}], "pt" => [{}] })
      write_vtt(dir, info, "es")
      write_vtt(dir, info, "pt")

      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "es", result[:metadata]["lang"], "lexicografico: es < pt"
      assert_operator result[:content].length, :>, 0
    end
  end

  # ── RED CASE 4: manual vence automatica ─────────────────────────────────────
  # Mesmo idioma em manual e automatico — manual deve ser escolhido.
  test "faixa manual vence automatica quando ambas existem" do
    Dir.mktmpdir("ytt-manual") do |dir|
      info = INFO.merge(
        "subtitles" => { "en" => [{}] },
        "automatic_captions" => { "en" => [{}], "es" => [{}] }
      )
      # escreve um arquivo .vtt em portugues (automatico) e outro em ingles (manual)
      write_vtt(dir, info, "es", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nauto es\n")
      write_vtt(dir, info, "en", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nmanual en\n")

      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "en", result[:metadata]["lang"], "manual deve vencer automatica"
      assert_includes result[:content], "manual en"
      assert_equal false, result[:metadata]["auto_generated"]
    end
  end

  # ── RED CASE 5: mesmo idioma em varios formatos → json3 > vtt > srt ─────────
  test "mesmo idioma em varios formatos prefere json3 > vtt > srt" do
    Dir.mktmpdir("ytt-formats") do |dir|
      info = INFO.merge(
        "subtitles" => { "en-GB" => [{}] },
        "automatic_captions" => {}
      )
      # json3, vtt, srt para o mesmo idioma en-GB
      File.write(File.join(dir, "#{info['id']}.en-GB.json3"), JSON.generate(EVENTS))
      write_vtt(dir, info, "en-GB", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nvtt content\n")
      File.write(File.join(dir, "#{info['id']}.en-GB.srt"), "1\n00:00:01,000 --> 00:00:02,000\nsrt content\n")

      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "en-GB", result[:metadata]["lang"]
      # json3 tem prioridade — conteudo vem do json3
      assert_equal "primeira linha\nsegunda linha", result[:content]
    end
  end

  # ── RED CASE 6: nenhuma faixa e faixa vazia → NoTranscript ───────────────────
  test "sem nenhuma faixa suportada levanta NoTranscript" do
    Dir.mktmpdir("ytt-vazio") do |dir|
      info = INFO.merge("subtitles" => {}, "automatic_captions" => {})
      File.write(File.join(dir, "lixo.txt"), "não é legenda")

      assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
        Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)
      end
    end
  end

  test "faixa parseavel mas vazia levanta NoTranscript" do
    Dir.mktmpdir("ytt-fazio") do |dir|
      info = INFO.merge("subtitles": {}, "automatic_captions": {})
      File.write(File.join(dir, "#{info['id']}.en.vtt"), "WEBVTT\n")

      assert_raises(Fetcher::Channels::Youtube::NoTranscript) do
        Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)
      end
    end
  end

  # ── RED CASE 7: video de controle real (en-GB) → lang en-GB, content > 1000 ───
  # VTT com conteudo extenido (simulando a fixture de controle lGtBPrSrnjY).
  LARGE_VTT = <<~VTT
    WEBVTT
    Kind: captions
    Language: en-GB
    NOTE
    This file was generated by YouTube.
    #{Array.new(60) { |i|
      "00:00:#{(i % 60).to_s.rjust(2, "0")}.000 --> 00:00:#{(i + 1 > 59 ? 59 : i + 1).to_s.rjust(2, "0")}.000\nLine number #{i} of the transcript content for testing purposes"
    }.join("\n")}

  VTT

  test "video de controle en-GB: lang en-GB e conteudo > 1000" do
    Dir.mktmpdir("ytt-control") do |dir|
      info = INFO.merge("subtitles" => {}, "automatic_captions" => { "en-GB" => [{}] })
      write_vtt(dir, info, "en-GB", LARGE_VTT)

      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "en-GB", result[:metadata]["lang"]
      assert_operator result[:content].length, :>, 1000, "conteudo deve ter mais de 1000 caracteres"
      assert_equal true, result[:metadata]["auto_generated"]
    end
  end

  # ── Parsers mantidos ────────────────────────────────────────────────────────

  VTT_FIXTURE = <<~VTT
    WEBVTT
    Kind: captions
    Language: en-GB
    NOTE
    This file was generated by YouTube.
    It contains auto-generated captions.
    00:00:00.500 --> 00:00:03.000
    <c>Welcome</c> to the show.

    00:00:03.500 --> 00:00:06.000
    We are <i>testing</i> the parser.
  VTT

  def write_vtt(dir, info, lang, body = VTT_FIXTURE)
    File.write(File.join(dir, "#{info['id']}.#{lang}.vtt"), body)
  end

  test "parse_vtt ignora NOTE/Kind/Language/STYLE e extrai so o texto das cues" do
    Dir.mktmpdir("ytt-parse") do |dir|
      info = INFO.merge("subtitles" => {})
      write_vtt(dir, info, "en-GB")

      events = Fetcher::Channels::Youtube.send(:events_from, File.join(dir, "#{info['id']}.en-GB.vtt"))
      textos = events.map { |e| e["text"] }

      assert_equal 2, events.size
      assert_includes textos[0], "Welcome"
      refute_includes textos[0], "<c>", "tags <c> devem ser strippadas"
      assert_includes textos[1], "testing"
    end
  end

  test "parse_srt extrai texto dos blocos" do
    srt_body = <<~SRT
      1
      00:00:00,500 --> 00:00:03,000
      Welcome to the show.

      2
      00:00:03,500 --> 00:00:06,000
      We are testing the parser.
    SRT
    Dir.mktmpdir("ytt-srt") do |dir|
      info = INFO.merge("subtitles" => {})
      File.write(File.join(dir, "#{info['id']}.en.srt"), srt_body)

      result = Fetcher::Channels::Youtube.build_from(dir: dir, url: "https://www.youtube.com/watch?v=X", info: info)

      assert_equal "en", result[:metadata]["lang"]
      assert_includes result[:content], "Welcome"
      assert_includes result[:content], "testing"
    end
  end
end
