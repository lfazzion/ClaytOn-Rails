# frozen_string_literal: true

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

class SearchApiQuotaTest < Minitest::Test
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

  def test_table_name_e_plural_search_api_quotas
    assert_equal "search_api_quotas", SearchApiQuota.table_name
  end

  def test_teto_zero_bloqueia_mesmo_sem_row
    # Quando teto é 0 e não há registro, exceeded? deve retornar true
    assert_equal true, SearchApiQuota.exceeded?("tavily", 0, month: "2026-08")
  end

  def test_teto_positivo_sem_row_nao_bloqueia
    assert_equal false, SearchApiQuota.exceeded?("tavily", 100, month: "2026-08")
  end

  def test_exceeded_respeita_contagem_do_mes
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 4)
    assert_equal false, SearchApiQuota.exceeded?("tavily", 5, month: "2026-08")

    SearchApiQuota.find_by(api_name: "tavily", month: "2026-08").update!(count: 5)
    assert_equal true, SearchApiQuota.exceeded?("tavily", 5, month: "2026-08")
  end

  def test_increment_cria_e_incrementa_registro
    SearchApiQuota.increment("tavily", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    refute_nil rec
    assert_equal 1, rec.count

    SearchApiQuota.increment("tavily", month: "2026-08")
    assert_equal 2, rec.reload.count
  end

  def test_setup_limpa_linhas_pre_existentes_evitando_contaminacao_no_increment
    # Simula estado residual deixado por outro teste na suíte antes de rodar o setup
    SearchApiQuota.create!(api_name: "tavily", month: "2026-08", count: 4)

    # Executa setup como o runner do Minitest faz antes de cada teste
    setup

    # Se setup isola determinísticamente limpando as rows, o incremento parte do zero (count: 1)
    SearchApiQuota.increment("tavily", month: "2026-08")
    rec = SearchApiQuota.find_by(api_name: "tavily", month: "2026-08")
    assert_equal 1, rec.count, "esperado que o setup tenha limpado a linha pré-existente (count: 4 -> limpo -> incrementa para 1)"
  end

  def test_increment_recupera_de_record_not_unique_em_concorrencia
    # Cria o registro primeiro como se uma thread concorrente tivesse acabado de criar
    SearchApiQuota.create!(api_name: "exa", month: "2026-08", count: 1)

    # Simula RecordNotUnique na chamada find_or_create_by
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
      assert_equal 2, rec.count, "deve ter incrementado de 1 para 2 mesmo com RecordNotUnique"
    ensure
      SearchApiQuota.singleton_class.send(:remove_method, :find_or_create_by) if SearchApiQuota.singleton_class.method_defined?(:find_or_create_by, false)
    end
  end

  def test_current_month_e_increment_default_month
    assert_match(/\A\d{4}-\d{2}\z/, SearchApiQuota.current_month)
    SearchApiQuota.increment("linkup")
    rec = SearchApiQuota.find_by(api_name: "linkup", month: SearchApiQuota.current_month)
    refute_nil rec
    assert_equal 1, rec.count
  end
end
