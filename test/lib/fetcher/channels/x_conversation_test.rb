# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_conversation"

# Stub local sem dependência externa — substitui OpenStruct (Ruby 4.0).
# Simula `SafeHttpClient::Response` (status, body, headers, success?).
StubResp = Struct.new(:status, :body, :headers, keyword_init: true) do
  def success?
    status.to_i.between?(200, 299)
  end
end

class Fetcher::Channels::XConversationTest < ActiveSupport::TestCase
  # FIXTURE REAL (HTTP 200 do TweetDetail, capturada 21/09 pelo maestro).
  # Morada versionada: test/fixtures/files/x/ (tmp/ é tmpfs no container de
  # teste — a fixture não sobrevive ali; ver docker/docker-compose.yml).
  FIXTURE = Rails.root.join("test/fixtures/files/x/tweet_detail.json")
  # rest_id medido no item raiz da fixture (TimelineTimelineItem).
  ROOT_ID = "2100705843453079718"

  # ------------------------------------------------------------------
  # Fixtures / contadores
  # ------------------------------------------------------------------

  def fixture_data
    @fixture_data ||= JSON.parse(File.read(FIXTURE))
  end

  # Conta os tweets da fixture SEM depender do parser — caminha os DOIS
  # caminhos reais (item raiz + módulo comentário). É o chão de verdade
  # contra o qual o parser é validado: se a fixture mudar, este contador
  # muda junto e o teste continua honrando o arquivo (não um número
  # enfiado).
  def all_tweet_results(data)
    data.dig("data", "threaded_conversation_with_injections_v2", "instructions")
        .select { |i| i.is_a?(Hash) && i["type"] == "TimelineAddEntries" }
        .flat_map { |i| Array(i["entries"]) }
        .each_with_object([]) do |entry, acc|
      c = entry.is_a?(Hash) ? entry["content"] : nil
      next unless c.is_a?(Hash)

      case c["entryType"]
      when "TimelineTimelineItem"
        r = c.dig("itemContent", "tweet_results", "result")
        acc << r if r.is_a?(Hash)
      when "TimelineTimelineModule"
        Array(c["items"]).each do |it|
          r = it.dig("item", "itemContent", "tweet_results", "result")
          acc << r if r.is_a?(Hash)
        end
      end
    end
  end

  def root_count(data)
    data.dig("data", "threaded_conversation_with_injections_v2", "instructions")
        .select { |i| i.is_a?(Hash) && i["type"] == "TimelineAddEntries" }
        .flat_map { |i| Array(i["entries"]) }
        .count do |entry|
      c = entry.is_a?(Hash) ? entry["content"] : nil
      c.is_a?(Hash) && c["entryType"] == "TimelineTimelineItem" &&
        c.dig("itemContent", "tweet_results", "result").is_a?(Hash)
    end
  end

  # Comentários = todos os tweets menos a(s) raiz(es).
  def comment_count(data)
    all_tweet_results(data).size - root_count(data)
  end

  def minimal_tweet(id, author, text)
    legacy = { "full_text" => text, "created_at" => "Thu Sep 17 21:57:56 +0000 2026",
               "favorite_count" => 1, "reply_count" => 0, "id_str" => id }
    user   = { "__typename" => "User", "core" => { "screen_name" => author } }
    { "rest_id" => id, "legacy" => legacy, "core" => { "user_results" => { "result" => user } } }
  end

  def root_entry(tweet)
    { "entryId" => "tweet-#{tweet["rest_id"]}",
      "content" => { "entryType" => "TimelineTimelineItem",
                     "itemContent" => { "tweet_results" => { "result" => tweet } } } }
  end

  def cursor_entry(value)
    { "entryId" => "cursor-bottom",
      "content" => { "entryType" => "TimelineTimelineCursor",
                     "cursorType" => "Bottom", "value" => value } }
  end

  def convo(entries)
    { "data" => { "threaded_conversation_with_injections_v2" =>
        { "instructions" => [ { "type" => "TimelineAddEntries", "entries" => entries } ] } } }
  end

  # Deps do transporte para os testes de `fetch` (sem tocar a API real):
  # sessão no jar + txid fake + gate de rate limit liberado.
  def stub_transport
    cookies = [
      { "name" => "auth_token", "value" => "test-auth" },
      { "name" => "ct0", "value" => "test-ct0" }
    ]
    # `gate!` faz falha rápida via `CookieJar.require!` (→ `valid?`);
    # sem stub, cairia no `BrowserSessionCookie` do DB e devolveria
    # `CookieJar::Expired`. Stub para que o teste avance ao transporte.
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    fake_txid = Class.new do
      def evidence_header(now_ms:, mask: nil, query_id: nil, path_suffix: nil, method: nil)
        "TXID(#{path_suffix})"
      end
    end.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake_txid)

    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
  end

  setup do
    # Remove o jitter real entre páginas (o que pesa na suíte).
    Kernel.stubs(:sleep)
  end

  # ------------------------------------------------------------------
  # Happy path contra a FIXTURE REAL
  # ------------------------------------------------------------------

  test "happy path: parser devolve root + N comentários contados do arquivo" do
    data = fixture_data
    expected_root = root_count(data)
    expected_comments = comment_count(data)

    conv = Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)

    assert_equal 1, expected_root, "fixture deve carregar exatamente 1 raiz"
    assert_equal expected_comments, conv["replies"].size,
      "comentários do parser deviam casar com a contagem direta do arquivo"
    refute conv["replies"].empty?, "conversa real não pode devolver [] calado"
  end

  test "raiz sai em 'root' e NÃO em 'replies'" do
    conv = Fetcher::Channels::XConversation.parse_conversation(fixture_data, focal_id: ROOT_ID)

    refute_nil conv["root"]
    assert_equal ROOT_ID, conv["root"]["id"]
    assert_equal "MonidHQ", conv["root"]["author"], "autor da raiz via fallback core"
    refute conv["replies"].any? { |r| r["id"] == ROOT_ID }, "raiz não pode aparecer em replies"
  end

  test "shape de cada comentário tem as chaves STRING do contrato" do
    conv = Fetcher::Channels::XConversation.parse_conversation(fixture_data, focal_id: ROOT_ID)

    conv["replies"].each do |r|
      assert_equal %w[author created_at id likes replies text].sort, r.keys.sort
      assert_kind_of String, r["id"]
      assert_kind_of Integer, r["likes"], "likes = legacy.favorite_count (int)"
      assert_kind_of Integer, r["replies"], "replies = legacy.reply_count (int)"
      refute_nil r["author"], "todo comentário da fixture resolve autor (fallback core)"
    end
  end

  # ------------------------------------------------------------------
  # Cursor Bottom de paginação
  # ------------------------------------------------------------------

  test "cursor Bottom presente na fixture real" do
    cursor = Fetcher::Channels::XConversation.extract_bottom_cursor(fixture_data)
    refute_nil cursor, "fixture real traz cursor Bottom de paginação"
    refute cursor.empty?
  end

  test "parser propaga o MESMO cursor Bottom que o extractor vê" do
    expected = Fetcher::Channels::XConversation.extract_bottom_cursor(fixture_data)
    conv = Fetcher::Channels::XConversation.parse_conversation(fixture_data, focal_id: ROOT_ID)
    assert_equal expected, conv["cursor"]
  end

  # ------------------------------------------------------------------
  # Tolerância: módulo sem tweet_results não explode
  # ------------------------------------------------------------------

  test "TimelineTimelineModule SEM tweet_results não explode: devolve o que tem" do
    data = JSON.parse(File.read(FIXTURE)) # cópia mutável
    entries = data.dig("data", "threaded_conversation_with_injections_v2", "instructions")
                 .find { |i| i["type"] == "TimelineAddEntries" }["entries"]

    mods = entries.select { |e| e.dig("content", "entryType") == "TimelineTimelineModule" }
    target = mods.find { |m| m.dig("content", "items").any? { |it| it.dig("item", "itemContent", "tweet_results") } }
    item = target["content"]["items"].find { |it| it.dig("item", "itemContent", "tweet_results") }
    item["item"].delete("itemContent") # quebra UM comentário

    expected = comment_count(data) # recounta APÓS a mutação (parser e contador veem o mesmo estado)
    conv = Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)
    assert_equal expected, conv["replies"].size, "deve cair 1 sem levantar"
    refute_nil conv["root"]
  end

  # ------------------------------------------------------------------
  # Vazio ≠ falha
  # ------------------------------------------------------------------

  test "post sem comentários: replies [] (vazio não é falha), root e cursor presentes" do
    data = convo([root_entry(minimal_tweet(ROOT_ID, "MonidHQ", "post raiz")), cursor_entry("CUR-X")])
    conv = Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)

    assert_equal [], conv["replies"]
    assert_equal ROOT_ID, conv["root"]["id"]
    assert_equal "CUR-X", conv["cursor"]
  end

  # ------------------------------------------------------------------
  # Falha de parse → ParseError (falhou, nunca [] calado)
  # ------------------------------------------------------------------

  test "focal ausente na conversa levanta ParseError" do
    data = convo([root_entry(minimal_tweet("111", "Alguem", "outro post"))])
    assert_raises(Fetcher::Channels::XConversation::ParseError) do
      Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)
    end
  end

  test "resposta sem o envelope da conversa levanta ParseError" do
    assert_raises(Fetcher::Channels::XConversation::ParseError) do
      Fetcher::Channels::XConversation.parse_conversation({ "data" => { "outro" => {} } }, focal_id: ROOT_ID)
    end
  end

  # ------------------------------------------------------------------
  # Envelope TweetWithVisibilityResults (tratar, não inventar)
  # ------------------------------------------------------------------

  test "desembrulha TweetWithVisibilityResults (result.tweet)" do
    inner = minimal_tweet(ROOT_ID, "MonidHQ", "post raiz")
    wrapper = { "rest_id" => ROOT_ID, "__typename" => "TweetWithVisibilityResults", "tweet" => inner }
    data = convo([root_entry_with_result(wrapper)])

    conv = Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)
    assert_equal "MonidHQ", conv["root"]["author"]
    assert_equal ROOT_ID, conv["root"]["id"]
  end

  def root_entry_with_result(result)
    { "entryId" => "tweet-#{ROOT_ID}",
      "content" => { "entryType" => "TimelineTimelineItem",
                     "itemContent" => { "tweet_results" => { "result" => result } } } }
  end

  test "autor via fallback core quando legacy.screen_name é nulo (como na fixture real)" do
    t = minimal_tweet(ROOT_ID, "fallbackuser", "texto")
    t.dig("core", "user_results", "result")["legacy"] = { "screen_name" => nil }
    data = convo([root_entry(t)])

    conv = Fetcher::Channels::XConversation.parse_conversation(data, focal_id: ROOT_ID)
    assert_equal "fallbackuser", conv["root"]["author"]
  end

  # ------------------------------------------------------------------
  # fetch (transporte stubado) — paginação + exceções tipadas
  # ------------------------------------------------------------------

  test "fetch (transporte stub) devolve root + comentários + cursor da página" do
    stub_transport
    resp = StubResp.new(status: 200, body: fixture_data.to_json, headers: {})
    Fetcher::SafeHttpClient.expects(:post).returns(resp)

    result = Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)

    assert_equal comment_count(fixture_data), result["replies"].size
    assert_equal ROOT_ID, result["root"]["id"]
    refute_nil result["cursor"], "cursor Bottom da página é propagado no contrato"
  end

  test "fetch para quando o cursor se repete (estopado anti-loop infinito)" do
    stub_transport
    # Duas páginas idênticas (mesmo cursor) → a segunda vê cursor == prev e quebra.
    resp = StubResp.new(status: 200, body: fixture_data.to_json, headers: {})
    Fetcher::SafeHttpClient.expects(:post).times(2).returns(resp, resp)

    result = Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: 100, max_pages: 3)
    # Dedicado: mesmo com a mesma página repetida, não repete comentários.
    assert_equal comment_count(fixture_data), result["replies"].size
    assert_equal result["replies"].uniq { |r| r["id"] }.size, result["replies"].size,
      "comentário duplicado não entra duas vezes"
  end

  test "HTTP 500 (stub) levanta ResponseError" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(StubResp.new(status: 500, body: "{}", headers: {}))

    assert_raises(Fetcher::Channels::XConversation::ResponseError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "HTTP 404 (stub) levanta NotFound" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(StubResp.new(status: 404, body: "{}", headers: {}))

    assert_raises(Fetcher::Channels::XConversation::NotFound) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "HTTP 429 (stub) levanta RateLimitedRemote" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(StubResp.new(status: 429, body: "{}", headers: {}))

    assert_raises(Fetcher::Channels::XConversation::RateLimitedRemote) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "HTTP 403 (stub) levanta AuthError" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(StubResp.new(status: 403, body: "{}", headers: {}))

    assert_raises(Fetcher::Channels::XConversation::AuthError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "tweet_id vazio levanta ArgumentError antes de tocar rede" do
    Fetcher::SafeHttpClient.expects(:post).never
    assert_raises(ArgumentError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: "   ")
    end
  end
end
