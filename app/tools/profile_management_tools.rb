# frozen_string_literal: true

require 'securerandom'
require 'timeout'
require 'json'

class ManagementToolBase < ToolBase
  HANDLE_RULES = {
    'youtube' => /\A[a-zA-Z0-9._-]{3,30}\z/,
    'twitter' => /\A[a-z0-9_]{1,15}\z/,
    'instagram' => /\A[a-z0-9_](?:[a-z0-9._]{0,28}[a-z0-9_])?\z/,
    'tiktok' => /\A[a-z0-9_](?:[a-z0-9._]{0,22}[a-z0-9_])?\z/
  }.freeze

  private

  def owner?
    actor = Thread.current[:cleitin_actor]
    return false unless actor.is_a?(Hash) && actor[:user_id].present?

    owner_ids = ENV['DISCORD_OWNER_IDS'].to_s.split(',').map(&:strip).reject(&:empty?)
    return false if owner_ids.empty?

    owner_ids.include?(actor[:user_id].to_s)
  end

  def owner_error
    error('Ação restrita ao dono do bot')
  end

  def normalize_handle(input)
    str = input.to_s.strip
    return '' if str.blank?

    case str
    when %r{youtube\.com/channel/([^\/\?\s]+)}i
      return Regexp.last_match(1).strip
    when %r{youtube\.com/@([^\/\?\s]+)}i, %r{youtube\.com/c/([^\/\?\s]+)}i, %r{youtube\.com/user/([^\/\?\s]+)}i
      str = Regexp.last_match(1)
    when %r{(?:twitter|x)\.com/([^\/\?\s]+)}i
      str = Regexp.last_match(1)
    when %r{instagram\.com/([^\/\?\s]+)}i
      str = Regexp.last_match(1)
    when %r{tiktok\.com/@?([^\/\?\s]+)}i
      str = Regexp.last_match(1)
    end

    str = str.sub(/\A@/, '').strip
    # Channel ID canônico: case significativo (achado 1/3 do PR #36).
    # Preservar — @handle e channel ID são namespaces distintos no YouTube
    # e um ID downcasado vira um handle que nunca resolve.
    return str if str.match?(SocialProfile::CHANNEL_ID_PATTERN)

    str.downcase
  end

  def find_profile(identifier, platform = nil)
    id_str = identifier.to_s.strip
    if id_str =~ /\A\d+\z/
      scope = SocialProfile.all
      scope = scope.where(platform: platform) if platform.present?
      prof = scope.find_by(id: id_str.to_i)
      return prof if prof
    end

    handle = normalize_handle(identifier)
    scope = SocialProfile.all
    scope = scope.where(platform: platform) if platform.present?
    profiles = if handle.match?(SocialProfile::CHANNEL_ID_PATTERN)
                 scope.where(platform_username: handle)
               else
                 scope.where('LOWER(platform_username) = ?', handle.downcase)
               end

    if platform.blank? && profiles.count > 1
      :ambiguous
    else
      profiles.first
    end
  end

  def format_profile(profile)
    super.merge(
      monitoring_status: profile.monitoring_status,
      collection_status: profile.collection_status
    )
  end

  # Deduplicação unificada (PR #36, parte 3).
  #  - Channel IDs do YouTube: case significativo — comparação exata.
  #  - Handles / @handles: case-insensitive — comparação com LOWER.
  def find_duplicate(platform, handle)
    normalized = normalize_handle(handle)
    scope = SocialProfile.where(platform: platform)
    return scope.where(platform_username: normalized).first if normalized.match?(SocialProfile::CHANNEL_ID_PATTERN)

    scope.where('LOWER(platform_username) = ?', normalized.downcase).first
  end

  # Recupera o perfil vencedor após uma corrida de criação (RecordNotUnique).
  # Procura primeiro por (platform, platform_user_id) se informado, caindo de volta para a deduplicação por username.
  def find_winner(platform, handle, platform_user_id: nil)
    if platform_user_id.present?
      winner = SocialProfile.find_by(platform: platform, platform_user_id: platform_user_id)
      return winner if winner
    end

    find_duplicate(platform, handle)
  end

  def handle_existing_profile(profile)
    if profile.archived_at.present?
      profile.update!(archived_at: nil, monitoring_status: 'active')
      { status: :reactivated, data: format_profile(profile) }
    else
      { status: :already_monitored, data: format_profile(profile) }
    end
  end
