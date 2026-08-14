# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require_relative "../../app/services/alert_throttler"

# Sol rodada 4 (13/08): o caminho de produção do release (SolidCache real) —
# decremento atômico via lock_and_write (FOR UPDATE) com retorno nil.
class AlertThrottlerSolidCacheReleaseTest < ActiveSupport::TestCase
  WINDOW = AlertThrottler::WINDOW

  def setup
    @store = SolidCache::Store.new(local_cache: false)
    @store.clear rescue nil
    Rails.stubs(:cache).returns(@store)
    ENV["ALERT_THROTTLE_ENABLED"] = "true"
  end

  def teardown
    Rails.unstub(:cache)
    ENV["ALERT_THROTTLE_ENABLED"] = nil
    @store&.clear rescue nil
  end

  def current_key(type)
    AlertThrottler.send(:current_key, type)
  end

  test "release com SolidCache real decrementa exatamente uma unidade" do
    AlertThrottler.reserve("solid_type")
    assert_equal 1, @store.read(current_key("solid_type")).to_i

    AlertThrottler.release("solid_type")

    assert_equal 0, @store.read(current_key("solid_type")).to_i
  end

  test "release com SolidCache real não deixa contador negativo em releases duplicados" do
    AlertThrottler.reserve("solid_type2")
    5.times { AlertThrottler.release("solid_type2") }

    assert_equal 0, @store.read(current_key("solid_type2")).to_i,
                 "release duplicado deve parar em 0 (nunca negativo)"
  end

  test "release com SolidCache real não cria chave ausente" do
    AlertThrottler.release("solid_ausente")

    assert_nil @store.read(current_key("solid_ausente")),
               "release sem reserva não deve criar chave"
  end
end