# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require_relative "../../app/services/alert_throttler"
require_relative "../../app/jobs/scraping_failure_alert_job"

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

  test "consolidate_incident e resolve_incident com SolidCache real persistem e limpam o estado duravel" do
    AlertThrottler.consolidate_incident("youtube", 42, "partial_collection", "fallback: sem dados")
    state = AlertThrottler.incident_state("youtube", 42)
    assert_equal "partial_collection", state[:error_type]
    assert_equal "fallback: sem dados", state[:fingerprint]
    assert_equal false, AlertThrottler.transition?("youtube", 42, "partial_collection", "fallback: sem dados")

    AlertThrottler.resolve_incident("youtube", 42)
    assert_nil AlertThrottler.incident_state("youtube", 42)
    assert_equal true, AlertThrottler.transition?("youtube", 42, "partial_collection", "fallback: sem dados")
  end

  test "reserve_incident com SolidCache real bloqueia reserva duplicada" do
    token = AlertThrottler.reserve_incident("youtube", 88, "scrape_error", "erro 500")
    assert token, "primeira reserva deve ser aceita"
    AlertThrottler.consolidate_incident("youtube", 88, "scrape_error", "erro 500", token: token)
    assert_equal false, AlertThrottler.reserve_incident("youtube", 88, "scrape_error", "erro 500")
  end

  test "release_incident com SolidCache real e compare-delete respeita o token de proprietario" do
    token = AlertThrottler.reserve_incident("youtube", 99, "scrape_error", "erro 500")
    assert token

    # Token incorreto não libera
    AlertThrottler.release_incident("youtube", 99, token: "outro_token")
    assert_equal false, AlertThrottler.reserve_incident("youtube", 99, "scrape_error", "erro 500")

    # Token correto libera
    AlertThrottler.release_incident("youtube", 99, token: token)
    assert AlertThrottler.reserve_incident("youtube", 99, "scrape_error", "erro 500")
  end

  test "jobs concorrentes para o mesmo incidente com SolidCache real resultam em no maximo 1 envio ao Discord" do
    ENV["DISCORD_ADMIN_CHANNEL_ID"] = "123456789"
    DiscordApiClient.expects(:send_message).once

    t1 = Thread.new do
      ScrapingFailureAlertJob.perform_now("youtube", 1, "erro fatal", "fatal_error")
    end
    t2 = Thread.new do
      ScrapingFailureAlertJob.perform_now("youtube", 1, "erro fatal", "fatal_error")
    end
    [t1, t2].each(&:join)

    state = AlertThrottler.incident_state("youtube", 1)
    assert_not_nil state
    assert_equal "fatal_error", state[:error_type]
  end
end
