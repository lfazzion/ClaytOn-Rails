# frozen_string_literal: true

require 'test_helper'
require_relative '../../../app/services/discord_api_client'
require_relative '../../../app/jobs/concerns/digest_channel'

class DigestChannelTest < ActiveSupport::TestCase
  class DummyJob
    include DigestChannel

    def self.name
      'DummyJob'
    end
  end

  setup do
    Rails.cache.delete('discord:digest_channel_id')
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  teardown do
    Rails.cache.delete('discord:digest_channel_id')
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'returns ENV when DISCORD_DIGEST_CHANNEL_ID is configured' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    job = DummyJob.new
    channel_id = job.send(:ensure_digest_channel)

    assert_equal '123456', channel_id
  end

  test 'returns cached value when cache has a channel id' do
    Rails.cache.write('discord:digest_channel_id', 'cached_channel_789', expires_in: 30.days)

    job = DummyJob.new
    channel_id = job.send(:ensure_digest_channel)

    assert_equal 'cached_channel_789', channel_id
  end

  test 'reuses existing channel found by name instead of creating' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([
      { 'id' => 'existing_channel', 'name' => 'digest-updates' },
      { 'id' => 'another_channel', 'name' => 'general' }
    ])
    DiscordApiClient.expects(:create_text_channel).never

    job = DummyJob.new
    channel_id = job.send(:ensure_digest_channel)

    assert_equal 'existing_channel', channel_id
    assert_equal 'existing_channel', Rails.cache.read('discord:digest_channel_id')
  end

  test 'creates channel when no existing channel with name is found' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([
      { 'id' => 'another_channel', 'name' => 'general' }
    ])
    DiscordApiClient.expects(:create_text_channel).with('guild123', 'digest-updates').returns({ 'id' => 'new_channel' })

    job = DummyJob.new
    channel_id = job.send(:ensure_digest_channel)

    assert_equal 'new_channel', channel_id
    assert_equal 'new_channel', Rails.cache.read('discord:digest_channel_id')
  end

  test 'returns nil when bot has no guilds' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    job = DummyJob.new
    channel_id = job.send(:ensure_digest_channel)

    assert_nil channel_id
  end

  # ACHADO 1: criação concorrente não deve duplicar o canal
  test 'concurrent ensure_digest_channel calls create channel only once' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([])

    create_calls = 0
    original_create = DiscordApiClient.method(:create_text_channel)
    DiscordApiClient.define_singleton_method(:create_text_channel) do |_guild_id, _name|
      create_calls += 1
      { 'id' => 'new_channel' }
    end

    job1 = DummyJob.new
    job2 = DummyJob.new

    # Simula duas chamadas concorrentes (sem cache, sem ENV)
    channel_id_1 = job1.send(:ensure_digest_channel)
    channel_id_2 = job2.send(:ensure_digest_channel)

    assert_equal 'new_channel', channel_id_1
    assert_equal 'new_channel', channel_id_2
    assert_equal 1, create_calls, 'create_text_channel deve ser chamado apenas uma vez, mesmo com chamadas concorrentes'
    assert_equal 'new_channel', Rails.cache.read('discord:digest_channel_id')
  ensure
    DiscordApiClient.define_singleton_method(:create_text_channel, original_create) if original_create
  end

  # ACHADO 1 (r9): corrida REAL entre dois jobs simultâneos.
  # Dois threads entram sem ENV e sem cache; a criação é lenta, portanto os dois
  # passam pela leitura do cache antes de qualquer escrita. Sem exclusão mútua,
  # create_text_channel é chamado duas vezes e o canal duplica.
  test 'two simultaneous jobs create the digest channel only once' do
    original_guilds   = DiscordApiClient.method(:get_bot_guilds)
    original_channels = DiscordApiClient.method(:get_guild_channels)
    original_create   = DiscordApiClient.method(:create_text_channel)

    mutex = Mutex.new
    create_calls = 0
    created_names = []

    DiscordApiClient.define_singleton_method(:get_bot_guilds) { [{ 'id' => 'guild123' }] }
    DiscordApiClient.define_singleton_method(:get_guild_channels) do |_guild_id|
      mutex.synchronize { created_names.dup }
    end
    DiscordApiClient.define_singleton_method(:create_text_channel) do |_guild_id, name|
      sleep 0.4 # janela da corrida: criação remota é lenta
      mutex.synchronize do
        create_calls += 1
        created_names << { 'id' => 'new_channel', 'name' => name }
      end
      { 'id' => 'new_channel' }
    end

    results = []
    threads = 2.times.map do
      Thread.new do
        job = DummyJob.new
        value = job.send(:ensure_digest_channel)
        mutex.synchronize { results << value }
      end
    end
    threads.each { |t| t.join(20) }

    assert_equal %w[new_channel new_channel], results.sort
    assert_equal 1, create_calls,
                 "create_text_channel deve ser chamado 1x sob concorrencia real, foi #{create_calls}x"
    assert_equal 'new_channel', Rails.cache.read('discord:digest_channel_id')
  ensure
    DiscordApiClient.define_singleton_method(:get_bot_guilds, original_guilds) if original_guilds
    DiscordApiClient.define_singleton_method(:get_guild_channels, original_channels) if original_channels
    DiscordApiClient.define_singleton_method(:create_text_channel, original_create) if original_create
    Rails.cache.delete('discord:digest_channel_lock:guild123')
  end

  # --- ACHADOS B, E, F (correções da revisão do sol, 13/08) ---

  # ACHADO B (P2): lease de 30s não cobria o pior caso (criação de canal no
  # Discord pode passar de 30s). O TTL deve cobrir o pior caso.
  test 'LOCK_TTL covers the worst-case channel creation window' do
    assert_equal 120.seconds, DigestChannel::LOCK_TTL
  end

  # ACHADO F (P2): o unlock antigo NÃO deve remover o lock novo. Testa a
  # unidade de release isolada (lock distribuído via cache compartilhado).
  test 'stale unlock does not remove the newer distributed lock' do
    lock_key = 'discord:digest_channel_lock:guildF'
    Rails.cache.delete(lock_key)
    # Worker2 já segura o lock (simula TTL expirado + re-aquisição).
    Rails.cache.write(lock_key, 'token_new', expires_in: DigestChannel::LOCK_TTL)
    # Worker1 faz seu unlock obsoleto com o token antigo.
    DummyJob.new.send(:release_digest_channel_lock, 'guildF', 'token_old')
    assert_equal 'token_new', Rails.cache.read(lock_key),
      'o unlock obsoleto não deve apagar o lock novo'
  end

  # ACHADO F (P2): interleaving completo via with_digest_channel_lock (exercita
  # o lock distribuído de verdade, não só o mutex local). Dentro da seção
  # crítica do worker1 o TTL expira e o worker2 escreve tokenB; o unlock
  # obsoleto de worker1 não deve remover tokenB.
  test 'distributed lock interleaving keeps the new lock intact' do
    lock_key = 'discord:digest_channel_lock:guildG'
    Rails.cache.delete(lock_key)
    DummyJob.new.send(:with_digest_channel_lock, 'guildG') do
      # Interleaving: TTL de tokenA expirou e worker2 adquiriu tokenB.
      Rails.cache.write(lock_key, 'tokenB', expires_in: DigestChannel::LOCK_TTL)
    end
    assert_equal 'tokenB', Rails.cache.read(lock_key)
  end

  # ACHADO E (P2): canal aceito do cache por 30 dias sem validação. Se o
  # get_channel retornar 404/Unknown Channel, invalidar o cache e re-resolver.
  test 'recovers digest channel by invalidating cache on Discord 404' do
    Rails.cache.write('discord:digest_channel_id', 'stale_channel', expires_in: 30.days)
    DiscordApiClient.stubs(:get_channel).with('stale_channel')
      .raises(RuntimeError.new('Discord API error: 404 Not Found'))
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guildE' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([])
    DiscordApiClient.expects(:create_text_channel).with('guildE', 'digest-updates').returns({ 'id' => 'fresh_channel' })

    channel_id = DummyJob.new.send(:recover_digest_channel, 'stale_channel')

    assert_equal 'fresh_channel', channel_id
    assert_equal 'fresh_channel', Rails.cache.read('discord:digest_channel_id'),
      'após 404 o cache deve ser repopulado com o canal recém-resolvido'
  end

  test 'does not invalidate cache when channel is still valid' do
    Rails.cache.write('discord:digest_channel_id', 'good_channel', expires_in: 30.days)
    DiscordApiClient.stubs(:get_channel).with('good_channel').returns({ 'id' => 'good_channel' })
    DiscordApiClient.expects(:get_bot_guilds).never
    DiscordApiClient.expects(:create_text_channel).never

    channel_id = DummyJob.new.send(:recover_digest_channel, 'good_channel')

    assert_equal 'good_channel', channel_id
    assert_equal 'good_channel', Rails.cache.read('discord:digest_channel_id')
  end
end
