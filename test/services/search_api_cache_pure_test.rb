# frozen_string_literal: true

# Testes PUROS do SearchApiCache (F3c do plano-fase2) — sem Rails/docker.
#
# Cobre:
#   - Tabela TTL exata do plano-fase2 D2 (replicada verbatim):
#       news → 600s, factual → 10800s, entity/academic → 86400s, code/auto → 900s,
#       vazio (sem tipo / type fora do enum) → 60s.
#       time_range: day → 600, week → 3600, month → 10800, year → 86400.
#       TTL final = min(tipo, time_range); piso 60s.
#   - Key compõe query|limit|time_range|type|provider; provider diferente → key
#     diferente; type diferente → key diferente.
#   - read/write: gravar e ler é roundtrip; TTL vence e read devolve nil.
#   - Não grava erro (:error) nem vazio ([]) — invariante da F3a/F2 mantida.
#
# Roda com `ruby test/services/search_api_cache_pure_test.rb`.

require "minitest/autorun"
require "digest"

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

# `PureMemoryCacheStore` precisa estar disponível em QUALQUER ambiente de
# execução (ruby puro isolado E fan-in Rails) porque o `setup` da classe
# de teste o referencia para substituir `Rails.cache` quando o store real
# (FileStore) não responde a `advance`. Defini-lo dentro de um guard
# `unless Rails.respond_to?(:cache)` quebra no fan-in — `Rails.cache`
# sempre responde (FileStore real) → guard é falso → classe nunca é
# definida → setup explode com NameError. Por isso a classe vive FORA do
# guard; o guard original só controlava a definição de `Rails.cache`,
# que agora é responsabilidade do `setup` da classe de teste.
unless defined?(Rails::PureMemoryCacheStore)
  class Rails::PureMemoryCacheStore
    def initialize
      @data = {}
      # `now` permite simular a passagem do tempo sem `travel` (que é ActiveSupport).
      @now = 0
    end

    def read(key)
      entry = @data[key]
      return nil if entry.nil?

      if entry[:expires_at] && entry[:expires_at] < @now
        @data.delete(key)
        return nil
      end

      entry[:value]
    end

    def write(key, value, expires_in: nil, **_rest)
      ttl = expires_in.to_i
      @data[key] = {
        value: value,
        expires_at: ttl.positive? ? @now + ttl : nil
      }
      true
    end

    def delete(key)
      @data.delete(key)
    end

    def clear
      @data.clear
      @now = 0
    end

    # Test-only knob: avança o relógio interno do cache store para simular
    # expiração sem depender de `travel` do ActiveSupport.
    def advance(seconds)
      @now += seconds
    end
  end
end

# Stub legado de `Rails.cache` para o modo ruby puro isolado (sem Rails
# carregado). No fan-in Rails o método já existe e pertence ao Rails real,
# e a substituição por `PureMemoryCacheStore` é feita no `setup` da
# classe de teste (não aqui, para não contaminar o estado global do
# processo).
unless Rails.respond_to?(:cache) && Rails.cache
  module Rails
    def self.cache
      @pure_cache_instance ||= PureMemoryCacheStore.new
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

require_relative "../../app/services/search_api_cache"

