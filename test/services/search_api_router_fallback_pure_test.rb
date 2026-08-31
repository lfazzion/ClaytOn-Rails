# frozen_string_literal: true

# Testes PUROS do SearchApiRouter para os Defeitos 2 e 3:
#  - Defeito 2: `attempt` recebe score_threshold e uma chamada Tavily bem-sucedida
#    normaliza e devolve engine :tavily (sem ActiveRecord/WebMock).
#  - Defeito 3: o body Tavily enviado inclui chunks_per_source=1,
#    auto_parameters=false e mantém include_answer=false (refinamentos SOTA).

require "minitest/autorun"
require "net/http"
require "json"
require "date"

unless defined?(Rails)
  module Rails
  end
end

unless Rails.respond_to?(:logger) && Rails.logger
  def Rails.logger
    @logger ||= Object.new.tap do |l|
      l.define_singleton_method(:info)  { |*| }
      l.define_singleton_method(:warn)  { |*| }
      l.define_singleton_method(:error) { |*| }
    end
  end
end

unless defined?(Rails::PureMemoryCacheStore)
  module Rails
    class PureMemoryCacheStore
      def initialize
        @data = {}
      end

      def read(key)
        @data[key]
      end

      def write(key, value, **_options)
        @data[key] = value
      end

      def clear
        @data.clear
      end
    end
  end
end

unless Rails.respond_to?(:cache) && Rails.cache
  def Rails.cache
    @pure_cache_instance ||= Rails::PureMemoryCacheStore.new
  end
end

require_relative "../../app/services/search_api_router"

class SearchApiRouterFallbackPureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  # O stub substitui os métodos singleton `http_post`, `reserve_quota_or_skip`,
  # `rollback_quota_silently` e `quota_exceeded?`. Guardamos as implementações
  # ORIGINAIS no setup e restauramos em teardown para não vazar stubs para
  # outros testes em ordem aleatória.
  #
  # F3a (E10): o caminho novo de quota é `reserve_quota_or_skip` ANTES do HTTP
  # e `rollback_quota_silently` SÓ em falha. `increment_quota` virou helper
  # legado público (mantido por compat) e não é mais chamado por `attempt` —
  # mas continua no teardown só para garantir limpeza de testes que ainda o
  # stubam por costume (não causam efeito na semântica, só evitam surpresa).
  def setup
    @original_http_post = SearchApiRouter.singleton_class.instance_method(:http_post)
    @original_increment_quota = SearchApiRouter.singleton_class.instance_method(:increment_quota)
    @original_quota_exceeded = SearchApiRouter.singleton_class.instance_method(:quota_exceeded?)
    @original_reserve_quota_or_skip = SearchApiRouter.singleton_class.instance_method(:reserve_quota_or_skip)
    @original_rollback_quota_silently = SearchApiRouter.singleton_class.instance_method(:rollback_quota_silently)
    @original_rails_logger = Rails.singleton_class.instance_method(:logger) if Rails.respond_to?(:logger)
    @original_rails_cache = Rails.singleton_class.instance_method(:cache) if Rails.respond_to?(:cache)
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }
  end

  def teardown
    SearchApiRouter.singleton_class.send(:define_method, :http_post, @original_http_post)
    SearchApiRouter.singleton_class.send(:define_method, :increment_quota, @original_increment_quota)
    SearchApiRouter.singleton_class.send(:define_method, :quota_exceeded?, @original_quota_exceeded)
    SearchApiRouter.singleton_class.send(:define_method, :reserve_quota_or_skip, @original_reserve_quota_or_skip)
    SearchApiRouter.singleton_class.send(:define_method, :rollback_quota_silently, @original_rollback_quota_silently)
    if defined?(@original_rails_logger) && @original_rails_logger
      Rails.singleton_class.send(:define_method, :logger, @original_rails_logger)
      @original_rails_logger = nil
    end
    if defined?(@original_rails_cache) && @original_rails_cache
      Rails.singleton_class.send(:define_method, :cache, @original_rails_cache)
      @original_rails_cache = nil
    end
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Substitui http_post por um stub que captura o body montado em build_request
  # e devolve um payload Tavily de sucesso.
  def capture_tavily_attempt(time_filter, fake_body)
    captured = {}
    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      _uri, req = SearchApiRouter.send(:build_request, provider, query, limit, tf)
      captured[:body] = JSON.parse(req.body)
      { ok: true, body: fake_body, reason: nil, retryable: false }
    end
    out = SearchApiRouter.attempt(:tavily, "rails", 5, time_filter, Date.today, score_threshold: 0.7)
    [out, captured]
  end

  def test_attempt_tavily_bem_sucedida_normaliza_e_devolve_engine_tavily_defeito_2
    fake_body = {
      "results" => [{ "title" => "R1", "url" => "https://r1.com", "content" => "c", "score" => 0.9 }],
      "usage" => { "credits" => 1 }
    }
    out, = capture_tavily_attempt(nil, fake_body)
    result, _reason = out

    assert_equal "tavily", result[:engine]
    assert_equal 1, result[:results].size
    assert_equal "https://r1.com", result[:results].first[:url]
    assert_equal 1, result[:cost], "custo Tavily vem de usage.credits"
  end

  # ── Regressão: engine deve ser String (não Symbol) no retorno de attempt ─────
  # A suíte Rails (search_api_router_test.rb) asserta engine como "tavily"
  # (String), mas o attempt devolvia `provider` (Symbol :tavily). Correção
  # mínima: provider.to_s. Este teste puro trava o contrato para não regressar.
  def test_engine_retornado_como_string_nao_symbol_defeito_1
    fake_body = {
      "results" => [{ "title" => "R1", "url" => "https://r1.com", "content" => "c", "score" => 0.9 }],
      "usage" => { "credits" => 1 }
    }
    out, = capture_tavily_attempt(nil, fake_body)
    result, _reason = out

    assert_kind_of String, result[:engine], "engine deve ser String, não Symbol (Defeito 1)"
    assert_equal "tavily", result[:engine], "engine deve normalizar para string 'tavily'"
  end

  def test_body_tavily_sota_inclui_chunks_per_source_e_auto_parameters_false_defeito_3
    fake_body = {
      "results" => [{ "title" => "R1", "url" => "https://r1.com", "content" => "c", "score" => 0.9 }]
    }
    _, captured = capture_tavily_attempt(nil, fake_body)
    body = captured[:body]

    assert_equal 1, body["chunks_per_source"], "SOTA: chunks_per_source deve ser 1"
    assert_equal false, body["auto_parameters"], "SOTA: auto_parameters nunca true"
    assert_equal false, body["include_answer"], "include_answer deve permanecer false"
    assert_equal "basic", body["search_depth"], "search_depth fixo em basic"
    assert_equal true, body["include_usage"], "SOTA: include_usage deve ser true para receber usage.credits"
  end

  # ── Linkup HTTP 200 com raw results=[] (JSON vazio cru) ─────────────────
  # Contrato por especialidade (Item A):
  # 200 vazio de um provider = miss da especialidade (incrementa cota).
  # Continua a cascata para o próximo provider SÓ SE a query casar com a especialidade do próximo.
  def test_attempt_linkup_raw_results_vazio_devolve_empty_sucesso_reserva_cobra_200_vazio
    # F3a: o contrato novo de quota é reservar ANTES do HTTP (`reserve_quota_or_skip`)
    # e reverter SÓ em falha (`rollback_quota_silently`). No 200-vazio a reserva
    # fica valendo — a cota é cobrada. Este teste asserta esse contrato:
    #   1. `attempt` chama `reserve_quota_or_skip` (reserva aconteceu)
    #   2. `attempt` NÃO chama `rollback_quota_silently` (200-vazio cobra)
    #   3. resultado continua sendo hash válido com results=[] (semântica intacta)
    fake_body = {
      "results" => [],
      "sources" => []
    }

    reserved_called = false
    SearchApiRouter.singleton_class.send(:define_method, :reserve_quota_or_skip) do |_provider, **_opts|
      reserved_called = true
      true # simula "cota reservada com sucesso"
    end

    rollback_called = false
    SearchApiRouter.singleton_class.send(:define_method, :rollback_quota_silently) do |_provider, **_opts|
      rollback_called = true
    end

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      { ok: true, body: fake_body, reason: nil, retryable: false }
    end

    result, reason = SearchApiRouter.attempt(:linkup, "rails", 5, nil, Date.today, score_threshold: 0.7)
    refute_nil result, "Linkup 200 com results=[] cru deve retornar hash válido"
    assert_nil reason, "não deve haver reason de falha quando a API respondeu 200"
    assert_equal "linkup", result[:engine]
    assert_equal [], result[:results]
    assert reserved_called, "reserve_quota_or_skip deve ser chamado antes do HTTP (reserva é pré-HTTP na F3a)"
    refute rollback_called, "rollback_quota_silently NÃO deve ser chamado em 200-vazio — quota fica cobrada (200 vazio cobra)"
  end

  def test_call_linkup_200_vazio_continua_para_exa_em_query_de_papers
    # F4 do plano-fase2 (30/08/2026): Path B reordenado — query de papers
    # (regex exa) faz Exa ser o 1º pago da cascata, NÃO Linkup. Stubber
    # legado de F3 esperava `[:linkup, :exa]` (linkup 200 vazio → exa serve);
    # F4 mudou a ordem de TRABALHO para `[:exa]` (exa serve direto).
    # O contrato semântico preservado: papers → exa (não linkup).
    calls = []
    fake_exa = {
      "results" => [{ "title" => "E1", "url" => "https://exa.ai/paper1", "highlights" => ["attention"] }]
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :exa
        { ok: true, body: fake_exa, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "papers sobre machine learning", limit: 5)
      refute_nil result, "deve obter resultado do Exa após query de papers"
      assert_equal "exa", result[:engine]
      assert_equal 1, result[:results].size
      assert_equal [:exa], calls, "F4: papers → Exa 1º no pago (não mais [:linkup, :exa])"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  def test_call_linkup_200_vazio_continua_para_tavily_em_query_de_lookup_pulando_exa
    # F4 do plano-fase2 (30/08/2026): Path B reordenado — query de lookup
    # (regex tavily) faz Tavily ser o 1º pago da cascata, NÃO Linkup. Stubber
    # legado de F3 esperava `[:linkup, :tavily]` (linkup 200 vazio → tavily serve);
    # F4 mudou a ordem de TRABALHO para `[:tavily]` (tavily serve direto).
    # O contrato semântico preservado: lookup → tavily (não exa).
    calls = []
    fake_tavily = {
      "results" => [{ "title" => "T1", "url" => "https://tavily.com/doc", "content" => "c", "score" => 0.9 }],
      "usage" => { "credits" => 1 }
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :tavily
        { ok: true, body: fake_tavily, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "como instalar rails", limit: 5)
      refute_nil result, "deve obter resultado do Tavily em query de lookup"
      assert_equal "tavily", result[:engine]
      assert_equal 1, result[:results].size
      assert_equal [:tavily], calls, "F4: lookup → Tavily 1º no pago (não mais [:linkup, :tavily])"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  def test_call_linkup_200_vazio_para_cascata_em_query_factual_generica
    calls = []
    fake_linkup = { "results" => [], "sources" => [] }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      { ok: true, body: fake_linkup, reason: nil, retryable: false }
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "preço do bitcoin hoje", limit: 5)
      assert_nil result, "query factual genérica com miss no Linkup deve parar a cascata e retornar nil"
      assert_equal [:linkup], calls, "não deve gastar cota de Exa ou Tavily em query factual genérica"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  def test_call_linkup_falha_http_500_cai_em_exa_diferenciando_de_results_vazio
    calls = []
    fake_exa = {
      "results" => [{ "title" => "E1", "url" => "https://exa.com/1", "text" => "c" }]
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :linkup
        { ok: false, body: nil, reason: "HTTP 500", retryable: false }
      else
        { ok: true, body: fake_exa, reason: nil, retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "rails", limit: 5)
      refute_nil result
      assert_equal "exa", result[:engine]
      assert_equal [:linkup, :exa], calls, "falha HTTP 500 no Linkup deve cair para Exa"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  # ── (2) Tavily HTTP 200 com todos scores abaixo do threshold ─────────────────
  # O filtro de score é EXCLUSIVO do Tavily (apply_score_filter só roda para
  # :tavily). Linkup/Exa não expõem score comparável — não há filtro para eles.
  # Score baixo no Tavily NÃO é falha: a API respondeu 200. Deve devolver
  # resultado válido com results=[] e engine string, incrementar a cota e NÃO
  # cair para os outros providers.
  def test_attempt_tavily_todos_scores_abaixo_threshold_devolve_results_empty_e_engine_tavily
    fake_body = {
      "results" => [{ "title" => "R1", "url" => "https://r1.com", "content" => "c", "score" => 0.1 }],
      "usage" => { "credits" => 1 }
    }
    out, = capture_tavily_attempt(nil, fake_body)
    result, reason = out

    refute_nil result, "Tavily 200 com score baixo não deve cair para nil (fallback)"
    assert_nil reason, "não deve haver reason quando a API respondeu 200"
    assert_equal "tavily", result[:engine]
    assert_equal [], result[:results], "results deve ser [] quando todos os scores ficam abaixo do threshold"
  end

  def test_attempt_tavily_score_baixo_reserva_cobra_200_vazio_sem_rollback
    # F3a: o contrato novo de quota é reservar ANTES do HTTP (`reserve_quota_or_skip`)
    # e reverter SÓ em falha (`rollback_quota_silently`). No 200-vazio (mesmo
    # com score baixo → results=[] após filtro) a reserva fica valendo — a
    # cota é cobrada. Este teste asserta esse contrato:
    #   1. `attempt` chama `reserve_quota_or_skip` (reserva pré-HTTP)
    #   2. `attempt` NÃO chama `rollback_quota_silently` (200 vazio cobra)
    #   3. resultado continua sendo hash válido com results=[] (semântica intacta)
    fake_body = {
      "results" => [{ "title" => "R1", "url" => "https://r1.com", "content" => "c", "score" => 0.1 }],
      "usage" => { "credits" => 1 }
    }

    reserved_called = false
    SearchApiRouter.singleton_class.send(:define_method, :reserve_quota_or_skip) do |_provider, **_opts|
      reserved_called = true
      true # simula "cota reservada com sucesso"
    end

    rollback_called = false
    SearchApiRouter.singleton_class.send(:define_method, :rollback_quota_silently) do |_provider, **_opts|
      rollback_called = true
    end

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      { ok: true, body: fake_body, reason: nil, retryable: false }
    end

    result, _reason = SearchApiRouter.attempt(:tavily, "rails", 5, nil, Date.today, score_threshold: 0.7)
    assert result, "deve devolver resultado válido (não nil)"
    assert_equal [], result[:results]
    assert reserved_called, "reserve_quota_or_skip deve ser chamado antes do HTTP (reserva é pré-HTTP na F3a)"
    refute rollback_called, "rollback_quota_silently NÃO deve ser chamado em 200-vazio — quota fica cobrada (200 vazio cobra)"
  end

  def test_call_linkup_scores_nao_filtram_porque_linkup_nao_expoe_score
    calls = []
    fake_linkup = {
      "results" => [{ "name" => "R1", "url" => "https://r1.com", "content" => "c" }],
      "sources" => []
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      { ok: true, body: fake_linkup, reason: nil, retryable: false }
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "rails", limit: 5)
      refute_nil result, "SearchApiRouter.call deve retornar hash válido"
      assert_equal "linkup", result[:engine]
      assert_equal 1, result[:results].size,
                   "Linkup não tem filtro de score — item sem score NÃO é descartado"
      assert_equal [:linkup], calls, "não deve tentar Exa ou Tavily quando Linkup respondeu 200"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  # F4 do plano-fase2 (30/08/2026): Path B reordena a lista de trabalho.
  # Quando `specialty_for(query)` casa com Exa, o 1º pago da cascata é Exa
  # (não mais Linkup). NUNCA muda `PROVIDERS` — só a ordem de trabalho
  # interna. Cobertura do aceite do plano:
  #   arxiv + SearXNG down + type=academic (ou regex) -> Exa primeiro no pago
  def test_call_query_papers_exa_e_primeiro_pago_path_b_f4
    calls = []
    fake_exa = {
      "results" => [{ "title" => "E1", "url" => "https://exa.ai/p1", "highlights" => ["attention"] }]
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :exa
        { ok: true, body: fake_exa, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "arxiv transformers attention", limit: 5)
      refute_nil result
      assert_equal "exa", result[:engine]
      assert_equal [:exa], calls,
                   "Path B reordenado: query com specialty exa → Exa 1º (Linkup/Tavily NÃO são tentados no caminho feliz)"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  # F4 (30/08/2026): query de notícia → Tavily 1º pago. Cobre o aceite
  # "time_range=day no Discord -> Tavily primeiro no pago (via regex
  # notícia, não type)". Sem `type:` explícito, o regex `notícia` agora
  # reordena a fila para Tavily primeiro.
  def test_call_query_noticia_tavily_e_primeiro_pago_path_b_f4
    calls = []
    fake_tavily = {
      "results" => [{ "title" => "N1", "url" => "https://n.com", "content" => "c", "score" => 0.9 }],
      "usage" => { "credits" => 1 }
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :tavily
        { ok: true, body: fake_tavily, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "última notícia do SpaceX agora", limit: 5, time_range: "day")
      refute_nil result
      assert_equal "tavily", result[:engine]
      assert_equal [:tavily], calls,
                   "Path B reordenado: query de notícia (regex F4) → Tavily 1º no pago"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  # F4 (30/08/2026): generic factual (sem regex de especialidade) → Linkup
  # continua sendo o 1º pago. Comportamento atual PRESERVADO.
  def test_call_query_generica_sem_especialidade_linkup_continua_primeiro_path_b_f4
    calls = []
    fake_linkup = {
      "results" => [{ "name" => "L1", "url" => "https://l.com", "content" => "c" }],
      "sources" => []
    }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :linkup
        { ok: true, body: fake_linkup, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "preço do bitcoin hoje", limit: 5)
      refute_nil result
      assert_equal "linkup", result[:engine]
      assert_equal [:linkup], calls,
                   "Path B sem especialidade: Linkup continua 1º (comportamento preservado)"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end

  # F4 (30/08/2026): query Tavily-especialidade 200 vazio → o próximo da
  # fila é Tavily-especialidade? Não: já estava nele. Path B reordenado
  # com Tavily 1º e 200 vazio significa: query SEM match para próximo
  # (Tavily é o último da especialidade) → para. Cobertura de regressão
  # para que Path B não introduza cascata extra descontrolada.
  def test_call_query_noticia_tavily_primeiro_200_vazio_para_sem_chamar_outro_pago_f4
    calls = []
    fake_tavily_vazio = { "results" => [] }

    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, query, limit, tf|
      calls << provider
      if provider == :tavily
        { ok: true, body: fake_tavily_vazio, reason: nil, retryable: false }
      else
        { ok: false, body: nil, reason: "NÃO DEVERIA TER SIDO CHAMADO", retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]

    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      result = SearchApiRouter.call(query: "última notícia SpaceX agora", limit: 5)
      assert_nil result
      assert_equal [:tavily], calls,
                   "Path B com Tavily 1º + 200 vazio: para a cascata (sem cascata adicional)"
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
    end
  end


  def test_current_month_formato_yyyy_mm
    assert_match(/\A\d{4}-\d{2}\z/, SearchApiRouter.current_month)
  end
end
