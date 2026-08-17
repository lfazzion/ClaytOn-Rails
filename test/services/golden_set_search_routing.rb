# frozen_string_literal: true

# Golden set para roteamento de APIs de busca.
#
# CONTRATO REAL DE PRODUÇÃO:
# - NÃO HÁ classificador regex de texto em produção para escolher provider.
# - A ordem de fallback é SEMPRE fixa: Linkup → Exa → Tavily (SearchApiRouter::PROVIDERS),
#   filtrada pelas chaves presentes via SearchApiRouter.ordered_providers.
# - A única exceção de texto é o HINT DE PLATAFORMA (site:reddit.com, site:x.com, site:twitter.com),
#   que bloqueia o fallback externo no WebSearchTool (retorna nil / router não é chamado).
# - Se o primeiro provider responder HTTP 200 com results=[], a cascata PARA e não cai em fallback.
#
# Cada entrada do golden set define:
# - query: a consulta em português
# - expected_provider: qual API é tentada PRIMEIRO com todas as chaves ativas (nil = plataforma, router bloqueado)
# - reason: justificativa baseada no contrato real (ordem fixa / hint de plataforma)

require_relative "../../app/services/search_api_router"

module GoldenSet
  PLATFORM_PATTERN = /(?:site:reddit\.com|site:x\.com|site:twitter\.com)(?:\s|$)/i

  GOLDEN_SET = [
    # ── Plataformas dedicadas → nil (redirecionar para platform_search / router externo bloqueado) ──
    { query: "site:reddit.com ruby performance", expected_provider: nil,     reason: "Reddit — plataforma dedicada, router externo bloqueado" },
    { query: "site:x.com EXM7777",               expected_provider: nil,     reason: "X — plataforma dedicada, router externo bloqueado" },
    { query: "site:twitter.com typescript",      expected_provider: nil,     reason: "Twitter — plataforma dedicada, router externo bloqueado" },

    # ── Fatos únicos verificáveis → Linkup (1ª tentativa na ordem fixa) ──
    { query: "preço do bitcoin hoje",          expected_provider: :linkup, reason: "fato verificável — 1ª tentativa Linkup (ordem fixa)" },
    { query: "qual o custo da OpenAI em 2025", expected_provider: :linkup, reason: "fato financeiro — 1ª tentativa Linkup (ordem fixa)" },
    { query: "quantos habitantes tem o Japão",  expected_provider: :linkup, reason: "demografia — 1ª tentativa Linkup (ordem fixa)" },

    # ── Corporativo / Empresas → Linkup (1ª tentativa na ordem fixa) ──
    { query: "company profile OpenAI",         expected_provider: :linkup, reason: "corporativo — 1ª tentativa Linkup (ordem fixa, sem regex)" },
    { query: "relatório anual da Apple",       expected_provider: :linkup, reason: "relatório anual — 1ª tentativa Linkup (ordem fixa, sem regex)" },
    { query: "linkedin empresa tech 2025",     expected_provider: :linkup, reason: "termo corporativo — 1ª tentativa Linkup (ordem fixa, sem regex)" },

    # ── Acadêmico / Papers → Linkup (1ª tentativa na ordem fixa; Exa é fallback se Linkup falhar) ──
    { query: "papers sobre machine learning",   expected_provider: :linkup, reason: "acadêmico — 1ª tentativa Linkup (sem regex; Exa é fallback posterior)" },
    { query: "arxiv transformers attention",    expected_provider: :linkup, reason: "arxiv — 1ª tentativa Linkup (sem regex; Exa é fallback posterior)" },
    { query: "pubmed covid vaccine",            expected_provider: :linkup, reason: "pubmed — 1ª tentativa Linkup (sem regex; Exa é fallback posterior)" },

    # ── Conceitual / Explicação → Linkup (1ª tentativa na ordem fixa) ──
    { query: "o que é Ruby on Rails",           expected_provider: :linkup, reason: "conceitual — 1ª tentativa Linkup (ordem fixa, sem regex)" },
    { query: "o que é semelhante a Kubernetes", expected_provider: :linkup, reason: "semântica — 1ª tentativa Linkup (ordem fixa, sem regex)" },

    # ── Código / Lookup técnico → Linkup (1ª tentativa na ordem fixa; Tavily é fallback posterior) ──
    { query: "como instalar rails",             expected_provider: :linkup, reason: "código — 1ª tentativa Linkup (sem regex; Tavily é fallback posterior)" },
    { query: "ruby 3.4 pattern matching",       expected_provider: :linkup, reason: "lookup técnico — 1ª tentativa Linkup (ordem fixa)" },
    { query: "gem install devise",              expected_provider: :linkup, reason: "documentação — 1ª tentativa Linkup (ordem fixa)" }
  ].freeze

  # Determina qual provider deve ser tentado primeiro em produção para uma query.
  #
  # Contrato:
  # 1. Plataforma dedicada (Reddit/X/Twitter) → nil (SearchApiRouter não é chamado)
  # 2. Demais queries → primeiro provider retornado por SearchApiRouter.ordered_providers
  def self.first_attempt_provider(query, **provider_keys)
    q = query.to_s.strip
    return nil if q.match?(PLATFORM_PATTERN)

    keys = provider_keys.empty? ? { linkup: "mock_lk", exa: "mock_ex", tavily: "mock_tv" } : provider_keys
    SearchApiRouter.ordered_providers(**keys).first
  end

  # Verifica se todas as queries do golden set batem com o contrato real.
  # @return [Array<Hash>] lista de falhas (vazia se tudo ok)
  def self.check_golden_set(**provider_keys)
    failures = []
    GOLDEN_SET.each_with_index do |entry, i|
      actual = first_attempt_provider(entry[:query], **provider_keys)
      if actual != entry[:expected_provider]
        failures << {
          index: i,
          query: entry[:query],
          expected: entry[:expected_provider],
          actual: actual,
          reason: entry[:reason]
        }
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
      by_provider: GOLDEN_SET.group_by { |e| e[:expected_provider] }.transform_values(&:size)
    }
  end
end