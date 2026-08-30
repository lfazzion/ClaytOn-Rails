# frozen_string_literal: true

# Testes PUROS do contrato de `specialty:` no SearchApiRouter (sem Rails/docker).
#
# Contrato (decisão do maestro, plano v2 F2):
#   `specialty:` presente e habilitado (chave + cota) → tenta UMA vez.
#     - sucesso → retorna o resultado;
#     - 200 vazio OU HTTP fail → retorna nil (NÃO chama mais nenhum pago; cota
#       do preferred já foi cobrada no attempt).
#   `specialty:` presente mas NÃO habilitado (sem chave / cota zerada) →
#     degrada para cascata padrão (linkup → exa → tavily), idêntica ao auto.
#   `specialty:` ausente (`auto`) → fluxo legado intacto (cascata padrão por regex).
#
# Estes testes instanciam o router de VERDADE e fazem stub APENAS de
# `http_post` / `quota_exceeded?` / `increment_quota` (NUNCA de `call`).
# Rodáveis com `ruby test/services/search_api_router_specialty_pure_test.rb`.

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

require "active_record"
unless defined?(ApplicationRecord)
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end

require_relative "../../app/services/search_api_router"

# Shims para o teste (g) — `WebSearchTool` precisa de RubyLLM::Tool e Integer#minute(s).
unless defined?(RubyLLM::Tool)
  module RubyLLM
    class Tool
      def self.inherited(subclass)
        subclass.singleton_class.class_eval do
          def description(*); end
          def param(*); end
        end
      end
    end
  end
end

class Integer
  unless method_defined?(:minutes)
    define_method(:minutes) { |_ = nil| self * 60 }
  end
  unless method_defined?(:minute)
    define_method(:minute) { |_ = nil| self * 60 }
  end
end

require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/web_search_tools"

class SearchApiRouterSpecialtyPureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  # Salva as implementações originais para o teardown.
  def setup
    @original_http_post = SearchApiRouter.singleton_class.instance_method(:http_post)
    @original_quota_exceeded = SearchApiRouter.singleton_class.instance_method(:quota_exceeded?)
    @original_increment_quota = SearchApiRouter.singleton_class.instance_method(:increment_quota)
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }
    @calls = []
  end

  def teardown
    SearchApiRouter.singleton_class.send(:define_method, :http_post, @original_http_post)
    SearchApiRouter.singleton_class.send(:define_method, :quota_exceeded?, @original_quota_exceeded)
    SearchApiRouter.singleton_class.send(:define_method, :increment_quota, @original_increment_quota)
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Stub de http_post: tabela indexada por provider, na ordem dada.
  # Cada entry é o retorno bruto {ok:, body:, reason:, retryable:}.
  #
  # IMPORTANTE: as chamadas são capturadas numa closure local (`calls`), NÃO
  # em `@calls` da classe — `define_method` no singleton executa o bloco no
  # contexto do SearchApiRouter (instância do singleton da classe), então um
  # `@calls` ali é um ivar DIFERENTE do `@calls` da instância de teste. Com
  # closure, ambos os lados veem a mesma referência.
  def stub_http_post(table)
    calls = []
    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, _query, _limit, _tf|
      calls << provider
      entry = table[provider]
      raise "stub http_post não preparado para #{provider}" unless entry

      entry
    end
    calls
  end

  # Quota zerada só para o provider passado; o resto fica liberado.
  def stub_quota_exhausted_only(*providers)
    SearchApiRouter.singleton_class.send(:define_method, :quota_exceeded?) do |provider|
      providers.include?(provider)
    end
  end

  # Quota livre para todos.
  def stub_quota_open
    SearchApiRouter.singleton_class.send(:define_method, :quota_exceeded?) { |_| false }
  end

  def stub_increment_quota_noop
    SearchApiRouter.singleton_class.send(:define_method, :increment_quota) { |_| }
  end

  # (a) preferred habilitado + sucesso → SÓ ELE é chamado.
  def test_specialty_habilitado_sucesso_so_chama_o_preferred
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post(
      { tavily: { ok: true, body: { "results" => [{ "title" => "N1", "url" => "https://n1.com", "content" => "c", "score" => 0.95 }], "usage" => { "credits" => 1 } }, reason: nil, retryable: false } }
    )

    out = SearchApiRouter.call(query: "última notícia SpaceX agora", specialty: :tavily)

    refute_nil out
    assert_equal "tavily", out[:engine]
    assert_equal 1, out[:results].size
    assert_equal [:tavily], calls, "preferred habilitado + sucesso: nenhum outro provider pode ser chamado"
  end

  # (b) preferred habilitado + HTTP fail (sem retry) → NENHUM outro pago é chamado, retorna nil.
  # `retryable: false` para isolar o teste do retry interno do router — o contrato
  # do specialty é "outros providers NÃO são chamados", não "1 request HTTP".
  def test_specialty_habilitado_http_fail_nao_chama_outro_pago_e_retorna_nil
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post({ tavily: { ok: false, body: nil, reason: "HTTP 401", retryable: false } })

    out = SearchApiRouter.call(query: "última notícia SpaceX agora", specialty: :tavily)

    assert_nil out, "preferred habilitado + fail: deve retornar nil sem cascata"
    assert_equal [:tavily], calls, "preferred habilitado + fail: nenhum outro pago pode ser chamado"
  end

  # (c) preferred habilitado + 200 vazio → NENHUM outro pago é chamado, retorna nil.
  def test_specialty_habilitado_200_vazio_nao_chama_outro_pago_e_retorna_nil
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post({ tavily: { ok: true, body: { "results" => [] }, reason: nil, retryable: false } })

    out = SearchApiRouter.call(query: "última notícia SpaceX agora", specialty: :tavily)

    assert_nil out, "preferred habilitado + 200 vazio: deve retornar nil sem cascata"
    assert_equal [:tavily], calls, "preferred habilitado + 200 vazio: nenhum outro pago pode ser chamado"
  end

  # (d) preferred com cota zerada → degrada para cascata padrão (próximo pago).
    # A cascata padrão (linkup → exa → tavily) é tentada; tavily é PULADO por
    # cota zerada (não chega a chamar). Linkup falha (stub fail) → exa serve.
    def test_specialty_com_cota_zerada_degrada_para_cascata_padrao
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"
      stub_quota_exhausted_only(:tavily)
      stub_increment_quota_noop
      calls = stub_http_post(
        {
          linkup: { ok: false, body: nil, reason: "HTTP 500", retryable: false },
          exa:    { ok: true,  body: { "results" => [{ "title" => "E1", "url" => "https://e1.com", "highlights" => ["x"] }] }, reason: nil, retryable: false }
        }
      )

      out = SearchApiRouter.call(query: "qualquer coisa", specialty: :tavily)

      refute_nil out
      assert_equal "exa", out[:engine], "com tavily em cota zerada, a cascata padrão (linkup→exa→tavily) entra; linkup falha e exa serve"
      assert_equal [:linkup, :exa], calls, "preferred com cota zerada: cascata padrão é tentada; tavily NÃO é chamado (cota)"
    end

    # (d.2) preferred sem chave → degrada para cascata padrão.
    # Sem TAVILY_API_KEY → specialty=:tavily não está habilitado; cascata padrão
    # (linkup → exa) é tentada; tavily some da cascata (sem chave).
    def test_specialty_sem_chave_degrada_para_cascata_padrao
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"
      # Sem TAVILY_API_KEY → specialty=:tavily não está habilitado.
      stub_quota_open
      stub_increment_quota_noop
      calls = stub_http_post(
        {
          linkup: { ok: false, body: nil, reason: "HTTP 500", retryable: false },
          exa:    { ok: true,  body: { "results" => [{ "title" => "E1", "url" => "https://e1.com", "highlights" => ["x"] }] }, reason: nil, retryable: false }
        }
      )

      out = SearchApiRouter.call(query: "qualquer coisa", specialty: :tavily)

      refute_nil out
      assert_equal "exa", out[:engine]
      assert_equal [:linkup, :exa], calls, "preferred sem chave: cascata padrão (linkup→exa) é tentada; tavily NÃO (sem chave)"
    end

  # (e) specialty NÃO é tentado duas vezes em nenhum caminho.
  # Cobre: sucesso no specialty (não re-tenta), fail (não re-tenta), 200 vazio (não re-tenta).
  def test_specialty_nunca_e_tentado_duas_vezes_no_caminho_de_sucesso
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post(
      { tavily: { ok: true, body: { "results" => [{ "title" => "N1", "url" => "https://n1.com", "content" => "c", "score" => 0.95 }], "usage" => { "credits" => 1 } }, reason: nil, retryable: false } }
    )

    SearchApiRouter.call(query: "x", specialty: :tavily)

    assert_equal 1, calls.count(:tavily), "specialty nunca pode ser chamado duas vezes no caminho de sucesso"
  end

  def test_specialty_nunca_e_tentado_duas_vezes_no_caminho_de_fail
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post({ tavily: { ok: false, body: nil, reason: "HTTP 401", retryable: false } })

    SearchApiRouter.call(query: "x", specialty: :tavily)

    assert_equal 1, calls.count(:tavily), "specialty nunca pode ser chamado duas vezes no caminho de fail"
  end

  def test_specialty_nunca_e_tentado_duas_vezes_no_caminho_de_200_vazio
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post({ tavily: { ok: true, body: { "results" => [] }, reason: nil, retryable: false } })

    SearchApiRouter.call(query: "x", specialty: :tavily)

    assert_equal 1, calls.count(:tavily), "specialty nunca pode ser chamado duas vezes no caminho de 200 vazio"
  end

  # (f) auto/sem specialty → cascata padrão legada (comportamento atual preservado).
  def test_sem_specialty_cascata_padrao_legada_intacta
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post(
      { linkup: { ok: true, body: { "results" => [{ "name" => "L1", "url" => "https://l1.com", "content" => "c" }] }, reason: nil, retryable: false } }
    )

    out = SearchApiRouter.call(query: "preço do bitcoin hoje") # factual genérica, sem specialty

    refute_nil out
    assert_equal "linkup", out[:engine]
    assert_equal [:linkup], calls, "sem specialty: linkup é o primeiro da cascata padrão"
  end

  # (f.2) auto/sem specialty + Linkup 200 vazio em query factual → para a cascata e retorna nil
  # (cobre o comportamento legado que NÃO pode quebrar).
  def test_sem_specialty_linkup_200_vazio_factual_generica_retorna_nil_sem_chamar_outros
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post({ linkup: { ok: true, body: { "results" => [] }, reason: nil, retryable: false } })

    out = SearchApiRouter.call(query: "preço do bitcoin hoje")

    assert_nil out, "sem specialty + factual genérica + 200 vazio: deve parar a cascata e retornar nil"
    assert_equal [:linkup], calls, "factual genérica: cascata para no linkup; exa/tavily NÃO podem ser chamados"
  end

  # (f.3) auto/sem specialty + Linkup 200 vazio em query de papers → continua para Exa.
  # (cobre o comportamento legado do specialty_for via regex que NÃO pode quebrar).
  def test_sem_specialty_linkup_200_vazio_em_query_de_papers_continua_para_exa
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
    stub_quota_open
    stub_increment_quota_noop
    calls = stub_http_post(
      {
        linkup: { ok: true, body: { "results" => [] }, reason: nil, retryable: false },
        exa: { ok: true, body: { "results" => [{ "title" => "E1", "url" => "https://e1.com", "highlights" => ["attention"] }] }, reason: nil, retryable: false }
      }
    )

    out = SearchApiRouter.call(query: "papers sobre machine learning")

    refute_nil out
    assert_equal "exa", out[:engine]
    assert_equal [:linkup, :exa], calls, "query de papers: linkup miss → exa (regex de especialidade preservado)"
  end

  # (g) type=news + query com site:reddit.com → plataforma bloqueada.
  # Esse teste trava o comportamento do WebSearchTool: query de plataforma
  # bloqueada não deve chamar o router mesmo com type=news (specialty=:tavily).
  # Cobre a defesa em web_search_tools.rb (`platform_query?` AND a condição de
  # specialty habilitada — uma chamada ao router com specialty=:tavily nesse
  # cenário violaria o contrato de specialty habilitado, que limita a UMA
  # chamada paga, mas a regra aqui é nem essa: plataforma = nem SearXNG OK,
  # nem router pago).
  def test_news_com_site_reddit_bloqueia_router_especialmente_quando_searxng_falha
    Rails.cache.clear
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"

    router_called = false
    orig_call = SearchApiRouter.singleton_class.instance_method(:call)
    SearchApiRouter.singleton_class.send(:define_method, :call) do |**|
      router_called = true
      { results: [{ title: "F", url: "https://f.com", content: "c" }], engine: :tavily, cost: nil }
    end

    tool = WebSearchTool.new
    tool.define_singleton_method(:fetch) { |_q, _l, _tr| nil } # SearXNG falhou

    begin
      res = tool.run(query: "site:reddit.com ruby", type: "news")
      assert_equal :error, res[:status], "platform_query + type=news + SearXNG fora: erro do SearXNG preservado"
      assert_equal "busca indisponível", res[:reason]
      refute router_called, "site:reddit.com bloqueia o router mesmo com type=news (specialty=:tavily)"
    ensure
      SearchApiRouter.singleton_class.send(:define_method, :call, orig_call)
    end
  end
end