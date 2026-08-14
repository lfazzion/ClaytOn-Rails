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
      # Rodada 2 (sol 13/08): se o heartbeat falhou ANTES de chegarmos aqui,
      # o lease foi perdido — criar o canal sem ser dono do lock quebraria a
      # exclusão mútua (dois workers criariam canais duplicados). Aborta.
      check_heartbeat!(heartbeat)

      # Re-check after acquiring lock — another thread may have created it
      cached = Rails.cache.read(CACHED_CHANNEL_KEY)
      if cached.present?
        return cached
      end

      guilds = DiscordApiClient.get_bot_guilds
      return nil if guilds.empty?

      # Rodada 2: re-checa o heartbeat DEPOIS da chamada lenta (get_bot_guilds)
      # e antes da criação — se o lease expirou durante a chamada, não cria.
      check_heartbeat!(heartbeat)

      guild_id = guilds.first["id"]
      channel = DiscordApiClient.create_text_channel(guild_id, "system-alerts")
      channel_id = channel["id"]

      Rails.cache.write(CACHED_CHANNEL_KEY, channel_id, expires_in: 30.days)
      Rails.logger.info "[#{self.class.name}] Canal admin criado e cacheado: #{channel_id}"
      channel_id
    ensure
      # Rodada 2 (sol 13/08): release_lock DEVE rodar mesmo se o stop do
      # heartbeat levantar (ex.: propagando falha do lease) — se o stop
      # lançar antes, o lock ficaria preso até expirar. Aninha: captura o erro
      # do stop, garante o release, e só então relança o erro original.
      heartbeat_error = stop_lock_heartbeat(heartbeat)
      release_lock(lock_token)
      raise heartbeat_error if heartbeat_error
    end
  end

  def check_heartbeat!(heartbeat)
    thread, state = heartbeat
    if state[:error]
      raise state[:error]
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
    state = { running: true, error: nil }
    thread = Thread.new do
      while state[:running]
        sleep lock_renew_interval
        break unless state[:running]

        begin
          renew_lock(token)
        rescue => e
          # ACHADO C: falha de renovação NÃO pode ser engolida na thread do
          # heartbeat. Capturamos e propagamos à thread principal — se o lease
          # expirou/d foi perdido, o caller deve decidir (e não criar o canal
          # como se ainda fosse o dono).
          state[:error] = e
          state[:running] = false
          break
        end
      end
    end
    [thread, state]
  end

  def stop_lock_heartbeat(heartbeat)
    return unless heartbeat

    thread, state = heartbeat

    # Rodada 2 (sol 13/08): NÃO levanta aqui — RETORNA o erro para o caller
    # garantir o release do lock ANTES de propagar. Se levantasse, o ensure
    # sequencial (`stop; release`) nunca chegaria ao release e o lock ficaria
    # preso até expirar. O wakeup/join é protegido para não substituir o erro
    # original por um ThreadError.
    if state[:error]
      state[:running] = false
      thread.wakeup if thread.alive?
      thread.join(1) rescue ThreadError
      return state[:error]
    end

    state[:running] = false
    thread.wakeup if thread.alive?
    # Protege contra ThreadError (thread já morta) — não deve mascarar a
    # exceção original do heartbeat.
    thread.join(1) rescue ThreadError
    nil
  end

  def renew_lock(token)
    LOCK_MUTEX.synchronize do
      if Rails.cache.is_a?(SolidCache::Store)
        # ACHADO B: renovação read-modify-write NÃO atômica. Substituímos por
        # CAS atômico via lock_and_write (FOR UPDATE + verificação do dono sob
        # lock). Se o lease já expirou e outro worker assumiu, a verificação
        # falha e NÃO sobrescrevemos o token novo. Se ainda somos dono,
        # reescrevemos com novo TTL (a expiração é embutida no blob do
        # SolidCache, e Rails.cache.write com expires_in atualiza o TTL).
        key = Rails.cache.send(:normalize_key, LOCK_KEY, nil)
        SolidCache::Entry.lock_and_write(key) do |raw|
          current = raw ? Rails.cache.send(:deserialize_entry, raw)&.value : nil
          if current.to_s == token.to_s
            Rails.cache.send(
              :serialize_entry,
              ActiveSupport::Cache::Entry.new(token, expires_in: lock_ttl)
            )
          end
        end
      elsif Rails.cache.read(LOCK_KEY) == token
        Rails.cache.write(LOCK_KEY, token, expires_in: lock_ttl)
      end
    end
  end

  def release_lock(token)
    return unless token.present?

    LOCK_MUTEX.synchronize do
      if Rails.cache.is_a?(SolidCache::Store)
        # ACHADO A + F: release atômico compare-and-delete.
        # - Usa a API real do SolidCache 1.0.10: lock_and_write trava a linha
        #   (FOR UPDATE) e entrega o valor sob lock; dentro dele verificamos
        #   igualdade EXATA do token e só então delete_by_key. Isso elimina a
        #   janela read→delete não-atômica do código anterior.
        # - A chave é namespaced via normalize_key (o código antigo lia
        #   Entry.read(LOCK_KEY) SEM namespace, o que nunca achava a linha em
        #   produção, onde Rails.cache tem namespace).
        # - Igualdade exata (==), não include?, para o token não casar por
        #   substring.
        key = Rails.cache.send(:normalize_key, LOCK_KEY, nil)
        SolidCache::Entry.lock_and_write(key) do |raw|
          current = raw ? Rails.cache.send(:deserialize_entry, raw)&.value : nil
          SolidCache::Entry.delete_by_key(key) if current.to_s == token.to_s
          nil
        end
      else
        current = Rails.cache.read(LOCK_KEY)
        Rails.cache.delete(LOCK_KEY) if current.to_s == token.to_s
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
