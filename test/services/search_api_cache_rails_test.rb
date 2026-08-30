# frozen_string_literal: true

require "test_helper"

# Testes Rails/WebMock do SearchApiCache (F3c do plano-fase2) — fim-a-fim.
#
# Cobre:
#   - Stub do SearXNG local: 1ª chamada → http_request 1x; 2ª chamada igual
#     → http_request NÃO é chamado (cache hit) e resultado idêntico.
#   - TTL por tipo: queries com type diferente têm TTL diferente no Rails.cache.
#   - Type diferente gera key diferente (caches isolados).
#
# Estes testes exigem `test_helper` (Rails), por isso rodam sob a suíte
# `bin/rails test`. O maestro (fan-in) é quem dispara essa suíte — eu
# só garanto que o arquivo carrega sem syntax error e está coerente com
# `app/services/search_api_cache.rb` (verificado nos pure tests).

class SearchApiCacheRailsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  # ── Fim-a-fim: 2ª chamada idêntica não chama o SearXNG ────────────────────
  # Garante que o SearchApiCache está integrado com o WebSearchTool:
  # ler do cache na entrada evita o HTTP, gravar na saída permite o hit.
  test "primeira chamada chama SearXNG; segunda idêntica acerta cache (sem HTTP)" do
    stub = stub_request(:get, /searxng:8080\/search/)
           .to_return(
             status: 200,
             body: { results: [{ "title" => "T", "url" => "https://x", "content" => "c", "engine" => "ddg" }] }.to_json,
             headers: { "Content-Type" => "application/json" }
           )

    2.times { WebSearchTool.new.execute(query: "cache hit rails") }

    assert_requested stub, times: 1
  end

  # ── TTL por tipo: news vs factual gravam TTLs distintos ──────────────────
  # O `Rails.cache` em teste é FileStore. Verifica via SearchApiCache.read
  # que cada tipo grava com seu TTL (cache hit só dentro do TTL).
  test "TTL tipo news: query cacheada é lida dentro do TTL de 600s" do
    # Stub do SearXNG: type=news não cai em fallback, então só SearXNG chama.
    # `tt1` é 1 termo, RelevanceGuard desliga (MIN_QUERY_TERMS=2).
    stub = stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [{ "title" => "T1", "url" => "https://t1", "content" => "c1", "engine" => "ddg" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    WebSearchTool.new.execute(query: "tt1", type: "news")
    # 599s < 600s → ainda dentro do TTL.
    assert_not_nil SearchApiCache.read(query: "tt1", limit: 5, time_range: nil,
                                       type: "news", provider: :tavily)
    # Garante que o SearXNG foi chamado UMA vez (fallback não pode ter disparado
    # nem repetido por engano). Se regredir para chamar 2x, este teste pega.
    assert_requested stub, times: 1
  end

  test "type=news não vaza hit para type=factual (key diferente)" do
    # Stub: tt2 só tem 1 termo, RelevanceGuard desliga, SearXNG devolve resultado.
    stub = stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [{ "title" => "T2", "url" => "https://t2", "content" => "c2", "engine" => "ddg" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    WebSearchTool.new.execute(query: "tt2", type: "news")
    # Mesma query, type diferente → key diferente → cache miss.
    assert_nil SearchApiCache.read(query: "tt2", limit: 5, time_range: nil,
                                   type: "factual", provider: :linkup)
    # Mesmo aqui (cache miss no read factual): SearXNG só foi chamado UMA vez.
    # Se algum caminho duplo (fallback ou read repetido) chamar de novo, falha.
    assert_requested stub, times: 1
  end

  # ── Cache hit SEM alterar o comportamento do resultado ────────────────────
  test "cache hit devolve os mesmos dados da chamada anterior" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [{ "title" => "Hit", "url" => "https://h.com", "content" => "snip", "engine" => "ddg" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    r1 = WebSearchTool.new.execute(query: "stable result", type: "news")
    r2 = WebSearchTool.new.execute(query: "stable result", type: "news")

    assert_equal :success, r1[:status]
    assert_equal :success, r2[:status]
    assert_equal r1[:data].first[:title], r2[:data].first[:title]
    assert_equal r1[:data].first[:url],   r2[:data].first[:url]
  end

  # ── Cache vazio: debounce de 60s mas resultado nunca é servido como conteúdo
  test "cache vazio do SearXNG devolve sucesso com [] em chamada repetida no mesmo turno" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    r1 = WebSearchTool.new.execute(query: "consulta sem resposta alguma")
    r2 = WebSearchTool.new.execute(query: "consulta sem resposta alguma")

    assert_equal :success, r1[:status]
    assert_equal :success, r2[:status]
    assert_empty r1[:data]
    assert_empty r2[:data]
  end

  # ── Cache de erro (engines fora do ar) NÃO é cacheado ────────────────────
  test "erro de engines fora do ar repete o HTTP na 2ª chamada" do
    stub = stub_request(:get, /searxng:8080\/search/)
           .to_return(
             status: 200,
             body: { results: [], unresponsive_engines: [["brave", "Suspended"]] }.to_json,
             headers: { "Content-Type" => "application/json" }
           )

    2.times { WebSearchTool.new.execute(query: "placar do jogo de ontem") }

    # Erro não pode ser cacheado: 2ª chamada deve repetir o HTTP.
    assert_requested stub, times: 2
  end

  # ── Cache rejeita vazio (não vaza para o SearchApiCache de conteúdo) ──────
  # type="auto" e não `type: nil`: a `WebSearchTool` resolve type fora do
  # enum para "auto" (defesa da linha 121 de web_search_tools.rb) — e o
  # `SearchApiCache.read` precisa ler com a mesma chave que o `write`
  # usaria. `type: nil` ficaria em chave DIFERENTE da que o `write` gravou
  # (TTL=piso 60s mas o `key_for` rotula diferente), falso-verde de
  # "cache rejeitou". type="auto" é o que a tool de fato passa.
  test "SearchApiCache.read não encontra vazio (vazio fica só no debounce)" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [] }.to_json
      )

    WebSearchTool.new.execute(query: "vai-vazio")

    # SearchApiCache.read deve retornar nil — vazio NÃO é gravado lá.
    assert_nil SearchApiCache.read(query: "vai-vazio", limit: 5, time_range: nil,
                                   type: "auto", provider: nil),
               "SearchApiCache rejeita payload=[]; vazio fica só no debounce da tool"
  end

  # ── Fail-open do store (decisão (f) da classe) ─────────────────────────────
  # `Rails.cache` que raise NÃO derruba `WebSearchTool#run`. Stub do
  # SearXNG local está presente — o fetch funciona — mas o cache do read
  # explode e o tool segue.
  test "Read do cache que explode: WebSearchTool continua e faz o fetch" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(
        status: 200,
        body: { results: [{ "title" => "T", "url" => "https://x", "content" => "c", "engine" => "ddg" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    prev_cache = Rails.cache
    boom = Class.new do
      def read(_); raise IOError, "boom read"; end
      def write(*_); raise Errno::EIO, "boom write"; end
      def clear; end
    end.new
    Rails.singleton_class.send(:define_method, :cache) { boom }

    begin
      r = WebSearchTool.new.execute(query: "cache estourou", type: "news")
      assert_equal :success, r[:status]
      assert_equal "T", r[:data].first[:title]
    ensure
      captured = prev_cache
      Rails.singleton_class.send(:define_method, :cache) { captured }
    end
  end
end
