# frozen_string_literal: true

require 'securerandom'

module AdminAlertChannel
  extend ActiveSupport::Concern

  CACHED_CHANNEL_KEY = "discord:admin_channel_id"
  LOCK_KEY = "discord:admin_channel_lock"
  LOCK_TTL = 30
  LOCK_RENEW_INTERVAL = 3
  LOCK_MUTEX = Mutex.new

  private

  def ensure_admin_channel
    channel_id = ENV["DISCORD_ADMIN_CHANNEL_ID"]
    return channel_id if channel_id.present?

    cached = Rails.cache.read(CACHED_CHANNEL_KEY)
    return cached if cached.present?

    lock_token = acquire_lock
    unless lock_token
      # Previously this fell through to a bare `nil`, which callers treated as
      # "channel not configured" and logged only a generic warning — masking a
      # lock-acquisition timeout as a configuration problem (achado 2, R3).
      Rails.logger.warn "[#{self.class.name}] Timeout ao adquirir lock de canal admin — tentativa simultânea descartada"
      return nil
    end

    heartbeat = start_lock_heartbeat(lock_token)
    begin
      # Re-check after acquiring lock — another thread may have created it
      cached = Rails.cache.read(CACHED_CHANNEL_KEY)
      if cached.present?
        return cached
      end

      guilds = DiscordApiClient.get_bot_guilds
      return nil if guilds.empty?

      guild_id = guilds.first["id"]
      channel = DiscordApiClient.create_text_channel(guild_id, "system-alerts")
      channel_id = channel["id"]

      Rails.cache.write(CACHED_CHANNEL_KEY, channel_id, expires_in: 30.days)
      Rails.logger.info "[#{self.class.name}] Canal admin criado e cacheado: #{channel_id}"
      channel_id
    ensure
      stop_lock_heartbeat(heartbeat)
      release_lock(lock_token)
    end
  end

  def acquire_lock
    token = SecureRandom.hex(8)
    deadline = Time.current + 5.seconds
    ttl = lock_ttl
    while Time.current < deadline
      if LOCK_MUTEX.synchronize { Rails.cache.write(LOCK_KEY, token, unless_exist: true, expires_in: ttl) }
        return token
      end
      sleep 0.05
    end
    nil
  end

  def start_lock_heartbeat(token)
    state = { running: true }
    thread = Thread.new do
      while state[:running]
        sleep lock_renew_interval
        break unless state[:running]

        renew_lock(token)
      end
    end
    [thread, state]
  end

  def stop_lock_heartbeat(heartbeat)
    return unless heartbeat

    thread, state = heartbeat
    state[:running] = false
    thread.wakeup if thread.alive?
    thread.join(1) rescue nil
  end

  def renew_lock(token)
    LOCK_MUTEX.synchronize do
      if Rails.cache.read(LOCK_KEY) == token
        Rails.cache.write(LOCK_KEY, token, expires_in: lock_ttl)
      end
    end
  end

  def release_lock(token)
    return unless token.present?

    LOCK_MUTEX.synchronize do
      if defined?(SolidCache::Entry) && Rails.cache.is_a?(SolidCache::Store)
        # Compare-and-delete pela API pública do Solid Cache: lê o entry e só
        # remove pela chave quando o token ainda é o dono. ACHADO 1 P1 do r9:
        # `SolidCache::Entry.hash_key` NÃO existe no Solid Cache 1.0.10 (só
        # key_hash_for, privado) — acessar internals quebrava o release no
        # ensure e o primeiro alerta nunca era enviado.
        entry = SolidCache::Entry.read(LOCK_KEY)
        SolidCache::Entry.delete_by_key(LOCK_KEY) if entry.to_s.include?(token.to_s)
      else
        Rails.cache.delete(LOCK_KEY) if Rails.cache.read(LOCK_KEY) == token
      end
    end
  end

  def lock_ttl
    self.class.const_defined?(:LOCK_TTL) ? self.class::LOCK_TTL : LOCK_TTL
  end

  def lock_renew_interval
    self.class.const_defined?(:LOCK_RENEW_INTERVAL) ? self.class::LOCK_RENEW_INTERVAL : LOCK_RENEW_INTERVAL
  end
end
