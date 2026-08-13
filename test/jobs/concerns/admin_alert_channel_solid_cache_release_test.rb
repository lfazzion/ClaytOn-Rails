# frozen_string_literal: true

require "test_helper"

# ACHADO 1 P1 do r9 (sol): release_lock usava SolidCache::Entry.hash_key,
# método que NÃO existe no Solid Cache 1.0.10 (só key_hash_for, privado).
# Em produção com SolidCache, o NoMethodError dentro do ensure substituía o
# retorno de ensure_admin_channel e o primeiro alerta nunca era enviado.
# Correção: usar a API pública read/delete_by_key (compare-and-delete por
# chave, validando o token no valor) — sem acessar internals.
class AdminAlertChannelSolidCacheReleaseTest < ActiveSupport::TestCase
  class DummyJob
    include AdminAlertChannel
  end

  class FakeSolidCacheEntry
    class << self
      attr_accessor :entries

      def read(key)
        entries[key]
      end

      def delete_by_key(*keys)
        keys.each { |k| entries.delete(k) }
      end
    end
  end

  setup do
    @job = DummyJob.new
    @original_entry = SolidCache::Entry
    SolidCache.send(:remove_const, :Entry)
    SolidCache.const_set(:Entry, FakeSolidCacheEntry)
    # Força o branch SolidCache no release_lock sem depender do store real
    Rails.cache.define_singleton_method(:is_a?) do |klass|
      klass == SolidCache::Store || super(klass)
    end
  end

  teardown do
    Rails.cache.singleton_class.send(:remove_method, :is_a?)
    SolidCache.send(:remove_const, :Entry)
    SolidCache.const_set(:Entry, @original_entry)
  end

  test "release_lock com SolidCache usa read + delete_by_key e apaga quando o token casa" do
    FakeSolidCacheEntry.entries = { "discord:admin_channel_lock" => "my_token" }

    assert_nothing_raised do
      @job.send(:release_lock, "my_token")
    end

    assert_nil FakeSolidCacheEntry.entries["discord:admin_channel_lock"],
               "lock deveria ter sido removido (token confere)"
  end

  test "release_lock com SolidCache NAO apaga quando o token do valor difere" do
    FakeSolidCacheEntry.entries = { "discord:admin_channel_lock" => "other_worker_token" }

    assert_nothing_raised do
      @job.send(:release_lock, "my_token")
    end

    assert_equal "other_worker_token", FakeSolidCacheEntry.entries["discord:admin_channel_lock"],
                 "lock de outro worker não pode ser removido"
  end
end