end

class AddProfileTool < ManagementToolBase
  description 'Adiciona um novo perfil para monitoramento (youtube, instagram, twitter, tiktok).'

  param :platform, type: :string, desc: 'Plataforma do perfil (youtube, instagram, twitter, tiktok)', required: true
  param :handle, type: :string, desc: 'Handle ou URL do perfil', required: true

  def run(platform:, handle:)
    return owner_error unless owner?

    plt = platform.to_s.strip.downcase
    unless SocialProfile::PLATFORMS.include?(plt)
      return error("Plataforma inválida: #{platform}")
    end

    normalized_handle = normalize_handle(handle)
    rule = HANDLE_RULES[plt]
    if rule && !normalized_handle.match?(rule)
      return error("Handle inválido para #{plt}: #{normalized_handle}")
    end

    duplicate = find_duplicate(plt, normalized_handle)
    return handle_existing_profile(duplicate) if duplicate

    if plt == 'youtube'
      is_channel_id = handle.to_s =~ %r{/channel/}i || normalized_handle.match?(SocialProfile::CHANNEL_ID_PATTERN)
      channel_url = is_channel_id ? "https://www.youtube.com/channel/#{normalized_handle}" : "https://www.youtube.com/@#{normalized_handle}"

      begin
        metadata = ScrapingServices::YoutubeScraperService.extract_channel_metadata(channel_url, timeout: 8)
      rescue Timeout::Error
        return error('validação demorou — tente de novo')
      end

      return error("Perfil do YouTube não encontrado ou sem metadata válida: #{normalized_handle}") if metadata.nil?

      begin
        profile = SocialProfile.create!(
          platform: plt,
          platform_username: normalized_handle,
          platform_user_id: metadata[:channel_id].presence || (is_channel_id ? normalized_handle : "pending:youtube:#{normalized_handle}"),
          display_name: metadata[:title],
          avatar_url: metadata[:avatar_url] || metadata[:thumbnail_url],
          bio: metadata[:description],
          followers_count: metadata[:subscriber_count],
          monitoring_status: 'active',
          collection_status: 'pending'
        )
      rescue ActiveRecord::RecordNotUnique
        winner = find_winner(plt, normalized_handle, platform_user_id: metadata[:channel_id].presence)
        return handle_existing_profile(winner) if winner
        return error('Corrida de criação: perfil não encontrado após RecordNotUnique')
      end

      ScrapeYoutubeJob.perform_later(profile.id)
      success(format_profile(profile))
    else
      begin
        profile = SocialProfile.create!(
          platform: plt,
          platform_username: normalized_handle,
          platform_user_id: "pending:#{plt}:#{normalized_handle}",
          monitoring_status: 'active',
          collection_status: 'pending_validation'
        )
      rescue ActiveRecord::RecordNotUnique
        winner = find_winner(plt, normalized_handle)
        return handle_existing_profile(winner) if winner
        return error('Corrida de criação: perfil não encontrado após RecordNotUnique')
      end

      case plt
      when 'twitter'
        ScrapeTwitterJob.perform_later(profile.id)
      when 'instagram'
        ScrapeInstagramJob.perform_later(profile.id)
      end

      success(format_profile(profile))
    end
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
  end
end

class SetProfileMonitoringTool < ManagementToolBase
  description 'Altera o status de monitoramento de um perfil (active ou paused).'

  param :identifier, type: :string, desc: 'ID numérico ou username do perfil', required: true
  param :status, type: :string, desc: 'Novo status: active ou paused', required: true
  param :platform, type: :string, desc: 'Plataforma opcional para desambiguação', required: false

  def run(identifier:, status:, platform: nil)
    return owner_error unless owner?

    new_status = status.to_s.strip.downcase
    unless %w[active paused].include?(new_status)
      return error("Status inválido: #{status}. Status aceitos: active, paused")
    end

    profile = find_profile(identifier, platform)
    return error('Perfil ambíguo: especifique a plataforma') if profile == :ambiguous
    return error("Perfil não encontrado: #{identifier}") if profile.nil?

    update_attrs = { monitoring_status: new_status }
    update_attrs[:archived_at] = nil if new_status == 'active'
    profile.update!(update_attrs)
    success(format_profile(profile))
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
  end
