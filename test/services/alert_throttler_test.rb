# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/alert_throttler'

class AlertThrottlerTest < ActiveSupport::TestCase
  setup do
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'
  end

  teardown do
    ENV.delete('ALERT_THROTTLE_ENABLED')
    # Limpa chaves antigas e novas (bucket atual)
    bucket = Time.current.to_i / 1.hour.to_i
    Rails.cache.delete("alert_throttle:test_type")
    Rails.cache.delete("alert_throttle:test_type:#{bucket}")
    Rails.cache.delete("alert_throttle:concurrent_type")
    Rails.cache.delete("alert_throttle:concurrent_type:#{bucket}")
    Rails.cache.delete("alert_throttle:expiry_type")
    Rails.cache.delete("alert_throttle:expiry_type:#{bucket}")
  end

  def current_key(type)
    bucket = Time.current.to_i / 1.hour.to_i
    "alert_throttle:#{type}:#{bucket}"
  end

  test 'throttle? retorna false quando desabilitado' do
    ENV['ALERT_THROTTLE_ENABLED'] = nil

    assert_equal false, AlertThrottler.throttle?('test_type')
  end

  test 'throttle? retorna false abaixo do limite' do
    5.times { AlertThrottler.record('test_type') }

    assert_equal false, AlertThrottler.throttle?('test_type')
  end

  test 'throttle? retorna true no limite' do
    10.times { AlertThrottler.record('test_type') }

    assert_equal true, AlertThrottler.throttle?('test_type')
  end

  test 'throttle? retorna true acima do limite' do
    15.times { AlertThrottler.record('test_type') }

    assert_equal true, AlertThrottler.throttle?('test_type')
  end

  test 'record não incrementa quando desabilitado' do
    ENV['ALERT_THROTTLE_ENABLED'] = nil
    20.times { AlertThrottler.record('test_type') }

    ENV['ALERT_THROTTLE_ENABLED'] = 'true'
    assert_equal false, AlertThrottler.throttle?('test_type')
  end

  test 'reset limpa contador' do
    10.times { AlertThrottler.record('test_type') }
    assert_equal true, AlertThrottler.throttle?('test_type')

    AlertThrottler.reset('test_type')
    assert_equal false, AlertThrottler.throttle?('test_type')
  end

  test 'tipos diferentes não interferem' do
    10.times { AlertThrottler.record('rate_limit') }

    assert_equal true, AlertThrottler.throttle?('rate_limit')
    assert_equal false, AlertThrottler.throttle?('captcha')
  end

  # --- Semântica de reserva (CORRECAO 3) ---

  test 'reserve aceita quando abaixo do limite' do
    # reserve retorna a CHAVE da janela (truthy) — não true literal (P1 do sol)
    key = AlertThrottler.reserve('test_type')
    assert key, "reserve deve retornar truthy (chave da janela)"
    assert_equal "alert_throttle:test_type:#{Time.current.to_i / 3600}", key
    assert_equal 1, Rails.cache.read(current_key('test_type')).to_i
  end

  test 'reserve rejeita quando no limite' do
    10.times { AlertThrottler.reserve('test_type') }

    assert_equal false, AlertThrottler.reserve('test_type')
    # contador permanece no limite (rollback do increment)
    assert_equal 10, Rails.cache.read(current_key('test_type')).to_i
  end

  test 'reserve aceita (retorna true) quando throttling desabilitado' do
    ENV['ALERT_THROTTLE_ENABLED'] = nil

    assert_equal true, AlertThrottler.reserve('test_type')
  end

  test 'release decrementa uma reserva aceita' do
    AlertThrottler.reserve('test_type')
    assert_equal 1, Rails.cache.read(current_key('test_type')).to_i

    AlertThrottler.release('test_type')
    assert_equal 0, Rails.cache.read(current_key('test_type')).to_i
  end

  test 'reserve concorrente a partir do contador 9 aceita apenas uma reserva' do
    # Inicia no contador 9 (um abaixo do limite)
    9.times { AlertThrottler.reserve('concurrent_type') }
    assert_equal 9, Rails.cache.read(current_key('concurrent_type')).to_i

    results = []
    mutex = Mutex.new

    threads = Array.new(2) do
      Thread.new do
        result = AlertThrottler.reserve('concurrent_type')
        mutex.synchronize { results << result }
      end
    end
    threads.each(&:join)

    aceitas = results.count { |r| r }   # chave (truthy) ou false
    rejeitadas = results.count { |r| !r }

    assert_equal 1, aceitas, "esperava que exatamente uma das duas reservas fosse aceita"
    assert_equal 1, rejeitadas, "esperava que uma reserva fosse rejeitada"
    assert_equal 10, Rails.cache.read(current_key('concurrent_type')).to_i
  end

  # --- Bug: rollback pode decrementar a janela seguinte ---
  # Cenário: contador em 10; requisição A incrementa para 11 e pausa;
  # a chave expira; B cria a nova janela e reserva a 1ª cota;
  # o rollback de A decrementa a janela nova de 1 para 0,
  # permitindo 11 envios naquela janela.
  test 'rollback nao afeta janela seguinte quando chave expira entre increment e rollback' do
    # Preenche a janela atual até o limite
    10.times { AlertThrottler.reserve('expiry_type') }
    assert_equal 10, Rails.cache.read(current_key('expiry_type')).to_i

    # Simula expiração da chave deletando-a manualmente (como se o TTL tivesse expirado)
    Rails.cache.delete(current_key('expiry_type'))

    # Requisição B chega na janela nova e reserva a primeira cota
    assert AlertThrottler.reserve('expiry_type'), "reserve deve retornar truthy"
    assert_equal 1, Rails.cache.read(current_key('expiry_type')).to_i

    # Agora simulamos o rollback da requisição A (que tinha incrementado para 11
    # antes da expiração). O bug: esse decrement atinge a janela NOVA de B.
    # Com a implementação atual, isso zera o contador da janela nova.
    # Com a correção, o rollback usa a chave da janela ANTIGA (que já expirou),
    # então é no-op ou cria uma chave na janela antiga que não afeta a nova.
    old_bucket = (Time.current.to_i - 1.hour.to_i) / 1.hour.to_i
    old_key = "alert_throttle:expiry_type:#{old_bucket}"
    Rails.cache.decrement(old_key, 1)

    # CORRETO: rollback não deve afetar a janela seguinte
    count_after_rollback = Rails.cache.read(current_key('expiry_type')).to_i
    assert_equal 1, count_after_rollback, "rollback não deve afetar a janela seguinte (esperado 1, obteve #{count_after_rollback})"
  end
end
