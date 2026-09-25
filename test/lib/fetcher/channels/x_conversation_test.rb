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

  # Comentários orgânicos = todos os tweets menos a(s) raiz(es) e anúncios.
  def comment_count(data)
    all_tweet_results(data).size - root_count(data) - promoted_count(data)
  end

  def promoted_count(data)
    data.dig("data", "threaded_conversation_with_injections_v2", "instructions")
        .select { |i| i.is_a?(Hash) && i["type"] == "TimelineAddEntries" }
        .flat_map { |i| Array(i["entries"]) }
        .sum do |entry|
      c = entry.is_a?(Hash) ? entry["content"] : nil
      next 0 unless c.is_a?(Hash) && c["entryType"] == "TimelineTimelineModule"

      Array(c["items"]).count do |item|
        item.is_a?(Hash) && item.dig("item", "itemContent", "promotedMetadata")
      end
    end
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
  # `exceeded:` devolve `HostRateLimiter.exceeded?` como o teste quiser
  # (padrão: livre; `true` exercita o freio local).
  def stub_transport(exceeded: false)
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

    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(exceeded)
  end

  setup do
    # Remove o jitter real entre páginas (o que pesa na suíte).
    Kernel.stubs(:sleep)
    # O freio remoto do 429 é estado de módulo (`@remote_blocked`); isola
    # cada teste para um 429 num teste não travar o próximo.
    Fetcher::Channels::XConversation.clear_remote_state!
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
    # Verdade medida na fixture real (21/09, HTTP 200): 30 entradas no
    # envelope, das quais uma é promovida; o contrato orgânico são 29.
    assert_equal 29, conv["replies"].size, "a fixture real mede 29 comentários orgânicos"
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

  test "promotedMetadata no itemContent exclui o anúncio e preserva comentários reais" do
    conv = Fetcher::Channels::XConversation.parse_conversation(fixture_data, focal_id: ROOT_ID)
    entries = fixture_data.dig("data", "threaded_conversation_with_injections_v2", "instructions")
                   .flat_map { |instruction| Array(instruction["entries"]) }
    promoted_id = entries.find { |entry| entry.dig("content", "items", 0, "item", "itemContent", "promotedMetadata") }
                   .dig("content", "items", 0, "item", "itemContent", "tweet_results", "result", "rest_id")

    refute_nil promoted_id, "a fixture precisa conter o Shape controlado de propaganda"
    refute conv["replies"].any? { |reply| reply["id"] == promoted_id }, "anúncio promovido não pode entrar"
    assert conv["replies"].any?, "comentários reais continuam entrando"
    assert_equal comment_count(fixture_data), conv["replies"].size,
      "o contador orgânico deve incluir todos os comentários reais e excluir o anúncio"
  end

  # ------------------------------------------------------------------
  # Cursor Bottom de paginação
  # ------------------------------------------------------------------

  test "cursor Bottom presente na fixture real" do
    cursor = Fetcher::Channels::XConversation.extract_bottom_cursor(fixture_data)
    refute_nil cursor, "fixture real traz cursor Bottom de paginação"
    refute cursor.empty?
  end

  # Verdade fixa: o cursor Bottom da fixture (extraído da MESMA única fonte
  # que o parser usa — `collect_entries`). Não é a comparação de duas cópias
  # da mesma lógica que `extract_bottom_cursor` já era; aqui o valor esperado
  # é literal e a fonte é única (`parse_conversation`), então o teste ancora
  # a verdade real em vez de validar um espelho contra ele mesmo.
  EXPECTED_BOTTOM_CURSOR = "DAAKCgABHSw_qSq__u8LAAIAAAFcRW1QQzZ3QUFBZlEvZ0dKTjB2R3AvQUFBQUI0ZEtFTlF0MXFoeUIwbmk3ZC8yOUJZSFNrTEtHU1dZUjRkSjBYR0ZkdlF2UjBuTlFVMUd3RjNIU2ZsSzFvYm9USWRLSGdEa3hvZ25SMHFkYnRERjBGT0hTYzE5ZjFXVWJZZEowbHI5ZHJ3SEIwbnM1Vmlsc0E5SFNpSGxtK2FvT1VkSnpUVnFKdXdwaDBubHFEc213RDNIU2Y4SldzV3dkWWRKNThTZDFvUml4MG9kQTJ3bTRHVEhTYzJ3QTBiVUo0ZEowR3NaVmN3U3gwbjlpZ1ltcEhLSFNjOThCbmIwSE1kSjl4K2xGZlJrQjBubzZrWFZySG1IU2VvL0FXYkFjRWRKN1ROeFpyUkt4MG4xVVAwbHRHL0hTZkdjcktXNGVJZEovUTRUcGRnRmgwb1p4eGsydkRkSFNnVmUydldjR2s9CAADAAAAAgsABAAAAAZCb3R0b20AAA"

  test "parser propaga o cursor Bottom REAL da fixture (fonte única)" do
    conv = Fetcher::Channels::XConversation.parse_conversation(fixture_data, focal_id: ROOT_ID)
    assert_equal EXPECTED_BOTTOM_CURSOR, conv["cursor"],
      "cursor devolvido pelo parser deve ser o Bottom literal da fixture"
  end

  test "extract_bottom_cursor devolve o MESMO cursor (delegado, não cópia)" do
    # Agora o mesmo caminhador (collect_entries); não é mais uma segunda
    # implementação paralela — o teste só confirma que a delegação entrega o
    # valor esperado, não que duas cópias casam.
    assert_equal EXPECTED_BOTTOM_CURSOR,
                 Fetcher::Channels::XConversation.extract_bottom_cursor(fixture_data)
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

  test "fetch para quando o cursor se repete (freio anti-loop infinito)" do
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

  # ------------------------------------------------------------------
  # `limit` corta o resultado (item: limit não cortava)
  # ------------------------------------------------------------------

  def comment_entry(tweet)
    { "entryId" => "tweet-#{tweet["rest_id"]}",
      "content" => { "entryType" => "TimelineTimelineModule",
                     "items" => [ { "item" => { "itemContent" => { "tweet_results" => { "result" => tweet } } } } ] } }
  end

  test "fetch com limit menor que o total corta replies para o teto (corte determinístico)" do
    stub_transport
    # Página com raiz + 8 comentários; limit: 5 deve devolver 5 (os primeiros),
    # NÃO os 8. E como 5 >= limit, não pede página 2.
    page = convo([
      root_entry(minimal_tweet(ROOT_ID, "MonidHQ", "post raiz")),
      *(1..8).map { |i| comment_entry(minimal_tweet("c#{i}", "user#{i}", "comentário #{i}")) },
      cursor_entry("CUR-NEXT")
    ])
    resp = StubResp.new(status: 200, body: page.to_json, headers: {})
    Fetcher::SafeHttpClient.expects(:post).once.returns(resp)

    result = Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: 5, max_pages: 3)

    assert_equal 5, result["replies"].size, "limit: 5 deve cortar para 5 (os primeiros)"
    assert_equal ["c1", "c2", "c3", "c4", "c5"], result["replies"].map { |r| r["id"] },
      "corte mantém a ordem em que chegaram"
    assert_equal "CUR-NEXT", result["cursor"], "corte não descarta o cursor de paginação"
  end

  test "fetch com limit menor que o total em 2 páginas corta no limite global" do
    stub_transport
    # Página 1: 3 comentários + cursor p2. Página 2: 6 + cursor repetido p2
    # (quebra anti-loop). Total disponível: 9; limit: 4 deve devolver 4.
    # Ordem real: a âncora local (1º tweet lido da página de continuação)
    # fica NA FRENTE da página — logo os primeiros 4 globais são a,b,c + d1.
    page1 = convo([
      root_entry(minimal_tweet(ROOT_ID, "MonidHQ", "post raiz")),
      *%w[a b c].map { |id| comment_entry(minimal_tweet(id, "author", "texto #{id}")) },
      cursor_entry("CUR-P2")
    ])
    page2 = convo([
      *(1..6).map { |i| comment_entry(minimal_tweet("d#{i}", "author", "texto d#{i}")) },
      cursor_entry("CUR-P2") # repetido -> quebra
    ])
    Fetcher::SafeHttpClient.expects(:post).times(2)
      .returns(
        StubResp.new(status: 200, body: page1.to_json, headers: {}),
        StubResp.new(status: 200, body: page2.to_json, headers: {})
      )

    result = Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: 4, max_pages: 3)

    assert_equal 4, result["replies"].size, "limit global corta a soma das páginas"
    assert_equal ["a", "b", "c", "d1"], result["replies"].map { |r| r["id"] },
      "corte mantém a ordem de chegada (âncora local fica NA FRENTE da página de continuação)"
  end

  test "fixture REAL: limit menor que o total da fixture corta replies" do
    # A fixture traz 30 comentários; limit: 7 (menor que o total) deve
    # devolver EXATAMENTE 7 — prova que o `limit` corta o resultado, não
    # apenas estanca a paginação (o bug antigo devolvia os 30).
    stub_transport
    resp = StubResp.new(status: 200, body: fixture_data.to_json, headers: {})
    Fetcher::SafeHttpClient.expects(:post).times(1).returns(resp)

    result = Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: 7, max_pages: 1)

    assert_equal 7, result["replies"].size, "limit: 7 corta os 30 para 7"
    assert_equal 7, result["replies"].uniq { |r| r["id"] }.size, "corte não duplica"
    refute result["replies"].any? { |r| r["id"] == ROOT_ID }, "raiz não entra em replies"
  end

  # ------------------------------------------------------------------
  # Falhas de transporte / sessão (sem rede real)
  # ------------------------------------------------------------------

  test "falha de rede (SafeHttpClient::Error) vira ResponseError tipada" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post)
      .raises(Fetcher::SafeHttpClient::Error, "fiação do transporte caiu")

    err = assert_raises(Fetcher::Channels::XConversation::ResponseError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/falha de rede/, err.message)
    assert_match(/SafeHttpClient::Error/, err.message)
  end

  test "SSRF bloqueado vira ResponseError tipada" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post)
      .raises(Fetcher::SsrfGuard::Blocked.new("ip interno"))

    assert_raises(Fetcher::Channels::XConversation::ResponseError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "corpo não-JSON em HTTP 200 levanta ResponseError" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(
      StubResp.new(status: 200, body: "<html>não é a API</html>", headers: {})
    )

    err = assert_raises(Fetcher::Channels::XConversation::ResponseError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/não é JSON/, err.message)
  end

  test "teto total injetável (total_timeout) estoura o alarme do módulo para TimedOut (tipado)" do
    # Prova o alarme DO MÓDULO (não o do transporte): `total_timeout: 0.05`
    # faz o `Timeout.timeout(total_timeout)` do `fetch` (x_conversation.rb:209)
    # disparar no relógio real; o stub consome 0,3 s via busy-wait (`Kernel.sleep`
    # está stubado no `setup` e não anda o alarme do `Timeout`). O `rescue
    # Timeout::Error` (x_conversation.rb:212-213) tipa em `TimedOut` com o
    # orçamento INJETADO — o transporte real converte seu timeout interno em
    # `RequestTimeout` antes, então é o alarme do módulo que dispara aqui.
    stub_transport
    resp = StubResp.new(status: 200, body: fixture_data.to_json, headers: {})
    Fetcher::SafeHttpClient.stubs(:post).with do |*_|
      # busy-wait real de ~0.3 s (>> 0.05 s) DENTRO do bloco do `Timeout`:
      # o monitor do `Timeout` interrompe esta thread no meio da chamada, e o
      # `rescue Timeout::Error` do `fetch` (x_conversation.rb:212-213) tipa.
      deadline = Time.now + 0.3
      Time.now while Time.now < deadline
      true
    end.returns(resp)

    err = assert_raises(Fetcher::Channels::XConversation::TimedOut) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1, total_timeout: 0.05)
    end
    assert_match(/excedeu 0.05/, err.message,
      "a mensagem deve nomear o orçamento INJETADO (0.05 s), não o default de 30")
  end

  test "timeout do transporte vira TimedOut tipado e não devolve resultado parcial" do
    # `SafeHttpClient::RequestTimeout` é um timeout de transporte nomeado. O
    # contrato do canal deve preservar essa causa em `TimedOut`; como o erro
    # sobe de `fetch`, não existe resultado parcial silencioso para devolver.
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).once
      .raises(Fetcher::SafeHttpClient::RequestTimeout, "timeout de 25s")

    err = assert_raises(Fetcher::Channels::XConversation::TimedOut) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/RequestTimeout/, err.message, "o erro tipado deve nomear a causa")
  end

  test "HTTP 401 (stub) levanta AuthError (txid/csrf/sessão inválidos)" do
    stub_transport
    Fetcher::SafeHttpClient.expects(:post).returns(
      StubResp.new(status: 401, body: "{}", headers: {})
    )

    assert_raises(Fetcher::Channels::XConversation::AuthError) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
  end

  test "rate limit local (4/min estourado) levanta RateLimited sem gastar rede" do
    stub_transport(exceeded: true)
    Fetcher::SafeHttpClient.expects(:post).never

    err = assert_raises(Fetcher::Channels::XConversation::RateLimited) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/rate limit local/, err.message)
  end

  test "CookieJar::Expired (sessão ausente/expirada) levanta antes de tocar rede" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth" },
      { "name" => "ct0", "value" => "test-ct0" }
    ]
    Fetcher::CookieJar.stubs(:valid?).returns(false) # -> require! levanta Expired
    Fetcher::CookieJar.stubs(:for).returns(cookies)
    fake_txid = Class.new do
      def evidence_header(now_ms:, mask: nil, query_id: nil, path_suffix: nil, method: nil)
        "TXID(#{path_suffix})"
      end
    end.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake_txid)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::SafeHttpClient.expects(:post).never

    err = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_equal "x.com", err.domain
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

  test "HTTP 429 (stub) levanta RateLimitedRemote e arma o freio remoto" do
    stub_transport
    # `x-rate-limit-reset` plausível (future, <1h) define a janela; sem o
    # header, o piso de 60 s vale.
    reset_ts = (Time.now + 120).to_i
    Fetcher::SafeHttpClient.expects(:post).returns(
      StubResp.new(status: 429, body: "{}", headers: { "x-rate-limit-reset" => reset_ts.to_s })
    )

    err = assert_raises(Fetcher::Channels::XConversation::RateLimitedRemote) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/429/, err.message)

    # 429 ARMOU o bloqueio remoto (mesmo padrão do XGraphql):
    assert Fetcher::Channels::XConversation.remote_blocked?,
      "429 deve armar o freio remoto para a próxima chamada"
  end

  test "chamada seguida após 429 não bate na API de novo (freio trava antes da rede)" do
    stub_transport
    reset_ts = (Time.now + 120).to_s
    first = StubResp.new(status: 429, body: "{}", headers: { "x-rate-limit-reset" => reset_ts })
    # 1 POST exato (o que arma o freio). A chamada SEGUIDA NÃO pode tocar a
    # API: se tocar, o `post` passa do teto de chamadas e o mocha levanta —
    # o teste cai na hora certa, sem re-stub (re-stub do mesmo método é
    # terreno instável no mocha).
    Fetcher::SafeHttpClient.expects(:post).times(1).returns(first)

    assert_raises(Fetcher::Channels::XConversation::RateLimitedRemote) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end

    err = assert_raises(Fetcher::Channels::XConversation::RateLimitedRemote) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end
    assert_match(/bloqueio remoto/, err.message,
      "chamada seguida deve ser cortada pelo freio local, não pela API")
  end

  test "429 sem header de reset usa o piso de 60 s e o freio zera ao esgotar" do
    stub_transport
    first = StubResp.new(status: 429, body: "{}", headers: {})
    Fetcher::SafeHttpClient.expects(:post).times(1).returns(first)
    assert_raises(Fetcher::Channels::XConversation::RateLimitedRemote) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, max_pages: 1)
    end

    mod = Fetcher::Channels::XConversation
    assert mod.remote_blocked?
    # Sem header o piso de 60 s vale (mesma regra do XGraphql):
    assert mod.instance_variable_get(:@remote_block_until) > Time.now,
      "janela do freio deve estar no futuro (piso de 60 s)"
    # Esgota a janela (não dá para esperar 60 s na suíte) — o freio solta:
    mod.instance_variable_set(:@remote_block_until, Time.now - 1)
    refute mod.remote_blocked?, "após a janela o freio deve soltar sozinho"
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

  # ------------------------------------------------------------------
  # Borda do `limit` (borda: limit 0/negativo não vira calado nem cru)
  # ------------------------------------------------------------------

  test "limit: 0 levanta InvalidLimit (não devolve [] calado, não toca rede)" do
    # Antes da borda, `limit: 0` passava reto e `replies.first(0)` devolvia
    # `[]` — "post sem comentários" disfarçado de falha de contrato. Agora o
    # `fetch` valida ANTES do `gate!`/rede e devolve erro TÍPADO da família
    # `Channels::Error` (não `ArgumentError` cru nem silêncio).
    Fetcher::SafeHttpClient.expects(:post).never
    err = assert_raises(Fetcher::Channels::XConversation::InvalidLimit) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: 0, max_pages: 1)
    end
    assert_match(/limit inválido/, err.message)
    assert_kind_of Fetcher::Channels::Error, err, "InvalidLimit é da família Channels::Error"
  end

  test "limit negativo levanta InvalidLimit (não ArgumentError cru de first)" do
    # Antes da borda, `limit: -5` escapava até `replies.first(-5)` e levantava
    # `ArgumentError` CRU (fora da família tipada do canal). Agora o `fetch`
    # valida na entrada e devolve o erro TÍPADO da família `Channels::Error`.
    Fetcher::SafeHttpClient.expects(:post).never
    err = assert_raises(Fetcher::Channels::XConversation::InvalidLimit) do
      Fetcher::Channels::XConversation.fetch(tweet_id: ROOT_ID, limit: -5, max_pages: 1)
    end
    assert_match(/limit inválido/, err.message)
    assert_kind_of Fetcher::Channels::Error, err, "erro tipado, não ArgumentError cru"
  end
end
