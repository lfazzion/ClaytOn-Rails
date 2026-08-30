# frozen_string_literal: true

# Testes PUROS do SearchApiQuota para F3b (origem + piso 5% pro bot).
# Mesma estratégia do test/services/search_api_quota_test.rb: AR + sqlite
# in-memory, sem Rails, sem Docker. Roda com:
#
#   ruby test/services/search_api_quota_f3b_pure_test.rb
#
# Contrato canônico F3b D1 (plano-fase2 L31, aceite F3b L109):
# "Piso dos últimos 5%" — RESERVA, não overage. Teto único NUNCA passa
# de `ceiling`. Discord (o bot) tem acesso aos últimos 5% da cota; MCP e
# demais origens param aos 95%. Kill-switch (ceiling <= 0) fecha TODOS.
#
# Regras cravadas pelos testes abaixo:
#   ceiling <= 0             → false SEMPRE (kill-switch, inclusive :discord)
#   origin != :discord       → false quando count >= ceiling - bot_floor_size(ceiling)
#                              (MCP/legado param aos 95% do teto;
#                              teto=100 → mcp_limit=95; teto=10 → mcp_limit=10;
#                              teto=5 → mcp_limit=5, floor_size=0;
#                              teto=1 → mcp_limit=1)
#   origin == :discord       → false SÓ com count >= ceiling (sem overage)
#   count NUNCA > ceiling    → regra absoluta do plano
#
# A coluna `count_discord` é observabilidade: sobe junto com `count` para
# alimentar o dashboard F8. NÃO é segundo teto.

require "minitest/autorun"
require "active_record"
require "active_support"
require "sqlite3"

unless defined?(ApplicationRecord)
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end

require_relative "../../app/models/search_api_quota"

