# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/search_api_router"
require_relative "../../app/models/search_api_quota"

# Estes testes dependem do Rails (ActiveRecord p/ quota, WebMock p/ HTTP) e são
# rodados pelo orquestrador dockerizado. Cobrem o contrato de fallback definido
# na Spec funcional e nos Refinamentos SOTA (ordem: Linkup → Exa → Tavily).
class SearchApiRouterTest < ActiveSupport::TestCase
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  setup do
    Rails.cache.clear
    SearchApiQuota.delete_all if defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    # Sem chaves por padrão → router desligado; cada teste liga a que precisa.
    SEARCH_API_ENVS.each { |key| ENV.delete(key) }
  end

  teardown do
    @saved_env&.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # ── Spec 2: WebSearchTool NÃO chama o router quando o SearXNG responde ──────
  test "WebSearchTool não chama o router quando o SearXNG devolve resultados" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(status: 200, body: { results: [{ "title" => "T", "url" => "u", "content" => "c" }] }.to_json)

    SearchApiRouter.expects(:call).never
    result = WebSearchTool.new.execute(query: "rails")
    assert_equal :success, result[:status]
  end

  # ── Spec 2: SearXNG fetch nil → router chamado; resultados devolvidos ───────
  test "SearXNG indisponível chama o router e devolve os resultados do fallback" do
    ENV["LINKUP_API_KEY"] = "lk"
    stub_request(:get, /searxng:8080\/search/).to_return(status: 500)
    stub_linkup_success("rails", [{ name: "R1", url: "https://r1.com", content: "c" }])

    result = WebSearchTool.new.execute(query: "rails")
    assert_equal :success, result[:status]
    assert_equal "https://r1.com", result[:data].first[:url]
    assert_equal "linkup", result[:data].first[:engine]
  end

  # ── Spec 2: router nil → erro original do SearXNG preservado ───────────────
  test "router nil preserva o erro original do SearXNG" do
    stub_request(:get, /searxng:8080\/search/).to_return(status: 500)
    # Sem chaves → router desligado → call retorna nil.

    result = WebSearchTool.new.execute(query: "rails")
    assert_equal :error, result[:status]
    assert_equal "busca indisponível", result[:reason]
  end

  # ── Spec 1.b: sem nenhuma chave → router desligado (nil imediato) ───────────
  test "sem chaves o router retorna nil imediato" do
    assert_nil SearchApiRouter.call(query: "x", limit: 5)
  end

  # ── Spec 1.b/1.a: sucesso Linkup incrementa cota ───────────────────────────
  test "sucesso Linkup normaliza e incrementa a cota do mês" do
    ENV["LINKUP_API_KEY"] = "lk"
    stub_linkup_success("rails", [{ name: "R1", url: "https://r1.com", content: "c" }])

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_equal "linkup", out[:engine]
    assert_equal 1, out[:results].size
    assert_equal 1, SearchApiQuota.find_by(api_name: "linkup", month: SearchApiRouter.current_month).count
  end

  # ── Spec 1.a: Linkup 429 → pula para Exa (sem retry no 429) ────────────────
  test "Linkup 429 pula direto para Exa" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    stub_request(:post, "https://api.linkup.so/v1/search").to_return(status: 429)
    stub_exa_success("rails", [{ title: "E1", url: "https://e1.com", text: "c" }])

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_equal "exa", out[:engine]
    assert_equal "https://e1.com", out[:results].first[:url]
  end

  # ── Spec 1.a: todas as APIs falham → nil + motivo agregado ─────────────────
  test "todas as APIs falham → nil" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    ENV["TAVILY_API_KEY"] = "tv"
    stub_request(:post, "https://api.linkup.so/v1/search").to_return(status: 500)
    stub_request(:post, "https://api.exa.ai/search").to_return(status: 500)
    stub_request(:post, "https://api.tavily.com/search").to_return(status: 500)

    assert_nil SearchApiRouter.call(query: "rails", limit: 5)
  end

  # ── Refinamento SOTA 3 / Spec 1.b: cota esgotada da primeira → pula direto ─
  test "cota esgotada do Linkup pula para Exa sem chamar o Linkup" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    ENV["SEARCH_API_QUOTA_LINKUP"] = "1"
    SearchApiQuota.create!(api_name: "linkup", month: SearchApiRouter.current_month, count: 1)

    # Linkup NÃO deve ser chamado (cota cheia).
    stub_request(:post, "https://api.linkup.so/v1/search").to_raise("Linkup não devia ser chamado")
    stub_exa_success("rails", [{ title: "E1", url: "https://e1.com", text: "c" }])

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_equal "exa", out[:engine]
  end

  # ── Spec 1.b: mês novo reseta a cota (count por mês) ───────────────────────
  test "mês novo não conta a cota do mês anterior" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["SEARCH_API_QUOTA_LINKUP"] = "1"
    # Cota cheia, mas em mês anterior → não bloqueia o mês atual.
    SearchApiQuota.create!(api_name: "linkup", month: "2000-01", count: 99)
    stub_linkup_success("rails", [{ name: "R1", url: "https://r1.com", content: "c" }])

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_equal "linkup", out[:engine]
  end

  # ── Spec 1.f: time_range mapeado por API (verifica o body enviado) ─────────
  test "time_range day é enviado no body de cada API no formato certo" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    ENV["TAVILY_API_KEY"] = "tv"
    # Linkup esgotado (cota 0) para forçar Exa; Exa esgotado para forçar Tavily.
    ENV["SEARCH_API_QUOTA_LINKUP"] = "0"
    ENV["SEARCH_API_QUOTA_EXA"] = "0"

    stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(query: "hoje", time_range: "day"))
      .to_return(status: 200, body: { results: [{ title: "T1", url: "https://t1.com", content: "c", score: 0.9 }], usage: { credits: 1 } }.to_json)
    stub_request(:post, "https://api.linkup.so/v1/search").to_raise("não devia")
    stub_request(:post, "https://api.exa.ai/search").to_raise("não devia")

    out = SearchApiRouter.call(query: "hoje", limit: 5, time_range: "day")
    assert_equal "tavily", out[:engine]
  end

  # ── Linkup 200 com results=[]: continua por especialidade ou para em factual ──
  test "Linkup 200 com results vazio em query de papers continua para Exa" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    stub_request(:post, "https://api.linkup.so/v1/search")
      .with(body: hash_including(q: "papers sobre machine learning"))
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_exa_success("papers sobre machine learning", [{ title: "E1", url: "https://e1.com", text: "c" }])

    out = SearchApiRouter.call(query: "papers sobre machine learning", limit: 5)
    refute_nil out
    assert_equal "exa", out[:engine]
    assert_equal 1, out[:results].size
    assert_equal 1, SearchApiQuota.find_by(api_name: "linkup", month: SearchApiRouter.current_month).count
  end

  test "Linkup 200 com results vazio em query de lookup continua para Tavily pulando Exa" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    ENV["TAVILY_API_KEY"] = "tv"
    stub_request(:post, "https://api.linkup.so/v1/search")
      .with(body: hash_including(q: "como instalar rails"))
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.exa.ai/search").to_raise("Exa não devia ser chamada para lookup")
    stub_tavily_success("como instalar rails", [{ title: "T1", url: "https://t1.com", content: "c", score: 0.9 }])

    out = SearchApiRouter.call(query: "como instalar rails", limit: 5)
    refute_nil out
    assert_equal "tavily", out[:engine]
    assert_equal 1, out[:results].size
    assert_equal 1, SearchApiQuota.find_by(api_name: "linkup", month: SearchApiRouter.current_month).count
  end

  test "Linkup 200 com results vazio em query factual generica para a cascata e retorna nil" do
    ENV["LINKUP_API_KEY"] = "lk"
    ENV["EXA_API_KEY"] = "ex"
    ENV["TAVILY_API_KEY"] = "tv"
    stub_request(:post, "https://api.linkup.so/v1/search")
      .with(body: hash_including(q: "preço do bitcoin hoje"))
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.exa.ai/search").to_raise("Exa não devia ser chamada")
    stub_request(:post, "https://api.tavily.com/search").to_raise("Tavily não devia ser chamada")

    out = SearchApiRouter.call(query: "preço do bitcoin hoje", limit: 5)
    assert_nil out
    assert_equal 1, SearchApiQuota.find_by(api_name: "linkup", month: SearchApiRouter.current_month).count
  end

  # ── F3a (blindagem r1): envelopes reserve/rollback sob falha 5xx ────────────
  # Estes testes travam a contagem de chamadas de `reserve_quota_or_skip` e
  # `rollback_quota_silently` em 3 cenários do `attempt`. A regra é:
  #   - reserve_quota_or_skip: 1x por chamada NÃO-retry (não é re-chamado no
  #     retry — a reserva original cobre o 1 retry do `attempt`).
  #   - rollback_quota_silently: 1x por falha terminal (após o retry esgotar
  #     OU em 4xx/retryable=false imediato). NUNCA em 200 (mesmo vazio).
  #
  # Usamos spy via mocha (`.expects(...).with(...).once`) — NUNCA stubamos
  # `SearchApiRouter.call` (a API real é exercida de verdade). O HTTP é
  # stubado via WebMock (já é o padrão da suíte) ou via mocha para o caso
  # de `retryable=false` (que o WebMock puro não consegue forçar — `http_post`
  # calcula retryable do código de status 5xx e não há como desativar).
  test "5xx retryable=false: reserve=1 e rollback=1 (sem retry, falha terminal)" do
    ENV["LINKUP_API_KEY"] = "lk"
    # Stub forçado do http_post para simular falha 5xx com retryable=false
    # (caminho de erro terminal — não passa pelo retry interno do attempt).
    # Em produção, esse caminho é raro (5xx sempre é retryable=true); aqui
    # ele representa o "contrato se a API devolvesse retryable=false": a
    # reserva ainda é revertida.
    SearchApiRouter.expects(:http_post)
      .with(:linkup, "rails", 5, anything)
      .returns({ ok: false, reason: "HTTP 500", retryable: false })

    SearchApiRouter.expects(:reserve_quota_or_skip).with(:linkup).returns(true).once
    SearchApiRouter.expects(:rollback_quota_silently).with(:linkup).once

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_nil out
  end

  test "5xx + retry que falha: reserve=1 e rollback=1 (retry NÃO reserva de novo)" do
    ENV["LINKUP_API_KEY"] = "lk"
    # WebMock encadeia: 1ª chamada 500, retry também 500. O `attempt` re-tenta
    # (com `retried: true`, sem nova reserva) e só então chama rollback. Asserções
    # verificam a regra "retry NÃO reserva de novo" (reserve=1) e "ambos os
    # failures revertem" (rollback=1 ao fim).
    stub_request(:post, "https://api.linkup.so/v1/search")
      .to_return(status: 500).then.to_return(status: 500)

    SearchApiRouter.expects(:reserve_quota_or_skip).with(:linkup).returns(true).once
    SearchApiRouter.expects(:rollback_quota_silently).with(:linkup).once

    out = SearchApiRouter.call(query: "rails", limit: 5)
    assert_nil out
  end

  test "5xx depois 200 (retry sucede): reserve=1 e rollback=0 (200 cobra)" do
    ENV["LINKUP_API_KEY"] = "lk"
    # WebMock: 1ª chamada 500, retry 200 com 1 resultado. O `attempt` re-tenta
    # sem nova reserva e SUCEDE — 200 cobra, rollback NÃO é chamado.
    stub_request(:post, "https://api.linkup.so/v1/search")
      .to_return(status: 500)
      .then.to_return(
        status: 200,
        body: { results: [{ "name" => "R1", "url" => "https://r1.com", "content" => "c" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    SearchApiRouter.expects(:reserve_quota_or_skip).with(:linkup).returns(true).once
    SearchApiRouter.expects(:rollback_quota_silently).with(:linkup).never

    out = SearchApiRouter.call(query: "rails", limit: 5)
    refute_nil out
    assert_equal "linkup", out[:engine]
    assert_equal 1, out[:results].size
  end

  private

  def stub_linkup_success(query, results)
    stub_request(:post, "https://api.linkup.so/v1/search")
      .with(body: hash_including(q: query))
      .to_return(
        status: 200,
        body: { results: results }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_tavily_success(query, results)
    stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(query: query))
      .to_return(
        status: 200,
        body: { results: results, usage: { credits: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_exa_success(query, results)
    stub_request(:post, "https://api.exa.ai/search")
      .with(body: hash_including(query: query))
      .to_return(
        status: 200,
        body: { results: results }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
