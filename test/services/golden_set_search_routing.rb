# frozen_string_literal: true

# Golden set para roteamento de APIs de busca.
#
# CONTRATO REAL DE PRODUÇÃO:
# - A ordem de fallback é fixa: Linkup → Exa → Tavily (SearchApiRouter::PROVIDERS),
#   filtrada pelas chaves presentes via SearchApiRouter.ordered_providers.
# - HINT DE PLATAFORMA (Reddit/X/Twitter, incluindo subpaths e www):
#   bloqueia o fallback externo no WebSearchTool (retorna nil / router não é chamado).
# - 200 vazio de um provider = miss da especialidade (incrementa cota).
#   Continua a cascata para o próximo provider SÓ SE a query casar com a especialidade do próximo:
#     - Exa: neural/papers/conceitual (paper|arxiv|pubmed|semelhante|o que é|conceitual|machine learning|pesquisa)
#     - Tavily: lookup técnico (como instalar|gem install|pattern matching|documentação|lookup|instalação)
#     - Factual genérica: para (não gasta cota extra).

require_relative "../../app/services/search_api_router"

# Minimal stubs to load WebSearchTool in pure ruby if needed
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

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Object.new.tap do |l|
        def l.info(*) = nil
        def l.warn(*) = nil
        def l.error(*) = nil
      end
    end
    def self.cache
      @cache ||= Object.new.tap do |c|
        def c.read(*) = nil
        def c.write(*) = nil
        def c.clear = nil
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

