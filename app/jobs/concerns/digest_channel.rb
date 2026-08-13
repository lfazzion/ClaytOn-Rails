# frozen_string_literal: true

module DigestChannel
  extend ActiveSupport::Concern

  CACHED_CHANNEL_KEY = 'discord:digest_channel_id'
  CHANNEL_NAME = 'digest-updates'
  LOCK_KEY_PREFIX = 'discord:digest_channel_lock'
  LOCK_TTL = 30.seconds
  LOCK_WAIT_TIMEOUT = 15.seconds
  LOCK_RETRY_INTERVAL = 0.05

  # Locks de processo por guild: `unless_exist` do cache serializa entre
  # processos, mas não é atômico entre threads do mesmo processo (FileStore).
  PROCESS_LOCKS = {}
  PROCESS_LOCKS_MUTEX = Mutex.new

  def self.process_lock_for(guild_id)
    PROCESS_LOCKS_MUTEX.synchronize { PROCESS_LOCKS[guild_id] ||= Mutex.new }
  end

  private

  def ensure_digest_channel
    channel_id = ENV['DISCORD_DIGEST_CHANNEL_ID']
    return channel_id if channel_id.present?

    cached = Rails.cache.read(CACHED_CHANNEL_KEY)
    return cached if cached.present?

    guilds = DiscordApiClient.get_bot_guilds
    return nil if guilds.empty?

    guild_id = guilds.first['id']

    DigestChannel.process_lock_for(guild_id).synchronize do
      with_digest_channel_lock(guild_id) do
        resolve_digest_channel(guild_id)
      end
    end
  end

  # Exclusão mútua por guild: apenas um job resolve/cria o canal por vez.
  def with_digest_channel_lock(guild_id)
    lock_key = "#{LOCK_KEY_PREFIX}:#{guild_id}"
    token = SecureRandom.hex(8)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_WAIT_TIMEOUT

    until Rails.cache.write(lock_key, token, unless_exist: true, expires_in: LOCK_TTL)
      # Outro job pode ter terminado e populado o cache enquanto esperávamos.
      cached = Rails.cache.read(CACHED_CHANNEL_KEY)
      return cached if cached.present?
      # NUNCA executa a seção crítica sem o lock: o chamador do outro processo
      # ainda pode estar criando o canal (a chamada Discord demora) e dois
      # jobs criariam canais duplicados — exatamente o que o lock impede
      # (achado P1 do sol, 13/08). Retorna nil: o job encerra sem canal e o
      # próximo ciclo tenta de novo.
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep LOCK_RETRY_INTERVAL
    end

    begin
      yield
    ensure
      # Só remove se o token ainda é o nosso: se o TTL expirou e outro
      # processo adquiriu, apagar o lock dele reintroduziria a corrida
      # (achado P2 do sol, 13/08).
      Rails.cache.delete(lock_key) if Rails.cache.read(lock_key) == token
    end
  end

  def resolve_digest_channel(guild_id)
    # Dentro do lock: reler cache e relistar canais antes de criar.
    cached = Rails.cache.read(CACHED_CHANNEL_KEY)
    return cached if cached.present?

    existing_channel = DiscordApiClient.get_guild_channels(guild_id)
      .find { |c| c['name'] == CHANNEL_NAME }

    if existing_channel
      channel_id = existing_channel['id']
      Rails.logger.info "[#{self.class.name}] Canal digest reutilizado por nome: #{channel_id}"
    else
      channel = DiscordApiClient.create_text_channel(guild_id, CHANNEL_NAME)
      channel_id = channel['id']
      Rails.logger.info "[#{self.class.name}] Canal digest criado: #{channel_id}"
    end

    Rails.cache.write(CACHED_CHANNEL_KEY, channel_id, expires_in: 30.days)
    channel_id
  end
end