end

class RemoveProfileTool < ManagementToolBase
  description 'Remove um perfil do monitoramento.'

  param :identifier, type: :string, desc: 'ID numérico ou username do perfil', required: true
  param :platform, type: :string, desc: 'Plataforma opcional para desambiguação', required: false
  param :confirm_token, type: :string, desc: 'Token de confirmação de uso único (retornado na primeira chamada)', required: false

  CONFIRM_TTL = 2.minutes
  CONFIRM_ACTION = 'remove_profile'

  def run(identifier:, platform: nil, confirm_token: nil)
    return owner_error unless owner?

    profile = find_profile(identifier, platform)
    return error('Perfil ambíguo: especifique a plataforma') if profile == :ambiguous
    return error("Perfil não encontrado: #{identifier}") if profile.nil?

    actor_id = Thread.current[:cleitin_actor][:user_id].to_s

    if confirm_token.blank?
      return build_confirmation_preview(profile, actor_id)
    end

    execute_with_confirmation(profile, actor_id, confirm_token)
  rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey => e
    error("Erro ao remover: #{e.message}")
  end

  private

  def build_confirmation_preview(profile, actor_id)
    token = SecureRandom.hex(16)
    expires_at = CONFIRM_TTL.from_now

    payload = {
      actor_id: actor_id,
      action: CONFIRM_ACTION,
      target_id: profile.id,
      target_platform: profile.platform,
      target_username: profile.platform_username,
      posts_count: profile.social_posts.count,
      snapshots_count: profile.profile_snapshots.count,
      expires_at: expires_at.iso8601
    }

    cache_key = "remove_profile_confirm:#{token}"
    # Convenção JSON nas duas pontas (r3, medido): FileStore/Marshal devolve
    # chaves símbolo e SolidCache/JSON devolve string — gravar um Hash de
    # símbolos era dependência de store. String JSON torna a leitura estável
    # (chaves string) em qualquer store.
    Rails.cache.write(cache_key, JSON.generate(payload), expires_in: CONFIRM_TTL)

    audit_payload = payload.merge(confirm_token: token, stage: 'preview')
    Rails.logger.info("[RemoveProfileTool] #{JSON.generate(audit_payload)}")

    {
      status: :confirmation_required,
      reason: 'Esta ação é irreversível. Confirme com o token fornecido.',
      data: {
        confirm_token: token,
        expires_at: expires_at.iso8601,
        target: {
          id: profile.id,
          platform: profile.platform,
          platform_username: profile.platform_username,
          posts_count: profile.social_posts.count,
          snapshots_count: profile.profile_snapshots.count
        }
      }
    }
  end

  # Claim do token: remove a chave do cache e CONFERE o retorno.
  # delete_entry em ambos os stores reais é atômico e reporta sucesso:
  #   - FileStore (teste): File.delete — SO garante que só UM processo remove
  #     o mesmo arquivo; delete_entry devolve true (removido) / false (já não
  #     existia ou outro removeu primeiro).
  #   - SolidCache (produção): DELETE WHERE key_hash=... no SQLite; o comitido
  #     primeiro apaga a linha, o segundo recebe 0 linhas → false.
  # (semântica medida nos sources: file_store.rb#delete_entry /
  #  solid_cache store#entry_delete → Entry.delete_by_key > 0)
  def claim_token(cache_key)
    deleted = Rails.cache.delete(cache_key)
    deleted == true
  end

  def execute_with_confirmation(profile, actor_id, confirm_token)
    cache_key = "remove_profile_confirm:#{confirm_token}"
    raw = Rails.cache.read(cache_key)

    # CLAIM-PRIMÉIRO: o token sai do cache ANTES de qualquer validação
    # (bloqueador C3b-r4: read→validar→delete deixava duas chamadas
    # concorrentes com o mesmo token validando antes de qualquer delete).
    # Quem falha no claim não valida nada — destruição dupla impossível.
    unless claim_token(cache_key)
      return error('Confirmação inválida ou inexistente')
    end

    # Mesma convenção da gravação (JSON string, chaves string) — parse com
    # guard para valores ausentes/corrompidos.
    cached = begin
      raw.is_a?(String) ? JSON.parse(raw) : raw
    rescue JSON::ParserError
      nil
    end

    unless cached.is_a?(Hash)
      return error('Confirmação inválida ou inexistente')
    end

    # Expiration check MUST come before actor/action/target checks
    expires_at = Time.iso8601(cached['expires_at']) rescue nil
    if expires_at.nil? || expires_at < Time.current
      return error('Confirmação expirada')
    end

    unless cached['actor_id'] == actor_id
      return error('Confirmação não pertence a este ator')
    end

    unless cached['action'] == CONFIRM_ACTION
      return error('Confirmação para ação diferente')
    end

    unless cached['target_id'] == profile.id
      return error('Confirmação para alvo diferente')
    end

    # Token válido e consumido (claim atomico) — executa destroy!
    # Decisão documentada: se o destroy! falhar (RecordNotDestroyed /
    # InvalidForeignKey), o token PERMANECE consumido — o claim já aconteceu
    # antes do destroy e a falha não devolve a chave. O dono pede uma
    # confirmação NOVA (token novo) para tentar de novo: em ações
    # destrutivas, reexecução automática após falha é mais perigosa que
    # uma reconfirmação.
    formatted = format_profile(profile)
    audit_payload = {
      id: profile.id,
      platform: profile.platform,
      platform_username: profile.platform_username,
      posts_count: profile.social_posts.count,
      snapshots_count: profile.profile_snapshots.count,
      actor: Thread.current[:cleitin_actor],
      confirm_token: confirm_token,
      stage: 'execute'
    }
    Rails.logger.info("[RemoveProfileTool] #{JSON.generate(audit_payload)}")

    profile.destroy!

    success(formatted.merge(status: 'removed'))
  end
