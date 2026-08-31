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
assert_nil.call("site:reddit.com/r/ruby")
assert_nil.call("www.reddit.com ruby")
assert_nil.call("site:x.com EXM7777")
assert_nil.call("site:x.com/user/foo")
assert_nil.call("site:twitter.com typescript")
assert_nil.call("site:twitter.com/bar")

# ── 2. Todas as demais queries com todas as chaves ativas: 1º pago por especialidade (F4) ──
# F4 do plano-fase2 (30/08/2026): o 1º pago da cascata passou a ser a
# ESPECIALIDADE (quando `specialty_for(query)` casa) — não mais linkup1º
# genérico. PROVIDERS estático intocado. Distribuição:
#   - factual / corporativo (sem regex de especialidade) → linkup 1º
#   - papers / conceitual (regex exa) → exa 1º
#   - lookup / notícia (regex tavily) → tavily 1º
assert_linkup = ->(q) {
  actual = GoldenSet.first_attempt_provider(q)
  if actual == :linkup
    passed += 1
  else
    puts "FAIL: #{q.inspect} → esperado :linkup, recebeu #{actual}"
    failed += 1
  end
}
assert_exa_first_call = ->(q) {
  actual = GoldenSet.first_attempt_provider(q)
  if actual == :exa
    passed += 1
  else
    puts "FAIL: #{q.inspect} → esperado :exa (F4: papers/conceitual), recebeu #{actual}"
    failed += 1
  end
}
assert_tavily_first_call = ->(q) {
  actual = GoldenSet.first_attempt_provider(q)
  if actual == :tavily
    passed += 1
  else
    puts "FAIL: #{q.inspect} → esperado :tavily (F4: lookup/notícia), recebeu #{actual}"
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
# Acadêmico (regex exa — F4)
assert_exa_first_call.call("papers sobre machine learning")
assert_exa_first_call.call("arxiv transformers attention")
assert_exa_first_call.call("pubmed covid vaccine")
# Conceitual (regex exa — F4)
assert_exa_first_call.call("o que é Ruby on Rails")
assert_exa_first_call.call("o que é semelhante a Kubernetes")
# Código / Lookup (regex tavily — F4)
assert_tavily_first_call.call("como instalar rails")
assert_tavily_first_call.call("ruby 3.4 pattern matching")
assert_tavily_first_call.call("gem install devise")
# Notícias (regex tavily — F4 novidade)
assert_tavily_first_call.call("última notícia do SpaceX agora")
assert_tavily_first_call.call("noticias de hoje sobre IA")

# ── 3. Ordem com chaves parciais (sem Linkup → Exa/Tavily conforme especialidade, F4) ──
# F4 do plano-fase2 (30/08/2026): sem linkup a fila = [exa, tavily] e
# `reorder_by_specialty` põe o da especialidade na frente. Papers/conceitual
# → exa 1º; lookup/notícia → tavily 1º. Stubber legado de F3 só
# diferenciava "sem linkup → exa 1º" — hoje é condicional.
assert_exa_first = ->(q) {
  actual = GoldenSet.first_attempt_provider(q, linkup: nil, exa: "ex_key", tavily: "tv_key")
  if actual == :exa
    passed += 1
  else
    puts "FAIL (sem linkup, exa esperava): #{q.inspect} → esperado :exa, recebeu #{actual}"
    failed += 1
  end
}
assert_tavily_first_partial = ->(q) {
  actual = GoldenSet.first_attempt_provider(q, linkup: nil, exa: "ex_key", tavily: "tv_key")
  if actual == :tavily
    passed += 1
  else
    puts "FAIL (sem linkup, tavily esperava): #{q.inspect} → esperado :tavily, recebeu #{actual}"
    failed += 1
  end
}
# Papers/conceitual sem linkup → exa 1º (especialidade)
assert_exa_first.call("papers sobre machine learning")
assert_exa_first.call("o que é Ruby on Rails")
# Lookup/notícia sem linkup → tavily 1º (especialidade, F4)
assert_tavily_first_partial.call("como instalar rails")
assert_tavily_first_partial.call("última notícia do SpaceX agora")

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
# F4 do plano-fase2 (30/08/2026): stats refletem a nova distribuição do
# golden set (23 entries; 7 platforms + 6 linkup + 5 exa + 5 tavily).
# O `on_empty_linkup` agrega TODOS os entries — incluindo os platforms
# com `expected_on_empty_linkup: nil` (eles existem, só não testam cascata).
stats = GoldenSet.golden_stats
expected_stats = {
  total: 23,
  labeled: 16,
  redirected: 7,
  by_provider: { nil => 7, :linkup => 6, :exa => 5, :tavily => 5 },
  on_empty_linkup: { nil => 13, :exa => 5, :tavily => 5 }
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