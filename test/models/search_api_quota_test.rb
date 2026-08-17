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
end
