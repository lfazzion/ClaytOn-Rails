# frozen_string_literal: true

# Testes do golden set de roteamento de APIs de busca.
#
# Ruby puro — sem Rails, sem test_helper. Roda com:
#   ruby test/services/golden_set_search_routing_check.rb
#
# Cobertura do contrato real:
# - Queries de plataforma (Reddit/X/Twitter) → nil (router não é chamado)
# - Queries gerais/papers/código/corporativo → primeiro provider da ordem fixa (Linkup se houver chave)
# - Ordem dinâmica ao mudar chaves presentes (Linkup ausente → Exa; Exa ausente → Tavily)
# - check_golden_set retorna vazio (0 falhas)
# - golden_stats reflete a distribuição real

require_relative "golden_set_search_routing"

passed = 0
failed = 0

# ── 1. Plataformas dedicadas → nil (redirecionar para platform_search) ────────
assert_nil = ->(q) {
  actual = GoldenSet.first_attempt_provider(q)
  if actual.nil?
    passed += 1
  else
    puts "FAIL: #{q.inspect} → esperado nil, recebeu #{actual}"
    failed += 1
  end
}
assert_nil.call("site:reddit.com ruby performance")
assert_nil.call("site:x.com EXM7777")
assert_nil.call("site:twitter.com typescript")

# ── 2. Todas as demais queries com todas as chaves ativas → :linkup (ordem fixa) ──
assert_linkup = ->(q) {
  actual = GoldenSet.first_attempt_provider(q)
  if actual == :linkup
    passed += 1
  else
    puts "FAIL: #{q.inspect} → esperado :linkup, recebeu #{actual}"
    failed += 1
  end
}
# Fatos
assert_linkup.call("preço do bitcoin hoje")
assert_linkup.call("qual o custo da OpenAI em 2025")
assert_linkup.call("quantos habitantes tem o Japão")
# Corporativo
assert_linkup.call("company profile OpenAI")
assert_linkup.call("relatório anual da Apple")
assert_linkup.call("linkedin empresa tech 2025")
# Acadêmico (sem classificador regex — Linkup é tentado primeiro em produção)
assert_linkup.call("papers sobre machine learning")
assert_linkup.call("arxiv transformers attention")
assert_linkup.call("pubmed covid vaccine")
# Conceitual (sem classificador regex)
assert_linkup.call("o que é Ruby on Rails")
assert_linkup.call("o que é semelhante a Kubernetes")
# Código / Lookup (sem classificador regex)
assert_linkup.call("como instalar rails")
assert_linkup.call("ruby 3.4 pattern matching")
assert_linkup.call("gem install devise")

# ── 3. Ordem com chaves parciais (sem Linkup → Exa é primeiro) ───────────────
assert_exa_first = ->(q) {
  actual = GoldenSet.first_attempt_provider(q, linkup: nil, exa: "ex_key", tavily: "tv_key")
  if actual == :exa
    passed += 1
  else
    puts "FAIL (sem linkup): #{q.inspect} → esperado :exa, recebeu #{actual}"
    failed += 1
  end
}
assert_exa_first.call("papers sobre machine learning")
assert_exa_first.call("como instalar rails")

# ── 4. Ordem com apenas Tavily ───────────────────────────────────────────────
assert_tavily_first = ->(q) {
  actual = GoldenSet.first_attempt_provider(q, linkup: nil, exa: nil, tavily: "tv_key")
  if actual == :tavily
    passed += 1
  else
    puts "FAIL (apenas tavily): #{q.inspect} → esperado :tavily, recebeu #{actual}"
    failed += 1
  end
}
assert_tavily_first.call("preço do bitcoin hoje")
assert_tavily_first.call("arxiv transformers attention")

# ── 5. check_golden_set ──────────────────────────────────────────────────────
failures = GoldenSet.check_golden_set
if failures.empty?
  passed += 1
else
  puts "FAIL: check_golden_set retornou #{failures.size} falha(s)"
  failures.each { |f| puts "  - #{f[:query]}: esperado #{f[:expected]}, recebeu #{f[:actual]}" }
  failed += 1
end

# ── 6. golden_stats ──────────────────────────────────────────────────────────
stats = GoldenSet.golden_stats
expected_stats = {
  total: 17,
  labeled: 14,
  redirected: 3,
  by_provider: { linkup: 14, nil => 3 }
}
if stats == expected_stats
  passed += 1
else
  puts "FAIL: golden_stats incorreto"
  puts "  esperado: #{expected_stats.inspect}"
  puts "  recebeu:  #{stats.inspect}"
  failed += 1
end

# ── Resultado ────────────────────────────────────────────────────────────────
puts "\n=== Golden Set Test ==="
puts "Passed: #{passed}"
puts "Failed: #{failed}"
puts failed.zero? ? "ALL GREEN ✅" : "SOME FAILURES ❌"
exit(failed.zero? ? 0 : 1)