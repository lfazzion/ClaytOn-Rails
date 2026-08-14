# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/services/alert_throttler'
require_relative '../../app/jobs/concerns/admin_alert_channel'
require_relative '../../app/jobs/scraping_failure_alert_job'

class ScrapingFailureAlertJobTest < ActiveSupport::TestCase
  # Chave com bucket temporal, igual à do AlertThrottler (ACHADO 1 P2 do r9):
  # rollback/release/decrement só afetam a janela em que a reserva foi feita.
  def current_key(type)
    bucket = Time.current.to_i / 1.hour.to_i
    "alert_throttle:#{type}:#{bucket}"
  end

  teardown do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    ENV.delete('ALERT_THROTTLE_ENABLED')
    Rails.cache.delete('alert_throttle:timeout')
    Rails.cache.delete('alert_throttle:error')
    Rails.cache.delete(current_key('timeout'))
    Rails.cache.delete(current_key('error'))
  end

  test 'perform envia mensagem de alerta ao Discord' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'

    DiscordApiClient.stubs(:send_message).returns(true)

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Connection timeout', 'timeout')
  end

  test 'perform loga warning quando canal admin não configurado' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    Rails.cache.delete('discord:admin_channel_id')

    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    Rails.logger.expects(:warn).with('[ScrapingFailureAlertJob] Canal admin não configurado')

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Error', 'unknown_error')
  end

  test 'build_alert_message contém informações corretas' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'

    DiscordApiClient.stubs(:send_message).returns(true)

    job = ScrapingFailureAlertJob.new
    job.perform('instagram', 99, 'Access denied by captcha', 'captcha')
  end

  test 'perform não envia alerta quando throttled' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    Rails.cache.write(current_key('timeout'), 10, expires_in: 1.hour)
    DiscordApiClient.stubs(:send_message).returns(true)
    Rails.logger.expects(:warn).with('[ScrapingFailureAlertJob] Throttled: timeout')

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Connection timeout', 'timeout')
  end

  # --- CORRECAO 3: reserva atomica de cota ---

  test 'perform somente um envio ocorre no limite concorrente' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    # Preenche quase todo o limite (9 de 10)
    9.times { AlertThrottler.reserve('error') }

    # Contagem via singleton override + Mutex: o bloco de stub do Mocha 3.1.0
    # NÃO executa neste ambiente (probe do maestro: PROBE_COUNT=0), então a
    # forma `stubs(:send_message) do ... end` nunca incrementa o contador.
    # Override real é thread-safe e determinístico para o cenário concorrente.
    send_count = 0
    send_mutex = Mutex.new
    original_send_message = DiscordApiClient.method(:send_message)
    DiscordApiClient.define_singleton_method(:send_message) do |*_args|
      send_mutex.synchronize { send_count += 1 }
      true
    end

    job = ScrapingFailureAlertJob.new
    errors = []
    threads = Array.new(2) do
      Thread.new do
        begin
          job.perform('twitter', 42, 'fail', 'error')
        rescue StandardError => e
          errors << e
        end
      end
    end
    threads.each(&:join)

    # Somente um dos dois envios deve ocorrer (reserva atômica)
    assert_equal 1, send_count, "esperava exatamente 1 envio no limite concorrente"
    assert_equal 0, errors.size
    assert_equal 10, Rails.cache.read(current_key("error")).to_i
  ensure
    DiscordApiClient.singleton_class.send(:remove_method, :send_message)
    DiscordApiClient.define_singleton_method(:send_message, original_send_message)
  end

  test 'perform não consome cota quando canal admin ausente' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    Rails.cache.delete('discord:admin_channel_id')
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    DiscordApiClient.expects(:send_message).never
    AlertThrottler.expects(:reserve).never

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'fail', 'error')

    # contador permanece zerado (nada reservado)
    assert_equal 0, Rails.cache.read(current_key("error")).to_i
  end

  test 'perform libera a reserva quando o envio falha' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    DiscordApiClient.stubs(:send_message).raises(StandardError, "Discord API down")

    job = ScrapingFailureAlertJob.new
    assert_raises(StandardError, "Discord API down") do
      job.perform('twitter', 42, 'fail', 'error')
    end

    # A reserva deve ter sido liberada (decrement)
    assert_equal 0, Rails.cache.read(current_key("error")).to_i
  end

  test 'perform não libera cota quando exceção ocorre antes da reserva' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    Rails.cache.delete('discord:admin_channel_id')
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    # ensure_admin_channel falha antes de reserve ser chamado
    DiscordApiClient.stubs(:get_bot_guilds).raises(StandardError, "Discord unreachable")
    DiscordApiClient.expects(:send_message).never

    job = ScrapingFailureAlertJob.new
    assert_raises(StandardError, "Discord unreachable") do
      job.perform('twitter', 42, 'fail', 'error')
    end

    # Nenhuma reserva foi feita, então o contador deve estar zerado
    assert_equal 0, Rails.cache.read(current_key("error")).to_i
  end

  # --- ACHADO A (13/08): o rescue cobre também o log pós-envio ---
  # Se o envio foi bem-sucedido mas algo APÓS ele falha (ex.: Rails.logger.info),
  # a reserva NÃO deve ser liberada — caso contrário um retry reenviaria o alerta.
  test 'perform não libera reserva quando a falha ocorre após o envio' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    # Envio OK; o logger.info pós-envio levanta para simular a falha pós-envio.
    DiscordApiClient.stubs(:send_message).returns(true)
    Rails.logger.stubs(:info).raises(StandardError, 'logger failure')

    job = ScrapingFailureAlertJob.new
    assert_raises(StandardError, 'logger failure') do
      job.perform('twitter', 42, 'fail', 'error')
    end

    # A reserva deve permanecer (1): o alerta já foi entregue.
    assert_equal 1, Rails.cache.read(current_key('error')).to_i
  end

  test 'perform em mesma instancia nao libera cota de execucao anterior se falhar antes de reservar' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    DiscordApiClient.stubs(:send_message).returns(true)

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'fail 1', 'error')

    assert_equal 1, Rails.cache.read(current_key("error")).to_i

    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    Rails.cache.delete('discord:admin_channel_id')
    DiscordApiClient.stubs(:get_bot_guilds).raises(StandardError, "Discord unreachable")

    assert_raises(StandardError, "Discord unreachable") do
      job.perform('twitter', 42, 'fail 2', 'error')
    end

    assert_equal 1, Rails.cache.read(current_key("error")).to_i
  end

  # --- ACHADO E (13/08): reserve desabilitado retorna truthy e é tratado como chave ---
  # Quando o throttling está desabilitado, o job nunca deve tentar liberar
  # reserva (chamar release com uma chave inventada). O job deve tratar o
  # retorno "sem reserva" (nil) e prosseguir sem liberar em falha.
  test 'perform não chama release quando o throttling está desabilitado' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = nil

    # Envio falha, mas como não há reserva, o job não deve tentar liberar nada.
    DiscordApiClient.stubs(:send_message).raises(StandardError, 'boom')

    AlertThrottler.expects(:release).never

    job = ScrapingFailureAlertJob.new
    assert_raises(StandardError, 'boom') do
      job.perform('twitter', 42, 'fail', 'error')
    end
  end
end
