# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require_relative "../../../app/jobs/concerns/digest_channel"

# Sol rodada 3 (13/08): o caminho de produção do unlock (SolidCache real) não
# era exercitado — o FileStore dos testes usa compare-delete simples. Aqui
# usamos SolidCache::Store REAL (mesma API 1.0.10 de produção) para provar que
# o release com lock_and_write remove de verdade (e o `nil` do bloco impede a
# reescrita do lock com o count do delete_by_key).
class DigestChannelSolidCacheReleaseTest < ActiveSupport::TestCase
  class DummyJob
    include DigestChannel
  end

  LOCK_KEY_PREFIX = DigestChannel::LOCK_KEY_PREFIX

  def setup
    @store = SolidCache::Store.new(local_cache: false)
    @store.clear rescue nil
    Rails.stubs(:cache).returns(@store)
  end

  def teardown
    Rails.unstub(:cache)
    @store&.clear rescue nil
  end

  test "release_digest_channel_lock com SolidCache real apaga quando o token e o dono atual casam" do
    lock_key = "#{LOCK_KEY_PREFIX}:guild1"
    @store.write(lock_key, "my_token", expires_in: 30)

    DummyJob.new.send(:release_digest_channel_lock, "guild1", "my_token")

    assert_nil @store.read(lock_key), "lock deveria ter sido removido (token confere)"
  end

  test "release_digest_channel_lock com SolidCache real NAO apaga lock de outro worker" do
    lock_key = "#{LOCK_KEY_PREFIX}:guild2"
    @store.write(lock_key, "other_worker_token", expires_in: 30)

    DummyJob.new.send(:release_digest_channel_lock, "guild2", "my_token")

    assert_equal "other_worker_token", @store.read(lock_key),
                 "lock de outro dono não deve ser removido"
  end
end