end

class PromoteProspectTool < ManagementToolBase
  description 'Promove um prospecto descoberto (DiscoveredProfile) a perfil monitorado (SocialProfile).'

  param :discovered_profile_id, type: :integer, desc: 'ID do DiscoveredProfile', required: true

  def run(discovered_profile_id:)
    return owner_error unless owner?

    prospect = DiscoveredProfile.find_by(id: discovered_profile_id)
    return error("Prospecto não encontrado: #{discovered_profile_id}") if prospect.nil?

    plt = prospect.platform.to_s.strip.downcase
    unless SocialProfile::PLATFORMS.include?(plt)
      return error("Plataforma inválida: #{prospect.platform}")
    end

    normalized_handle = normalize_handle(prospect.username)
    rule = HANDLE_RULES[plt]
    if rule && !normalized_handle.match?(rule)
      return error("Handle inválido para #{plt}: #{normalized_handle}")
    end

    duplicate = find_duplicate(plt, normalized_handle)
    return handle_existing_profile(duplicate) if duplicate

    begin
      profile = SocialProfile.create!(
        platform: plt,
        platform_username: normalized_handle,
        platform_user_id: "pending:#{plt}:#{normalized_handle}",
        bio: prospect.bio,
        monitoring_status: 'active',
        collection_status: 'pending_validation'
      )
    rescue ActiveRecord::RecordNotUnique
      winner = find_winner(plt, normalized_handle)
      return handle_existing_profile(winner) if winner
      return error('Corrida de promoção: prospecto não encontrado após RecordNotUnique')
    end

    case plt
    when 'youtube'
      ScrapeYoutubeJob.perform_later(profile.id)
    when 'twitter'
      ScrapeTwitterJob.perform_later(profile.id)
    when 'instagram'
      ScrapeInstagramJob.perform_later(profile.id)
    end

    success(format_profile(profile))
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
  end
end