class SearchApiQuotaF3bPureTest < Minitest::Test
  def setup
    unless ActiveRecord::Base.connected?
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    end

    unless ActiveRecord::Base.connection.table_exists?(:search_api_quotas)
      ActiveRecord::Schema.define do
        create_table :search_api_quotas, force: true do |t|
          t.string :api_name, null: false
          t.string :month, null: false
          t.integer :count, null: false, default: 0
          # F3b: origem opcional na linha canônica. Quando nil, é a linha
          # "sem origem" que faz o teto (mantemos o índice único). Não criamos
          # linhas separadas por origem — colunas de contador cobrem isso.
          t.string :origin
          t.integer :count_discord, null: false, default: 0
          t.integer :count_mcp, null: false, default: 0
          t.timestamps
          t.index %i[api_name month], name: "index_search_api_quotas_on_api_name_and_month", unique: true
        end
      end
    end

    SearchApiQuota.delete_all if ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?(:search_api_quotas)
  end

  def teardown
    SearchApiQuota.delete_all if ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?(:search_api_quotas)
  end

  # ── Schema / defaults ──────────────────────────────────────────────────────
  def test_count_discord_e_count_mcp_default_zero_em_linha_nova
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  def test_origin_default_nil
    rec = SearchApiQuota.create!(api_name: "tavily", month: "2026-08")
    assert_nil rec.origin
  end

  def test_count_discord_e_count_mcp_sao_atributos_publicos
    rec = SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count_discord: 7, count_mcp: 3)
    assert_equal 7, rec.count_discord
    assert_equal 3, rec.count_mcp
  end

  # ── Métrica por origem (count_mcp / count_discord) ─────────────────────────
  def test_reserve_com_origin_mcp_incrementa_count_mcp
    SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :mcp)
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 1, rec.count, "count (teto principal) sempre incrementa"
    assert_equal 1, rec.count_mcp, "count_mcp sobe quando origin=:mcp"
    assert_equal 0, rec.count_discord, "count_discord não se mexe quando origin=:mcp"
  end

  def test_reserve_com_origin_discord_incrementa_count_discord
    SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :discord)
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 1, rec.count
    assert_equal 1, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  def test_reserve_sem_origin_nao_toca_contadores_de_origem
    SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 1, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── Regra D1 canônica: teto + reserva dos últimos 5% ──────────────────────
  # ceiling=100, count=95, origin=:mcp → FALSE (MCP para aos 95)
  def test_mcp_recusa_aos_95_porcento_do_teto
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 95)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :mcp)
    refute ok, "MCP com count=95 >= mcp_limit(95) → recusa"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 95, rec.count, "count NÃO incrementa quando MCP recusa"
    assert_equal 0, rec.count_mcp, "count_mcp NÃO incrementa quando MCP recusa"
  end

  # ceiling=100, count=94, origin=:mcp → TRUE (94 < 95, MCP ainda reserva)
  def test_mcp_abaixo_do_95_porcento_ainda_reserva
    SearchApiQuota.create!(api_name: "linkup", month: "2026-08", count: 94)
    ok = SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08", origin: :mcp)
    assert ok, "MCP com count=94 < mcp_limit(95) → reserva"
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 95, rec.count
    assert_equal 1, rec.count_mcp
  end

  # ceiling=100, count=95, origin=:discord → TRUE (reserva o 96º)
  def test_discord_reserva_no_piso_95_ate_100
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 95)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    assert ok, "Discord com count=95 < ceiling=100 → reserva (96º, dentro do piso)"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 96, rec.count
    assert_equal 1, rec.count_discord
  end

  # origin=nil ≡ mcp: para aos 95% igualzinho
  def test_origin_nil_recusa_aos_95_igual_mcp
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 95)
    ok = SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: nil)
    refute ok, "origin=nil ≡ :mcp no gate; recusa quando count=95 >= mcp_limit=95"
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 95, rec.count
    assert_equal 0, rec.count_mcp, "origin=nil não incrementa coluna de origem"
  end

  # ceiling=100, count=99, origin=:discord → TRUE (vai pro 100); count=100 → FALSE
  def test_discord_reserva_ate_ceiling_e_recusa_em_count_igual_ceiling
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 99)
    ok1 = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    assert ok1, "count=99 < ceiling=100 → reserva (vai a 100)"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 100, rec.count
    assert_equal 1, rec.count_discord

    ok2 = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    refute ok2, "count=100 >= ceiling=100 → recusa (teto cheio, sem overage)"
    rec.reload
    assert_equal 100, rec.count, "count NUNCA passa de ceiling — sem overage"
    assert_equal 1, rec.count_discord, "count_discord NÃO incrementa em recusa"
  end

  # ceiling=0 → FALSE pra TODOS (kill-switch fecha o bot inclusive)
  def test_kill_switch_ceiling_zero_bloqueia_discord
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 0, month: "2026-08", origin: :discord)
    refute ok, "ceiling=0 é kill-switch; discord não escapa"
    # Nenhuma linha deve ter sido criada (early-return antes do transaction).
    refute SearchApiQuota.find_by(api_name: "tavily", month: "2026-08"),
           "ceiling=0 → não cria registro (early-return antes do transaction)"
  end

  def test_kill_switch_ceiling_zero_bloqueia_mcp_e_nil
    # `[:mcp, nil]` em vez de `%i[mcp nil]`: o `%i` cria símbolo `:nil`
    # (que conflita com `nil`), poluindo o assert e confundindo leitora.
    [ :mcp, nil ].each do |origin|
      ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 0, month: "2026-08", origin: origin)
      refute ok, "ceiling=0 bloqueia #{origin.inspect} também"
    end
  end

  def test_kill_switch_ceiling_negativo_bloqueia
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: -1, month: "2026-08", origin: :discord)
    refute ok
  end

  # ── Borda: tetos pequenos (1-2). `max(0, ...)` evita piso negativo ────────
  def test_ceiling_2_discord_para_no_teto_unico_sem_reserva_de_piso
    # mcp_limit = ceiling - bot_floor_size(2) = 2 - max(0, floor(0.10)) = 2 - 0 = 2
    # Discord com count=1 → reserva normal (count vai a 2).
    # Discord com count=2 → recusa (count >= ceiling).
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 1)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 2, month: "2026-08", origin: :discord)
    assert ok, "count=1 < ceiling=2 → reserva normal"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 2, rec.count
    assert_equal 1, rec.count_discord

    ok2 = SearchApiQuota.reserve_quota!("tavily", ceiling: 2, month: "2026-08", origin: :discord)
    refute ok2, "count=2 >= ceiling=2 → recusa (teto cheio)"
  end

  def test_ceiling_1_discord_para_no_teto_unico
    # mcp_limit = ceiling - bot_floor_size(1) = 1 - max(0, floor(0.05)) = 1 - 0 = 1
    # Discord com count=0 → reserva (vai a 1). count=1 → recusa.
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 0)
    ok = SearchApiQuota.reserve_quota!("exa", ceiling: 1, month: "2026-08", origin: :discord)
    assert ok
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 1, rec.count

    ok2 = SearchApiQuota.reserve_quota!("exa", ceiling: 1, month: "2026-08", origin: :discord)
    refute ok2
  end

  # ── Legado F3a: reserve sem origin com ceiling=10 (regressão) ──────────────
  # Brief v8: "ceiling=10, origin=nil → count=0 TRUE e count=10 FALSE".
  # bot_floor_size(10) = max(0, floor(10*0.05)) = max(0, 0) = 0;
  # mcp_limit = 10 - 0 = 10. Sem origin ≡ :mcp no gate.
  def test_legado_reserve_sem_origin_ceiling_10_count_0_reserva
    SearchApiQuota.reserve_quota!("legacy_api", ceiling: 10, month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "legacy_api", month: "2026-08")
    assert_equal 1, rec.count, "ceiling=10, count=0 < mcp_limit=10 → reserva"
  end

  def test_legado_reserve_sem_origin_ceiling_10_count_10_recusa
    SearchApiQuota.create!(api_name: "legacy_full", month: "2026-08", count: 10)
    ok = SearchApiQuota.reserve_quota!("legacy_full", ceiling: 10, month: "2026-08")
    refute ok, "ceiling=10, count=10 >= mcp_limit=10 → recusa (legado F3a volta a passar)"
    rec = SearchApiQuota.find_by(api_name: "legacy_full", month: "2026-08")
    assert_equal 10, rec.count, "count NÃO incrementa em recusa"
  end

  # ── MCP reserva enquanto count < mcp_limit ────────────────────────────────
  def test_mcp_reserva_normalmente_abaixo_do_95_porcento
    # ceiling=100, mcp_limit=ceiling - bot_floor_size = 100 - 5 = 95.
    # MCP com count=4 → reserva (vai a 5).
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 4)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :mcp)
    assert ok, "MCP com count=4 < mcp_limit(95) → reserva"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 5, rec.count
    assert_equal 1, rec.count_mcp
  end

  # ── Regressão do contrato legado (reserve sem origin) ──────────────────────
  def test_contrato_legado_reserve_sem_origin_continua_funcionando
    3.times { SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08") }
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 3, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  def test_contrato_legado_reserve_sem_origin_para_no_teto
    # Sem origin = mcp no gate. ceiling=100, count=95 → recusa.
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 95)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08")
    refute ok, "reserve sem origin ≡ mcp: para aos 95%"
  end

  # ── Rollback (métrica + count) ─────────────────────────────────────────────
  def test_rollback_quota_reverte_count_e_count_discord
    SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    rec_before = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 1, rec_before.count
    assert_equal 1, rec_before.count_discord

    SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord)
    rec_after = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 0, rec_after.count
    assert_equal 0, rec_after.count_discord
  end

  def test_rollback_quota_reverte_count_e_count_mcp
    SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :mcp)
    SearchApiQuota.rollback_quota!("exa", month: "2026-08", origin: :mcp)
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 0, rec.count
    assert_equal 0, rec.count_mcp
  end

  def test_rollback_quota_sem_origin_reverte_apenas_count
    SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08")
    SearchApiQuota.rollback_quota!("linkup", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 0, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  def test_rollback_com_count_discord_zero_e_noop
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 5, count_discord: 0)
    SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord)
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 5, rec.count
    assert_equal 0, rec.count_discord
  end

  def test_rollback_multiplo_sem_reserva_nao_vai_negativo
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 0)
    3.times { SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord) }
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 0, rec.count
    assert_equal 0, rec.count_discord
  end

  # ── exceeded_with_origin? (regra canônica do fast-path) ────────────────────
  def test_exceeded_with_origin_kill_switch_ceiling_zero
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 0, month: "2026-08", origin: :discord
    )
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 0, month: "2026-08", origin: :mcp
    )
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 0, month: "2026-08", origin: nil
    )
  end

  def test_exceeded_with_origin_mcp_bloqueia_em_count_95
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 95)
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 100, month: "2026-08", origin: :mcp
    ), "MCP/legado com count=95 >= mcp_limit=95 → exceeded"
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 100, month: "2026-08", origin: nil
    ), "origin=nil ≡ :mcp no gate"
  end

  def test_exceeded_with_origin_mcp_libera_abaixo_do_95
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 4)
    assert_equal false, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 100, month: "2026-08", origin: :mcp
    ), "count=4 < mcp_limit=95 → NÃO exceeded"
  end

  def test_exceeded_with_origin_discord_bloqueia_so_no_teto
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 99)
    assert_equal false, SearchApiQuota.exceeded_with_origin?(
      "tavily", ceiling: 100, month: "2026-08", origin: :discord
    ), "Discord com count=99 < ceiling=100 → reserva o 100º (não exceeded)"

    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 100)
    assert_equal true, SearchApiQuota.exceeded_with_origin?(
      "exa", ceiling: 100, month: "2026-08", origin: :discord
    ), "Discord com count=100 >= ceiling=100 → exceeded (sem overage)"
  end

  def test_exceeded_with_origin_sem_row_nao_bloqueia_quando_count_zero
    SearchApiQuota.where(api_name: "new_api", month: "2026-08").delete_all
    assert_equal false, SearchApiQuota.exceeded_with_origin?(
      "new_api", ceiling: 100, month: "2026-08", origin: :discord
    ), "linha inexistente + ceiling>0 → não exceeded (pode criar)"
  end

  # ── Sanity: count nunca ultrapassa ceiling ────────────────────────────────
  def test_count_nunca_passa_de_ceiling_em_qualquer_caminho
    api = "ceiling_guard"
    SearchApiQuota.where(api_name: api, month: "2026-08").delete_all
    50.times do
      SearchApiQuota.reserve_quota!(api, ceiling: 100, month: "2026-08", origin: :discord)
    end
    rec = SearchApiQuota.find_by(api_name: api, month: "2026-08")
    assert rec.count <= 100, "count=#{rec.count} violou o teto (sem overage)"
    assert_equal 50, rec.count, "50 reservas com count<ceiling → count=50"
    assert_equal 50, rec.count_discord, "count_discord sobe junto com count"
  end
end
