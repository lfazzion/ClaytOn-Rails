# frozen_string_literal: true

require 'test_helper'
require_relative '../../../app/services/discord_api_client'
require_relative '../../../app/jobs/concerns/admin_alert_channel'

class AdminAlertChannelTest < ActiveSupport::TestCase
  class DummyJob
    include AdminAlertChannel

    def self.name
      'DummyJob'
    end
  end

  setup do
    @original_discord_admin_channel_id = ENV['DISCORD_ADMIN_CHANNEL_ID']
    Rails.cache.delete('discord:admin_channel_id')
    Rails.cache.delete('discord:admin_channel_lock')
  end

  teardown do
    if @original_discord_admin_channel_id
      ENV['DISCORD_ADMIN_CHANNEL_ID'] = @original_discord_admin_channel_id
    else
      ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    end
    Rails.cache.delete('discord:admin_channel_id')
    Rails.cache.delete('discord:admin_channel_lock')
  end

  test 'ensure_admin_channel retorna ENV quando configurado' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '123456'

    job = DummyJob.new
    channel_id = job.send(:ensure_admin_channel)

    assert_equal '123456', channel_id
  end

  test 'ensure_admin_channel cria canal quando ENV não configurado' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild789' }])
    DiscordApiClient.stubs(:create_text_channel).returns({ 'id' => 'channel456' })

    job = DummyJob.new
    channel_id = job.send(:ensure_admin_channel)

    assert_equal 'channel456', channel_id
  end

  test 'ensure_admin_channel usa cache quando disponível' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    Rails.cache.write('discord:admin_channel_id', 'cached_channel_789', expires_in: 30.days)

    job = DummyJob.new
    channel_id = job.send(:ensure_admin_channel)

    assert_equal 'cached_channel_789', channel_id
  end

  test 'ensure_admin_channel retorna nil quando sem guilds' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    job = DummyJob.new
    channel_id = job.send(:ensure_admin_channel)

    assert_nil channel_id
  end

  test 'ensure_admin_channel é seguro contra concorrência: cria canal exatamente uma vez' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild789' }])
    DiscordApiClient.expects(:create_text_channel).once.returns({ 'id' => 'channel456' })

    job1 = DummyJob.new
    job2 = DummyJob.new

    results = []
    mutex = Mutex.new
    threads = [
      Thread.new {
        result = job1.send(:ensure_admin_channel)
        mutex.synchronize { results << result }
      },
      Thread.new {
        result = job2.send(:ensure_admin_channel)
        mutex.synchronize { results << result }
      }
    ]
    threads.each(&:join)

    assert_equal 2, results.size
    assert_equal 'channel456', results[0]
    assert_equal 'channel456', results[1]
    assert_equal 'channel456', Rails.cache.read('discord:admin_channel_id')
  end

  test 'release_lock não apaga lock de outro worker se token for diferente' do
    job = DummyJob.new
    Rails.cache.write('discord:admin_channel_lock', 'other_worker_token', expires_in: 30)

    job.send(:release_lock, 'my_expired_token')

    assert_equal 'other_worker_token', Rails.cache.read('discord:admin_channel_lock')
  end

  test 'ensure_admin_channel renova o lease periodicamente permitindo criacao longa ultrapassar o TTL original' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild789' }])

    DiscordApiClient.stubs(:create_text_channel).with do
      sleep 0.12
      true
    end.returns({ 'id' => 'channel_long_exec' })

    begin
      AdminAlertChannel.send(:remove_const, :LOCK_TTL) rescue nil
      AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
      AdminAlertChannel.const_set(:LOCK_TTL, 0.08)
      AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 0.02)

      job1 = DummyJob.new
      job2 = DummyJob.new

      t1 = Thread.new { job1.send(:ensure_admin_channel) }
      sleep 0.04
      t2 = Thread.new { job2.send(:ensure_admin_channel) }

      res1 = t1.value
      res2 = t2.value

      assert_equal 'channel_long_exec', res1
      # ACHADO 3 r9: com o heartbeat renovando o lease, o segundo worker NÃO
      # desiste — ele tenta adquirir o lock até o deadline, e como o primeiro
      # termina em ~0.12s (menos que os 5s de acquire_lock), o segundo adquire,
      # relê o canal já cacheado e retorna o mesmo ID. A expectativa antiga
      # (nil) era incompatível com a implementação do heartbeat.
      assert_equal 'channel_long_exec', res2
    ensure
      AdminAlertChannel.send(:remove_const, :LOCK_TTL) rescue nil
      AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
      AdminAlertChannel.const_set(:LOCK_TTL, 30)
      AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 3)
    end
  end

  # ACHADO C: falhas do renew_lock na thread do heartbeat devem ser capturadas
  # e propagadas à thread principal — a renovação NÃO deve falhar silenciosamente
  # (o que permitiria que o canal continuasse sendo criado após perder o lease).
  # Aqui injetamos uma falha no renew_lock e exigimos que ela suba até o caller.
  test 'heartbeat propaga falha de renew_lock para a thread principal em vez de falhar silenciosamente' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild789' }])
    # Retarda a criação do canal para garantir que o heartbeat (intervalo
    # reduzido) dispare e falhe ANTES do ensure do caller.
    DiscordApiClient.stubs(:create_text_channel).with { sleep 0.1; true }.returns({ 'id' => 'channel456' })

    job = DummyJob.new
    # Injeta uma falha determinística no renew_lock.
    job.singleton_class.send(:define_method, :renew_lock) do |_token|
      raise 'falha simulada no heartbeat/renew_lock'
    end

    AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
    AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 0.01)
    begin
      error = assert_raises(RuntimeError) { job.send(:ensure_admin_channel) }
      assert_match(/falha simulada no heartbeat/, error.message)
    ensure
      AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
      AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 3)
    end
  end

  # ACHADO C (parte 2): o wakeup/join da parada do heartbeat não deve mascarar
  # a exceção original com um ThreadError. A exceção do heartbeat deve chegar
  # ao caller em vez de ser substituída por erro de join sobre thread morta.
  test 'stop_lock_heartbeat nao mascara excecao original do heartbeat com ThreadError' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild789' }])
    DiscordApiClient.stubs(:create_text_channel).with { sleep 0.1; true }.returns({ 'id' => 'channel456' })

    job = DummyJob.new
    job.singleton_class.send(:define_method, :renew_lock) do |_token|
      raise 'erro unico do heartbeat'
    end

    AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
    AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 0.01)
    begin
      error = assert_raises(RuntimeError) { job.send(:ensure_admin_channel) }
      assert_match(/erro unico do heartbeat/, error.message)
    ensure
      AdminAlertChannel.send(:remove_const, :LOCK_RENEW_INTERVAL) rescue nil
      AdminAlertChannel.const_set(:LOCK_RENEW_INTERVAL, 3)
    end
  end

  test 'release_lock atômico previne exclusao da chave quando token no cache muda durante a liberacao' do
    job = DummyJob.new
    token1 = 'token_worker_1'
    token2 = 'token_worker_2'

    Rails.cache.write(AdminAlertChannel::LOCK_KEY, token1, expires_in: 30)

    job.send(:release_lock, token1)
    assert_nil Rails.cache.read(AdminAlertChannel::LOCK_KEY)

    Rails.cache.write(AdminAlertChannel::LOCK_KEY, token2, expires_in: 30)

    job.send(:release_lock, token1)
    assert_equal token2, Rails.cache.read(AdminAlertChannel::LOCK_KEY)
  end
end