class SearchApiCachePureTest < Minitest::Test
  # Quando rodado dentro do fan-in Rails (`rails test`), `Rails.cache` é o
  # FileStore real, que NÃO responde a `advance`. Os 2 testes de expiração
  # (`test_ttl_expira_*`) precisam avançar o relógio simulado — eles
  # quebrariam com `NoMethodError`. Solução: durante ESTE arquivo de teste,
  # substituir `Rails.cache` pelo `PureMemoryCacheStore` (definido no topo
  # do arquivo) e restaurar o original no teardown. Como cada arquivo de
  # teste roda em sequência dentro do mesmo processo Rails, o teardown é
  # o portão — sem ele, contaminaríamos os testes vizinhos.
  def setup
    @__original_rails_cache = (Rails.respond_to?(:cache) ? Rails.cache : nil)

    if Rails.respond_to?(:cache) && Rails.cache.respond_to?(:advance)
      # Já é um store com `advance` (modo ruby puro isolado, ou se algum
      # outro test_helper já stubou). Só limpa e segue.
      Rails.cache.clear
    else
      # Modo Rails carregado: `Rails.cache` é FileStore (sem `advance`).
      # Substitui pelo nosso store puro para esta classe de teste. A
      # instância é mantida numa variável local capturada pelo closure —
      # se retornássemos `Rails::PureMemoryCacheStore.new` direto, cada
      # chamada (`Rails.cache.read`, `Rails.cache.write`) criaria uma
      # instância nova e o roundtrip quebraria (write em uma, read em outra).
      pure_store = Rails::PureMemoryCacheStore.new
      Rails.singleton_class.send(:define_method, :cache) { pure_store }
    end
  end

  def teardown
    # Restaura o cache original para não contaminar testes vizinhos
    # rodando no mesmo processo Rails.
    if @__original_rails_cache
      captured = @__original_rails_cache
      Rails.singleton_class.send(:define_method, :cache) { captured }
    elsif Rails.respond_to?(:cache)
      Rails.singleton_class.send(:remove_method, :cache)
    end
    @__original_rails_cache = nil
  end

  # ── TTL: tabela plana (sem time_range) ─────────────────────────────────────
  # Espelha plano-fase2 D2. Verbatim.
  def test_ttl_news_e_600_segundos
    assert_equal 600, SearchApiCache.ttl_for(type: "news")
  end

  def test_ttl_factual_e_3_horas_10800
    assert_equal 10_800, SearchApiCache.ttl_for(type: "factual")
  end

  def test_ttl_entity_e_24_horas
    assert_equal 86_400, SearchApiCache.ttl_for(type: "entity")
  end

  def test_ttl_academic_e_24_horas
    assert_equal 86_400, SearchApiCache.ttl_for(type: "academic")
  end

  def test_ttl_code_e_15_minutos
    assert_equal 900, SearchApiCache.ttl_for(type: "code")
  end

  def test_ttl_auto_e_15_minutos
    assert_equal 900, SearchApiCache.ttl_for(type: "auto")
  end

  def test_ttl_nil_e_60_segundos
    assert_equal 60, SearchApiCache.ttl_for(type: nil)
  end

  def test_ttl_vazio_string_e_60_segundos
    assert_equal 60, SearchApiCache.ttl_for(type: "")
  end

  def test_ttl_tipo_invalido_e_60_segundos
    assert_equal 60, SearchApiCache.ttl_for(type: "qualquer-coisa")
  end

  # ── TTL: time_range aperta, nunca alarga ──────────────────────────────────
  def test_ttl_time_range_day_news_aplica_min_600
    # day=600, news=600 → 600
    assert_equal 600, SearchApiCache.ttl_for(type: "news", time_range: "day")
  end

  def test_ttl_time_range_week_entity_aperta_para_3600
    # entity=86400, week=3600 → 3600
    assert_equal 3_600, SearchApiCache.ttl_for(type: "entity", time_range: "week")
  end

  def test_ttl_time_range_year_news_aperta_para_600
    # year=86400, news=600 → 600
    assert_equal 600, SearchApiCache.ttl_for(type: "news", time_range: "year")
  end

  def test_ttl_time_range_month_factual_aperta_para_10800
    # factual=10800, month=10800 → 10800
    assert_equal 10_800, SearchApiCache.ttl_for(type: "factual", time_range: "month")
  end

  def test_ttl_time_range_day_code_aperta_para_600
    # code=900, day=600 → 600 (code maior que day)
    assert_equal 600, SearchApiCache.ttl_for(type: "code", time_range: "day")
  end

  def test_ttl_time_range_year_entity_86400
    # entity=86400, year=86400 → 86400
    assert_equal 86_400, SearchApiCache.ttl_for(type: "entity", time_range: "year")
  end

  def test_ttl_time_range_invalido_e_ignorado
    # time_range fora do enum → sem cap → só o tipo vale
    assert_equal 600, SearchApiCache.ttl_for(type: "news", time_range: "century")
  end

  def test_ttl_tipo_vazio_com_time_range_day_60_segundos
    # tipo vazio = 60s, day = 600s → min = 60s (piso do plano)
    assert_equal 60, SearchApiCache.ttl_for(type: nil, time_range: "day")
  end

  def test_ttl_piso_de_60_segundos_quando_ambos_minimos
    # factual=10800, day=600, tipo vazio=60 → min(10800,600)=600 (piso 60 não aplica se não vazio)
    assert_equal 600, SearchApiCache.ttl_for(type: "factual", time_range: "day")
  end

  # ── Key: composição + diferença por provider e type ────────────────────────
  def test_key_formato_busca_provider_sha1
    key = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    assert_match(/\Asearch:tavily:[a-f0-9]{40}\z/, key)
  end

  def test_key_provider_nil_vira_searxng_rotulo
    # type=auto → provider=nil → cache rotula "searxng" para não cruzar hit
    key = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "auto", provider: nil)
    assert_match(/\Asearch:searxng:[a-f0-9]{40}\z/, key)
  end

  def test_key_provider_diferente_gera_key_diferente
    a = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :exa)
    refute_equal a, b, "provider diferente deve invalidar a key (não cruzar SearXNG vs pago)"
  end

  def test_key_type_diferente_gera_key_diferente
    a = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "entity", provider: :tavily)
    refute_equal a, b, "type diferente deve invalidar a key"
  end

  def test_key_limit_diferente_gera_key_diferente
    a = SearchApiCache.key_for(query: "rails", limit: 3, time_range: nil, type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    refute_equal a, b
  end

  def test_key_time_range_diferente_gera_key_diferente
    a = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "rails", limit: 5, time_range: "day", type: "news", provider: :tavily)
    refute_equal a, b
  end

  def test_key_mesmos_parametros_gera_mesma_key
    a = SearchApiCache.key_for(query: "rails", limit: 5, time_range: "day", type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "rails", limit: 5, time_range: "day", type: "news", provider: :tavily)
    assert_equal a, b
  end

  def test_key_query_diferente_gera_key_diferente
    a = SearchApiCache.key_for(query: "rails", limit: 5, time_range: nil, type: "news", provider: :tavily)
    b = SearchApiCache.key_for(query: "django", limit: 5, time_range: nil, type: "news", provider: :tavily)
    refute_equal a, b
  end

  # ── read/write: roundtrip ──────────────────────────────────────────────────
  def test_write_read_roundtrip
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: [{ title: "t", url: "u", content: "c" }])
    out = SearchApiCache.read(query: "q", limit: 5, time_range: nil, type: "news", provider: :tavily)
    assert_equal [{ title: "t", url: "u", content: "c" }], out
  end

  def test_read_sem_gravacao_devolve_nil
    assert_nil SearchApiCache.read(query: "nao-existe", limit: 5, time_range: nil,
                                   type: "news", provider: :tavily)
  end

  def test_ttl_expira_e_read_devolve_nil
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: [{ url: "u" }])
    # Avança o relógio do cache além do TTL do tipo news (600s).
    # O `PureMemoryCacheStore` instalado no topo do arquivo tem `advance` —
    # chamada direta (sem guard `respond_to?`): se regredir, falhamos aqui,
    # não silenciosamente.
    Rails.cache.advance(700)
    assert_nil SearchApiCache.read(query: "q", limit: 5, time_range: nil,
                                   type: "news", provider: :tavily),
               "TTL de 600s deve expirar após 700s simulados"
  end

  def test_ttl_curto_vence_mais_rapido
    # type=auto (900s) vs time_range=day (600s) → 600s.
    SearchApiCache.write(query: "q", limit: 5, time_range: "day", type: "auto",
                          provider: nil, payload: [{ url: "u" }])
    Rails.cache.advance(400)
    assert_equal [{ url: "u" }],
                 SearchApiCache.read(query: "q", limit: 5, time_range: "day", type: "auto", provider: nil),
                 "dentro do TTL ainda lê"
    Rails.cache.advance(300) # total 700s > 600s
    assert_nil SearchApiCache.read(query: "q", limit: 5, time_range: "day", type: "auto", provider: nil),
               "além do TTL (time_range=day cap=600s) deve expirar"
  end

  # ── Não grava erro nem vazio ───────────────────────────────────────────────
  def test_write_nao_grava_payload_vazio
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: [])
    assert_nil SearchApiCache.read(query: "q", limit: 5, time_range: nil,
                                   type: "news", provider: :tavily),
               "cache vazio não deve ser gravado (decisão F3c: vazio não cacheia)"
  end

  def test_write_nao_grava_payload_nil
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: nil)
    assert_nil SearchApiCache.read(query: "q", limit: 5, time_range: nil,
                                   type: "news", provider: :tavily)
  end

  def test_write_nao_grava_payload_marcado_com_erro
    # O router/web_search_tool pode mandar um envelope {ok: false, results: []}
    # representando erro de payload — gravar isso seria servir um erro congelado.
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: { ok: false, results: [] })
    assert_nil SearchApiCache.read(query: "q", limit: 5, time_range: nil,
                                   type: "news", provider: :tavily),
               "envelope de erro não deve ser cacheado"
  end

  # ── Tipo do payload guardado é normalizado (lista de hashes) ───────────────
  def test_write_aceita_payload_hash_envelopado_em_results
    # O router devolve { results: [...], engine: ... }. O cache guarda só o array.
    payload = [{ title: "t", url: "u", content: "c", engine: "tavily" }]
    SearchApiCache.write(query: "q", limit: 5, time_range: nil, type: "news",
                          provider: :tavily, payload: payload)
    out = SearchApiCache.read(query: "q", limit: 5, time_range: nil,
                               type: "news", provider: :tavily)
    assert_equal 1, out.size
    assert_equal "u", out.first[:url]
  end
end