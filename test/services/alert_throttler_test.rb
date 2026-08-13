# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/alert_throttler'

class AlertThrottlerTest < ActiveSupport::TestCase
  setup do
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'
  end

  teardown do
    ENV.delete('ALERT_THROTTLE_ENABLED')
    Rails.cache.delete("alert_throttle:test_type")
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

  test 'decrement reduz contador' do
    5.times { AlertThrottler.record('test_type') }
    AlertThrottler.decrement('test_type')

    assert_equal false, AlertThrottler.throttle?('test_type')
  end

  test 'tipos diferentes não interferem' do
    10.times { AlertThrottler.record('rate_limit') }

    assert_equal true, AlertThrottler.throttle?('rate_limit')
    assert_equal false, AlertThrottler.throttle?('captcha')
  end
end
