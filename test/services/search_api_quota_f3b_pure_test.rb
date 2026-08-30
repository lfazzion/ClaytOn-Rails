# frozen_string_literal: true

# Testes PUROS do SearchApiQuota para F3b (origem + piso 5% pro bot).
# Mesma estratégia do test/services/search_api_quota_test.rb: AR + sqlite
# in-memory, sem Rails, sem Docker. Roda com:
#
#   ruby test/services/search_api_quota_f3b_pure_test.rb
#
# O ponto central é blindar:
#  - coluna origin opcional na linha canônica (api_name, month)
#  - colunas count_discord / count_mcp (métrica, não segundo teto)
#  - reserva atômica incrementa o contador de origem certo
#  - rollback reverte o contador de origem certo
#  - piso 5% pro bot (origin=discord) — único caso que continua reservando
#    quando o teto principal está cheio
#  - demais origins (mcp / nil) seguem o teto único intacto
#  - teto único segue intacto (caminho legado passa idêntico)

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

  # ── F3b D1: migration trouxe count_discord e count_mcp como inteiros default 0 ─
  def test_count_discord_e_count_mcp_default_zero_em_linha_nova
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── F3b D1: origem é opcional e default nil ────────────────────────────────
  def test_origin_default_nil
    rec = SearchApiQuota.create!(api_name: "tavily", month: "2026-08")
    assert_nil rec.origin
  end

  # ── F3b métrica: reserve com origin=:mcp incrementa count_mcp ───────────────
  def test_reserve_com_origin_mcp_incrementa_count_mcp
    SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :mcp)
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 1, rec.count, "count (teto principal) sempre incrementa"
    assert_equal 1, rec.count_mcp, "count_mcp sobe quando origin=:mcp"
    assert_equal 0, rec.count_discord, "count_discord não se mexe quando origin=:mcp"
  end

  # ── F3b métrica: reserve com origin=:discord incrementa count_discord ──────
  def test_reserve_com_origin_discord_incrementa_count_discord
    SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :discord)
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 1, rec.count
    assert_equal 1, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── F3b métrica: reserve sem origin (nil) NÃO toca contadores de origem ────
  def test_reserve_sem_origin_nao_toca_contadores_de_origem
    SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 1, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── F3b D1 piso: discord no teto principal ainda reserva do piso 5% ────────
  # ceiling=100, count=100 (teto fechado). Discord reserva o 101º a 105º.
  # floor(100 * 0.05) = 5 → max(1, 5) = 5. count_discord antes do reserve = 0.
  #
  # Por que count=100 e não 95? O brief diz "teto único intacto", e a
  # decisão D1 do plano-fase2 é "um teto só". O piso só vale quando o teto
  # principal ESTÁ fechado (count >= ceiling). Discord tem EXCEÇÃO ao teto
  # para consumir os últimos 5% — não um segundo teto com margem de 95%.
  def test_piso_discord_no_teto_principal_permite_reserva_ate_5_chamadas
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 100)

    5.times do |i|
      ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
      assert ok, "reserva #{i + 1} do piso discord (count_discord sobe de #{i} para #{i + 1}) deve passar"
    end

    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 105, rec.count, "count final = 100 + 5 reservas do piso = 105"
    assert_equal 5, rec.count_discord
  end

  # ── F3b D1 piso: discord NÃO pode passar do piso (estouro do piso = recusa) ─
  # 6ª chamada discord: count_discord=5 já no piso, recusa.
  def test_piso_discord_apos_5_chamadas_no_piso_recusa
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 100, count_discord: 5)

    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    refute ok, "6ª chamada discord com count_discord=5 (= piso) deve recusar"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 100, rec.count, "count NÃO incrementa quando piso recusa"
    assert_equal 5, rec.count_discord, "count_discord NÃO incrementa quando piso recusa"
  end

  # ── F3b D1 piso: count=99 (ainda 1% do teto) → piso NÃO foi tocado, reserva normal
  # O piso só ativa quando count >= ceiling. Discord com count=99 entra no
  # caminho "teto principal tem espaço" e reserva normalmente, indo a 100.
  # Daí em diante o piso começa a contar.
  def test_discord_com_count_99_ainda_no_teto_principal_reserva_normal
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 99)

    ok = SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :discord)
    assert ok, "count=99 < ceiling=100 → reserva normal (count_discord sobe junto)"
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 100, rec.count
    assert_equal 1, rec.count_discord
  end

  # ── F3b D1 piso: teto cheio + count_discord já no piso → recusa ───────────
  def test_piso_discord_count_discord_ja_no_piso_recusa_desde_a_primeira
    SearchApiQuota.create!(api_name: "linkup", month: "2026-08", count: 100, count_discord: 5)

    ok = SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08", origin: :discord)
    refute ok, "count_discord=5 (= piso) e count=100 → discord não reserva"
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 100, rec.count
    assert_equal 5, rec.count_discord
  end

  # ── F3b D1 piso: mcp NÃO tem piso — teto principal intacto ──────────────────
  # ceiling=100, count=100 (teto fechado) → mcp recusa.
  # Versão mais direta do "mcp recusa quando teto fechado":
  def test_mcp_recusa_quando_count_atinge_ceiling
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 100)

    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :mcp)
    refute ok, "mcp NÃO tem piso — teto principal fechado = recusa"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 100, rec.count, "count NÃO mexe quando mcp recusa"
    assert_equal 0, rec.count_mcp
  end

  # ── F3b D1 piso: discord NO TETO PRINCIPAL ESTOURADO MAS count_discord zero
  #    ainda tem piso disponível → discord reserva do piso. Esse é o caso
  #    crítico do plano: "campanha do perfil gastou quase tudo" (count > ceiling,
  #    count_discord=0) e o bot AINDA pode gastar até o piso. Só recusa quando
  #    o próprio count_discord atinge o piso (=5).
  def test_discord_reserva_piso_com_count_maior_que_ceiling_e_count_discord_zero
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 110, count_discord: 0)

    ok = SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :discord)
    assert ok, "count_discord=0 < piso=5 → discord reserva DO PISO mesmo com count > ceiling"
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 111, rec.count
    assert_equal 1, rec.count_discord
  end

  # ── F3b D1 piso: discord NO TETO PRINCIPAL ESTOURADO com count_discord já
  #    no piso → recusa (piso esgotado, mesmo com count estourado).
  def test_discord_recusa_quando_count_discord_no_piso_e_count_estourado
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 110, count_discord: 5)

    ok = SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :discord)
    refute ok, "count_discord=5 (= piso) → discord não reserva mesmo com count > ceiling"
    rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 110, rec.count
    assert_equal 5, rec.count_discord
  end

  # ── F3b piso: ceiling pequeno (5) — piso é max(1, floor(5*0.05)=floor(0.25)=0) = 1 ─
  def test_piso_ceiling_5_permite_apenas_1_chamada_discord_no_piso
    # count=4 (80% do teto). Discord pode fazer 1 reserva (count < ceiling, vai a 5).
    # Depois: count=5 >= ceiling=5, count_discord=1 < max(1, 0)=1? 1 < 1 = false → recusa.
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 4)

    ok1 = SearchApiQuota.reserve_quota!("tavily", ceiling: 5, month: "2026-08", origin: :discord)
    ok2 = SearchApiQuota.reserve_quota!("tavily", ceiling: 5, month: "2026-08", origin: :discord)
    assert ok1, "1ª reserva (count 4→5) deve passar"
    refute ok2, "2ª reserva com count=5 >= ceiling=5 e count_discord=1 já no piso max=1 deve recuar"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 5, rec.count
    assert_equal 1, rec.count_discord
  end

  # ── F3b rollback: reverte count + count_discord quando origin=:discord ─────
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

  # ── F3b rollback: reverte count + count_mcp quando origin=:mcp ──────────────
  def test_rollback_quota_reverte_count_e_count_mcp
    SearchApiQuota.reserve_quota!("exa", ceiling: 100, month: "2026-08", origin: :mcp)
    rec_before = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 1, rec_before.count
    assert_equal 1, rec_before.count_mcp

    SearchApiQuota.rollback_quota!("exa", month: "2026-08", origin: :mcp)
    rec_after = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
    assert_equal 0, rec_after.count
    assert_equal 0, rec_after.count_mcp
  end

  # ── F3b rollback: sem origin reverte só count (legado intacto) ─────────────
  def test_rollback_quota_sem_origin_reverte_apenas_count
    SearchApiQuota.reserve_quota!("linkup", ceiling: 100, month: "2026-08")
    SearchApiQuota.rollback_quota!("linkup", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "linkup", month: "2026-08")
    assert_equal 0, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── F3b rollback: reverter uma reserva do piso discord decrementa corretamente
  def test_rollback_quota_apos_reserva_do_piso_decrementa_count_discord
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 100, count_discord: 0)

    SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord)

    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 100, rec.count, "rollback volta count para 100 (estado pré-piso)"
    assert_equal 0, rec.count_discord, "rollback zera count_discord"
  end

  # ── F3b guarda: rollback não decrementa abaixo de 0 ──────────────────────
  def test_rollback_com_count_discord_zero_e_noop
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 5, count_discord: 0)
    SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord)
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 5, rec.count
    assert_equal 0, rec.count_discord
  end

  # ── F3b integração: reserve+rollback para o piso deixa count_discord intacto
  def test_reserva_piso_discord_com_sucesso_incrementa_count_e_count_discord
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 100, count_discord: 2)
    ok = SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08", origin: :discord)
    assert ok, "count_discord=2 < piso=5 → discord reserva do piso"
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 101, rec.count
    assert_equal 3, rec.count_discord
  end

  # ── F3b regressão: contrato legado — reserve sem origin — não muda ─────────
  def test_contrato_legado_reserve_sem_origin_continua_funcionando
    3.times { SearchApiQuota.reserve_quota!("tavily", ceiling: 100, month: "2026-08") }
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 3, rec.count
    assert_equal 0, rec.count_discord
    assert_equal 0, rec.count_mcp
  end

  # ── F3b regressão: rollback múltiplo sem reserva não vai negativo ─────────
  def test_rollback_multiplo_sem_reserva_nao_vai_negativo
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 0)
    3.times { SearchApiQuota.rollback_quota!("tavily", month: "2026-08", origin: :discord) }
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 0, rec.count
    assert_equal 0, rec.count_discord
  end

  # ── F3b D7-readiness: método público para F8 (rake/search:report) ler contagem
  # O plano-fase2 §D7 define que a métrica de origem deve ser legível. Aqui
  # só cravamos que os contadores são atributos públicos do model (sem
  # helper custom) — é o suficiente pro F8 grep+log.
  def test_count_discord_e_count_mcp_sao_atributos_publicos
    rec = SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count_discord: 7, count_mcp: 3)
    assert_equal 7, rec.count_discord
    assert_equal 3, rec.count_mcp
  end
end