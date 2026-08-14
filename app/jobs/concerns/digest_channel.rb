# frozen_string_literal: true

module DigestChannel
  extend ActiveSupport::Concern

  CACHED_CHANNEL_KEY = 'discord:digest_channel_id'
  CHANNEL_NAME = 'digest-updates'
  LOCK_KEY_PREFIX = 'discord:digest_channel_lock'
  # ACHADO B (P2, sol 13/08): antes era 30s. A seção crítica cria o canal no
  # Discord (create_text_channel) e pode passar de 30s sob latência/rate-limit;
  # com TTL curto, outro worker podia entrar após a expiração e duplicar o
  # canal. 120s cobre o pior caso (handshake + criação) com folga. Não renovamos
  # o lease: a seção crítica é curta e o compare-delete no unlock (achado A)
  # impede que um release obsoleto apague o lock do worker que entrou depois.
  LOCK_TTL = 120.seconds
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
      # ACHADO A (P1, sol 13/08): o unlock é compare-delete. Rails.cache NÃO
      # expõe compare-and-swap (CAS) nem delete condicional por valor, e o
      # backend SolidCache (ActiveSupport::Cache::SolidCacheStore) não oferece
      # API de delete-atômico-por-valor. A janela read→delete é a MENOR
      # possível (lê o token e decide apagar na mesma linha); se o TTL expirar
      # entre o read e o delete, o worker que re-adquiriu o lock continua dono
      # e o compare (token != atual) impede que este release obsoleto o apague.
      # Sem CAS no cache, este é o melhor possível — trade-off documentado e
      # aceito. Veja release_digest_channel_lock (achado F) para o teste que
      # exercita exatamente esse interleaving.
      release_digest_channel_lock(guild_id, token)
    end
  end

  # Unlock distribuído: só remove o lock se ainda for o nosso token
  # (compare-delete). Extraído de with_digest_channel_lock para ser testável
  # isoladamente (achado F, sol 13/08) e para o fluxo de recuperação de canal
  # (achado E) poder reusá-lo. Rodada 2 (sol 13/08): quando o backend é
  # SolidCache (produção), o release é ATÔMICO via lock_and_write (FOR
  # UPDATE) — verifica o token sob lock e deleta na mesma operação; sem a
  # janela read→delete. Para outros stores (teste FileStore) fica o
  # compare-delete simples, que é o melhor possível sem CAS.
  def release_digest_channel_lock(guild_id, token)
    lock_key = "#{LOCK_KEY_PREFIX}:#{guild_id}"
    if Rails.cache.is_a?(SolidCache::Store)
      normalized = Rails.cache.send(:normalize_key, lock_key, nil)
      SolidCache::Entry.lock_and_write(normalized) do |raw|
        if raw && Rails.cache.send(:deserialize_entry, raw)&.value.to_s == token.to_s
          SolidCache::Entry.delete_by_key(normalized)
        end
      end
    else
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

  # ACHADO E (P2, sol 13/08): o canal é aceito do cache por 30 dias SEM validar
  # se ainda existe no Discord. Se o envio falhar com 404/"Unknown Channel", o
  # cache está obsoleto e precisa ser invalidado para que o próximo
  # ensure_digest_channel reutilize o canal existente por nome ou crie um novo.
  #
  # DiscordApiClient#request levanta RuntimeError "Discord API error: 404 ..."
  # para canal inexistente; este método trata SÓ esse caso e propaga o resto.
  # Os jobs que enviam mensagens (WeeklyDigestJob, FridayIdeationJob,
  # Last30DaysDigestJob) devem chamar recover_digest_channel(channel_id) no
  # rescue de 404 de DiscordApiClient.send_message e reenviar com o canal novo.
  def recover_digest_channel(channel_id)
    # Valida a existência do canal antes de confiar no cache de 30 dias.
    DiscordApiClient.get_channel(channel_id)
    channel_id
  rescue RuntimeError => e
    raise unless e.message.include?('404') || e.message.match?(/unknown channel/i)

    Rails.cache.delete(CACHED_CHANNEL_KEY)
    Rails.logger.warn "[#{self.class.name}] Canal digest #{channel_id} inválido (404); cache invalidado para re-resolver"
    ensure_digest_channel
  end
end