module GoldenSet
  PLATFORM_PATTERN = WebSearchTool::PLATFORM_FALLBACK_BLOCK_PATTERN

  GOLDEN_SET = [
    # ── Plataformas dedicadas → nil (redirecionar para platform_search / router externo bloqueado) ──
    { query: "site:reddit.com ruby performance", expected_provider: nil,     expected_on_empty_linkup: nil, reason: "Reddit — plataforma dedicada, router bloqueado" },
    { query: "site:reddit.com/r/ruby",           expected_provider: nil,     expected_on_empty_linkup: nil, reason: "Reddit subpath — plataforma dedicada, router bloqueado" },
    { query: "www.reddit.com ruby",              expected_provider: nil,     expected_on_empty_linkup: nil, reason: "Reddit www — plataforma dedicada, router bloqueado" },
    { query: "site:x.com EXM7777",               expected_provider: nil,     expected_on_empty_linkup: nil, reason: "X — plataforma dedicada, router bloqueado" },
    { query: "site:x.com/user/foo",              expected_provider: nil,     expected_on_empty_linkup: nil, reason: "X subpath — plataforma dedicada, router bloqueado" },
    { query: "site:twitter.com typescript",      expected_provider: nil,     expected_on_empty_linkup: nil, reason: "Twitter — plataforma dedicada, router bloqueado" },
    { query: "site:twitter.com/bar",             expected_provider: nil,     expected_on_empty_linkup: nil, reason: "Twitter subpath — plataforma dedicada, router bloqueado" },

    # ── Fatos únicos verificáveis → 1ª tentativa Linkup; após 200 vazio PARA (nil) ──
    { query: "preço do bitcoin hoje",          expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "fato verificável — 1ª tentativa Linkup; para em 200 vazio" },
    { query: "qual o custo da OpenAI em 2025", expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "fato financeiro — 1ª tentativa Linkup; para em 200 vazio" },
    { query: "quantos habitantes tem o Japão",  expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "demografia — 1ª tentativa Linkup; para em 200 vazio" },

    # ── Corporativo / Empresas → 1ª tentativa Linkup; após 200 vazio PARA (nil) ──
    { query: "company profile OpenAI",         expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "corporativo — 1ª tentativa Linkup; para em 200 vazio" },
    { query: "relatório anual da Apple",       expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "relatório anual — 1ª tentativa Linkup; para em 200 vazio" },
    { query: "linkedin empresa tech 2025",     expected_provider: :linkup, expected_on_empty_linkup: nil, reason: "termo corporativo — 1ª tentativa Linkup; para em 200 vazio" },

    # ── Acadêmico / Papers / Neural → 1ª tentativa Linkup; após 200 vazio CONTINUA para Exa ──
    { query: "papers sobre machine learning",   expected_provider: :linkup, expected_on_empty_linkup: :exa, reason: "acadêmico/papers — 1ª tentativa Linkup; continua para Exa em 200 vazio" },
    { query: "arxiv transformers attention",    expected_provider: :linkup, expected_on_empty_linkup: :exa, reason: "arxiv — 1ª tentativa Linkup; continua para Exa em 200 vazio" },
    { query: "pubmed covid vaccine",            expected_provider: :linkup, expected_on_empty_linkup: :exa, reason: "pubmed — 1ª tentativa Linkup; continua para Exa em 200 vazio" },

    # ── Conceitual / Explicação → 1ª tentativa Linkup; após 200 vazio CONTINUA para Exa ──
    { query: "o que é Ruby on Rails",           expected_provider: :linkup, expected_on_empty_linkup: :exa, reason: "conceitual — 1ª tentativa Linkup; continua para Exa em 200 vazio" },
    { query: "o que é semelhante a Kubernetes", expected_provider: :linkup, expected_on_empty_linkup: :exa, reason: "semântica — 1ª tentativa Linkup; continua para Exa em 200 vazio" },

    # ── Código / Lookup técnico → 1ª tentativa Linkup; após 200 vazio CONTINUA para Tavily ──
    { query: "como instalar rails",             expected_provider: :linkup, expected_on_empty_linkup: :tavily, reason: "código/lookup — 1ª tentativa Linkup; continua para Tavily em 200 vazio" },
    { query: "ruby 3.4 pattern matching",       expected_provider: :linkup, expected_on_empty_linkup: :tavily, reason: "lookup técnico — 1ª tentativa Linkup; continua para Tavily em 200 vazio" },
    { query: "gem install devise",              expected_provider: :linkup, expected_on_empty_linkup: :tavily, reason: "documentação — 1ª tentativa Linkup; continua para Tavily em 200 vazio" }
  ].freeze

  # Determina qual provider deve ser tentado primeiro em produção para uma query.
  def self.first_attempt_provider(query, **provider_keys)
    q = query.to_s.strip
    return nil if q.match?(PLATFORM_PATTERN)

    keys = provider_keys.empty? ? { linkup: "mock_lk", exa: "mock_ex", tavily: "mock_tv" } : provider_keys
    SearchApiRouter.ordered_providers(**keys).first
  end

  # Simula execução real de SearchApiRouter.call quando o primeiro provider (Linkup) retorna 200 vazio.
  # @return [Symbol, nil] provider final que serviu a busca (:exa, :tavily) ou nil se parou/falhou.
  def self.simulate_empty_linkup_cascade(query)
    saved_http_post = SearchApiRouter.singleton_class.instance_method(:http_post)
    saved_increment = SearchApiRouter.singleton_class.instance_method(:increment_quota)

    provider_used = nil
    SearchApiRouter.singleton_class.send(:define_method, :increment_quota) { |_p| }
    SearchApiRouter.singleton_class.send(:define_method, :http_post) do |provider, _q, _l, _tf|
      if provider == :linkup
        { ok: true, body: { "results" => [] }, reason: nil, retryable: false }
      else
        provider_used = provider
        { ok: true, body: { "results" => [{ "title" => "R", "url" => "https://r.com", "content" => "c", "score" => 0.9 }] }, reason: nil, retryable: false }
      end
    end

    orig_tv = ENV["TAVILY_API_KEY"]
    orig_ex = ENV["EXA_API_KEY"]
    orig_lk = ENV["LINKUP_API_KEY"]
    begin
      ENV["TAVILY_API_KEY"] = "tv"
      ENV["EXA_API_KEY"] = "ex"
      ENV["LINKUP_API_KEY"] = "lk"

      res = SearchApiRouter.call(query: query, limit: 5)
      res ? res[:engine]&.to_sym : nil
    ensure
      ENV["TAVILY_API_KEY"] = orig_tv
      ENV["EXA_API_KEY"] = orig_ex
      ENV["LINKUP_API_KEY"] = orig_lk
      SearchApiRouter.singleton_class.send(:define_method, :http_post, saved_http_post)
      SearchApiRouter.singleton_class.send(:define_method, :increment_quota, saved_increment)
    end
  end

  # Verifica se todas as queries do golden set batem com o contrato real:
  # 1. first_attempt_provider (primeira tentativa / bloqueio de plataforma)
  # 2. cascata real sob Linkup 200 vazio (continua por especialidade ou para)
  # @return [Array<Hash>] lista de falhas (vazia se tudo ok)
  def self.check_golden_set(**provider_keys)
    failures = []
    GOLDEN_SET.each_with_index do |entry, i|
      actual_first = first_attempt_provider(entry[:query], **provider_keys)
      if actual_first != entry[:expected_provider]
        failures << {
          index: i,
          type: :first_attempt,
          query: entry[:query],
          expected: entry[:expected_provider],
          actual: actual_first,
          reason: entry[:reason]
        }
      end

      # Testa a cascata real se a query não for bloqueada como plataforma
      if entry[:expected_provider]
        actual_cascade = simulate_empty_linkup_cascade(entry[:query])
        if actual_cascade != entry[:expected_on_empty_linkup]
          failures << {
            index: i,
            type: :empty_linkup_cascade,
            query: entry[:query],
            expected: entry[:expected_on_empty_linkup],
            actual: actual_cascade,
            reason: entry[:reason]
          }
        end
      end
    end
    failures
  end

  # Estatísticas do golden set com todas as chaves presentes.
  def self.golden_stats
    total = GOLDEN_SET.size
    labeled = GOLDEN_SET.count { |e| e[:expected_provider] }
    redirected = GOLDEN_SET.count { |e| e[:expected_provider].nil? }
    {
      total: total,
      labeled: labeled,
      redirected: redirected,
      by_provider: GOLDEN_SET.group_by { |e| e[:expected_provider] }.transform_values(&:size),
      on_empty_linkup: GOLDEN_SET.group_by { |e| e[:expected_on_empty_linkup] }.transform_values(&:size)
    }
  end
end