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

  # ACHADO E (13/08): quando desabilitado, reserve retorna nil (não chave),
  # para que o job trate como "sem reserva" e NÃO tente liberar em falha.
  test 'reserve retorna nil (sem reserva) quando throttling desabilitado' do
    ENV['ALERT_THROTTLE_ENABLED'] = nil
    assert_nil AlertThrottler.reserve('test_type')
  end

  test 'release decrementa uma reserva aceita' do
    AlertThrottler.reserve('test_type')
    assert_equal 1, Rails.cache.read(current_key('test_type')).to_i

    AlertThrottler.release('test_type')
    assert_equal 0, Rails.cache.read(current_key('test_type')).to_i
  end

  # --- ACHADO B (13/08): release incondicional pode deixar contador negativo ---
  # Um release chamado quando não há reserva pendente (ex.: retry do job após
  # já ter liberado) não deve decrementar de 0 para -1 (o que recriaria/estragaria
  # a chave). A correção só decrementa se a chave existe e valor > 0.
  test 'release não deixa contador negativo quando chamado sem reserva pendente' do
    AlertThrottler.reserve('test_type')        # 1
    AlertThrottler.release('test_type')        # 0
    assert_equal 0, Rails.cache.read(current_key('test_type')).to_i

    # Libera de novo (retry após já ter liberado).
    AlertThrottler.release('test_type')
    valor = Rails.cache.read(current_key('test_type')).to_i
    assert valor >= 0, "release idempotente não deve deixar contador negativo (obteve #{valor})"
    assert_equal 0, valor
  end

  # Rodada 2 (sol 13/08): o read→condição→decrement era TOCTOU. Com decrement
  # atômico + clamp, o contador NUNCA persiste negativo — mesmo com releases
  # duplicados concorrentes a partir de um valor pequeno.
  test 'release duplicado em sequência nunca deixa contador negativo' do
    AlertThrottler.reserve('clamp_type')       # 1
    5.times { AlertThrottler.release('clamp_type') }
    assert_equal 0, Rails.cache.read(current_key('clamp_type')).to_i,
                 "clamp pós-decrement deve segurar em 0, não -4"
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

  # --- ACHADO C (13/08): record não é atômico na inicialização ---
  # O increment+write quando nil NÃO é atômico: em concorrência dois processos
  # podem ler nil e ambos escrever 1, perdendo uma contagem. A correção
  # inicializa com write(unless_exist: true, expires_in: WINDOW) ANTES do
  # increment (como reserve). Como o bug é uma corrida entre processos, testamos
  # o INVARIANTE de ordem: record deve chamar write(unless_exist: true) e só
  # então increment — exatamente a ordem prescrita. O código antigo chamava
  # increment primeiro (sem write unless_exist), violando o contrato.
  test 'record inicializa com write(unless_exist) antes do increment (achado C)' do
    key = current_key('test_type')
    Rails.cache.delete(key)

    # Contrato: write(unless_exist) vem ANTES do increment. Valores canônicos
    # (não executam I/O real) impõem a ordem e a assinatura exatas.
    seq = sequence('record_init')
    Rails.cache.expects(:write)
      .with(key, 0, unless_exist: true, expires_in: 1.hour)
      .in_sequence(seq)
      .once
      .returns(true)
    Rails.cache.expects(:increment)
      .with(key, 1, expires_in: 1.hour)
      .in_sequence(seq)
      .once
      .returns(1)

    AlertThrottler.record('test_type')
  end

  # --- ACHADO D (13/08): teste REAL de release entre buckets ---
  # Reserva no bucket atual, "vira" o bucket (próxima janela temporal) e reserva
  # no novo; libera usando a chave da PRIMEIRA reserva. A liberação deve afetar
  # APENAS a janela antiga — recalcular a chave (current_key) corromperia a nova.
  test 'release libera a reserva da janela antiga sem afetar a nova apos virada de bucket' do
    bucket_atual = Time.current.to_i / 1.hour.to_i
    key_antiga = "alert_throttle:expiry_type:#{bucket_atual}"
    key_nova   = "alert_throttle:expiry_type:#{bucket_atual + 1}"

    Rails.cache.write(key_antiga, 1, expires_in: 1.hour)
    Rails.cache.write(key_nova, 1, expires_in: 1.hour)

    # Libera usando a chave da PRIMEIRA reserva (bucket antigo)
    AlertThrottler.release('expiry_type', key: key_antiga)

    assert_equal 0, Rails.cache.read(key_antiga).to_i, "janela antiga deve ser liberada"
    assert_equal 1, Rails.cache.read(key_nova).to_i, "janela nova não deve ser afetada"
  end
end
