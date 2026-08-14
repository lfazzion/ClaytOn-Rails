# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require_relative "../../../app/jobs/concerns/admin_alert_channel"

# ACHADO F (e A/B): o teste antigo usava uma classe fake com is_a? sobrescrito
# e rodava sequencialmente — não exercitava o store real do SolidCache nem
# forçava troca de proprietário sob concorrência. Aqui usamos um
# SolidCache::Store REAL (mesma API do Solid Cache 1.0.10 de produção),
# substituímos Rails.cache por ele durante o teste, e rodamos liberações
# concorrentes (dono atual vs. dono obsoleto) para provar que o
# compare-and-delete é atômico e o dono errado nunca destrói o lock.
class AdminAlertChannelSolidCacheReleaseTest < ActiveSupport::TestCase
  class DummyJob
    include AdminAlertChannel
  end

  LOCK_KEY = AdminAlertChannel::LOCK_KEY

  def setup
    @store = SolidCache::Store.new(local_cache: false)
    @store.clear rescue nil
    Rails.stubs(:cache).returns(@store)
  end

  def teardown
    Rails.unstub(:cache)
    @store&.clear rescue nil
  end

  test "release_lock com SolidCache real apaga quando o token e o dono atual casam" do
    @store.write(LOCK_KEY, "my_token", expires_in: 30)

    assert_nothing_raised { DummyJob.new.send(:release_lock, "my_token") }

    assert_nil @store.read(LOCK_KEY), "lock deveria ter sido removido (token confere)"
  end

  test "release_lock com SolidCache real NAO apaga lock de outro worker" do
    @store.write(LOCK_KEY, "other_worker_token", expires_in: 30)

    assert_nothing_raised { DummyJob.new.send(:release_lock, "my_token") }

    assert_equal "other_worker_token", @store.read(LOCK_KEY),
                 "lock de outro worker não pode ser removido"
  end

  # Igualdade EXATA (achado A): token que é substring do outro não deve casar.
  test "release_lock com SolidCache real exige igualdade exata do token (nao substring)" do
    @store.write(LOCK_KEY, "abc123def456", expires_in: 30)

    # token parecido mas diferente (substring) não remove
    assert_nothing_raised { DummyJob.new.send(:release_lock, "abc123") }

    assert_equal "abc123def456", @store.read(LOCK_KEY),
                 "igualdade exata: substring do token não pode liberar o lock"
  end

  # ACHADO F: sincronização que força troca de proprietário sob concorrência.
  # O dono obsoleto (owner1) tenta liberar enquanto o dono atual (owner2)
  # também libera. Em nenhuma das corridas o release do owner1 pode destruir
  # o lock do owner2 — o compare-and-delete só remove quando o token ainda é
  # o dono sob o lock_and_write (FOR UPDATE).
  test "release_lock com SolidCache real e concorrencia: release do nao-dono nunca remove o lock" do
    10.times do
      @store.clear rescue nil
      @store.write(LOCK_KEY, "owner2", expires_in: 30)

      t1 = Thread.new { DummyJob.new.send(:release_lock, "owner1") } # obsoleto, no-op
      t2 = Thread.new { DummyJob.new.send(:release_lock, "owner2") } # atual, remove
      t1.join
      t2.join

      final = @store.read(LOCK_KEY)
      assert_includes [nil, "owner2"], final,
                      "release do não-dono não pode remover lock do dono atual"
    end
  end
end
