# frozen_string_literal: true

require "test_helper"

class SearchApiQuotaModelTest < ActiveSupport::TestCase
  setup do
    SearchApiQuota.delete_all if defined?(SearchApiQuota) && SearchApiQuota.table_exists?
  end

  teardown do
    SearchApiQuota.delete_all if defined?(SearchApiQuota) && SearchApiQuota.table_exists?
  end

  test "valida presença de api_name" do
    quota = SearchApiQuota.new(month: "2026-08", count: 0)
    assert_not quota.valid?
    assert_includes quota.errors[:api_name], "can't be blank"
  end

  test "valida presença e formato do mês (YYYY-MM)" do
    invalid_month = SearchApiQuota.new(api_name: "linkup", month: "2026-8", count: 0)
    assert_not invalid_month.valid?
    assert_includes invalid_month.errors[:month], "is invalid"

    blank_month = SearchApiQuota.new(api_name: "linkup", month: "", count: 0)
    assert_not blank_month.valid?
    assert_includes blank_month.errors[:month], "can't be blank"

    valid_quota = SearchApiQuota.new(api_name: "linkup", month: "2026-08", count: 0)
    assert valid_quota.valid?
  end

  test "teto zero bloqueia mesmo sem registro existente" do
    SearchApiQuota.where(api_name: "tavily", month: "2026-08").delete_all
    assert_equal true, SearchApiQuota.exceeded?("tavily", 0, month: "2026-08")
  end

  test "teto positivo sem registro não bloqueia" do
    SearchApiQuota.where(api_name: "tavily", month: "2026-08").delete_all
    assert_equal false, SearchApiQuota.exceeded?("tavily", 100, month: "2026-08")
  end

  test "exceeded? e increment respeitam contagem e executam dentro de lock" do
    SearchApiQuota.where(api_name: "tavily", month: "2026-08").delete_all

    SearchApiQuota.increment("tavily", month: "2026-08")
    assert_equal false, SearchApiQuota.exceeded?("tavily", 2, month: "2026-08")

    SearchApiQuota.increment("tavily", month: "2026-08")
    assert_equal true, SearchApiQuota.exceeded?("tavily", 2, month: "2026-08")
  end

  test "increment recupera de RecordNotUnique em corrida concorrente" do
    SearchApiQuota.where(api_name: "exa", month: "2026-08").delete_all
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 1)

    called_rescue = false
    original_find_or_create = SearchApiQuota.method(:find_or_create_by)
    SearchApiQuota.define_singleton_method(:find_or_create_by) do |*args, &block|
      if !called_rescue
        called_rescue = true
        raise ActiveRecord::RecordNotUnique.new("simulated unique constraint failure")
      else
        original_find_or_create.call(*args, &block)
      end
    end

    begin
      SearchApiQuota.increment("exa", month: "2026-08")
      rec = SearchApiQuota.find_by(api_name: "exa", month: "2026-08")
      assert_equal 2, rec.count
    ensure
      SearchApiQuota.singleton_class.send(:remove_method, :find_or_create_by) if SearchApiQuota.singleton_class.method_defined?(:find_or_create_by, false)
    end
  end

  # ── F3a (E10): reserva atômica de quota ─────────────────────────────────────
  # 2 threads simultâneas disputando a ÚNICA vaga (ceiling=1) no MESMO SQLite
  # em arquivo (não :memory:). O race E10 existia porque `quota_exceeded?` e
  # `increment_quota` eram dois `with_lock` separados pelo HTTP. `reserve_quota!`
  # funde os dois em UMA transação atômica — só uma das threads passa.
  test "reserve_quota! com ceiling=1 e 2 threads simultâneas reserva no máximo 1" do
    SearchApiQuota.where(api_name: "race_api", month: "2026-08").delete_all

    barrier_mutex = Mutex.new
    barrier_cond = ConditionVariable.new
    ready_count = 0
    go = false

    results = Array.new(2)

    threads = (0..1).map do |i|
      Thread.new do
        # Usa conexão própria para que ActiveRecord não compartilhe a mesma
        # handle entre threads (ActiveRecord por padrão tem check-out por
        # thread; aqui usamos ApplicationRecord.connection_pool.with_connection
        # para garantir isolamento).
        ActiveRecord::Base.connection_pool.with_connection do
          barrier_mutex.synchronize do
            ready_count += 1
            barrier_cond.broadcast if ready_count == 2
            barrier_cond.wait(barrier_mutex) until go
          end

          # `reserve_quota!` será chamado pelas duas threads exatamente
          # depois do "go". A primeira que pegar o lock do SQLite passa
          # (count 0→1); a segunda deve ver count=1 e receber false.
          results[i] = SearchApiQuota.reserve_quota!("race_api", ceiling: 1, month: "2026-08")
        end
      end
    end

    # Espera as duas threads prontas
    barrier_mutex.synchronize do
      barrier_cond.wait(barrier_mutex) until ready_count == 2
    end

    # Sinaliza largada simultânea
    barrier_mutex.synchronize do
      go = true
      barrier_cond.broadcast
    end

    threads.each(&:join)

    rec = SearchApiQuota.find_by(api_name: "race_api", month: "2026-08")
    assert_not_nil rec, "row deve existir após reserva"
    assert rec.count <= 1, "count (#{rec.count}) deve ser <= ceiling=1; reserve_quota! falhou em serializar"
    trues = results.count(true)
    falses = results.count(false)
    assert_equal 1, trues, "exatamente UMA thread deve ter reservado (true), outra deve ter sido recusada (false); results=#{results.inspect}"
    assert_equal 1, falses, "a outra thread deve ter recebido false; results=#{results.inspect}"
  end

  # 200 vazio cobra — `reserve_quota!` é separado do "depois incrementa", então
  # o caller é responsável por NÃO chamar rollback_quota! em caso de 200-vazio.
  # Aqui testamos que `reserve_quota!` (que faz a reserva inicial) funciona
  # isoladamente: incrementa count e retorna true; sem 2ª chamada, count fica
  # em 1. Cobre a parte "200 vazio cobra" — quem decide reverter é o router.
  test "reserve_quota! incrementa e mantém contagem sem chamada extra" do
    SearchApiQuota.where(api_name: "vacuous_api", month: "2026-08").delete_all

    assert_equal true, SearchApiQuota.reserve_quota!("vacuous_api", ceiling: 10, month: "2026-08")
    assert_equal 1, SearchApiQuota.find_by(api_name: "vacuous_api", month: "2026-08").count

    # 2ª reserva: 1→2 (não faz rollback porque o caller não pediu).
    assert_equal true, SearchApiQuota.reserve_quota!("vacuous_api", ceiling: 10, month: "2026-08")
    assert_equal 2, SearchApiQuota.find_by(api_name: "vacuous_api", month: "2026-08").count
  end

  # 5xx não cobra — `rollback_quota!` reverte o incremento feito por
  # `reserve_quota!`. Após reserve→rollback, count volta ao estado anterior.
  test "rollback_quota! reverte o incremento feito por reserve_quota!" do
    SearchApiQuota.where(api_name: "rollback_api", month: "2026-08").delete_all

    assert_equal true, SearchApiQuota.reserve_quota!("rollback_api", ceiling: 10, month: "2026-08")
    assert_equal 1, SearchApiQuota.find_by(api_name: "rollback_api", month: "2026-08").count

    SearchApiQuota.rollback_quota!("rollback_api", month: "2026-08")
    assert_equal 0, SearchApiQuota.find_by(api_name: "rollback_api", month: "2026-08").count

    # Rollback extra sem reserva anterior: noop silencioso, count fica em 0.
    SearchApiQuota.rollback_quota!("rollback_api", month: "2026-08")
    assert_equal 0, SearchApiQuota.find_by(api_name: "rollback_api", month: "2026-08").count
  end

  # Reserva falha quando count já está no teto, SEM incrementar.
  test "reserve_quota! retorna false quando count já está no teto (sem incrementar)" do
    SearchApiQuota.where(api_name: "ceiling_api", month: "2026-08").delete_all
    SearchApiQuota.create!(api_name: "ceiling_api", month: "2026-08", count: 2)

    # Teto 2, count 2 → reserva recusada, count NÃO vai a 3.
    assert_equal false, SearchApiQuota.reserve_quota!("ceiling_api", ceiling: 2, month: "2026-08")
    assert_equal 2, SearchApiQuota.find_by(api_name: "ceiling_api", month: "2026-08").count
  end

  # Smoke (adaptado pós-implementação F3a): o original provava RED com
  # `assert_raises(NoMethodError)`. Agora que `reserve_quota!` existe, este
  # teste virou um guard de regressão: garante que o método continua
  # disponível e retorna um booleano (true/false) sem levantar NoMethodError.
  test "smoke — reserve_quota! existe e retorna booleano sem NoMethodError" do
    SearchApiQuota.where(api_name: "smoke", month: "2026-08").delete_all
    result = SearchApiQuota.reserve_quota!("smoke", ceiling: 1, month: "2026-08")
    assert_includes [true, false], result, "reserve_quota! deve retornar true|false, recebeu #{result.inspect}"
  end
end
