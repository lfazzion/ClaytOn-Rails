# frozen_string_literal: true

require 'securerandom'
require 'timeout'

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

    str.sub(/\A@/, '').downcase.strip
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
    profiles = scope.where('LOWER(platform_username) = ?', handle.downcase)

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

    existing = SocialProfile.where(platform: plt).where('LOWER(platform_username) = ?', normalized_handle.downcase).first
    if existing
      if existing.archived_at.present?
        existing.update!(archived_at: nil, monitoring_status: 'active')
        return { status: :reactivated, data: format_profile(existing) }
      else
        return { status: :already_monitored, data: format_profile(existing) }
      end
    end

    if plt == 'youtube'
      is_channel_id = handle.to_s =~ %r{/channel/}i || (normalized_handle.start_with?('UC') && normalized_handle.length == 24)
      channel_url = is_channel_id ? "https://www.youtube.com/channel/#{normalized_handle}" : "https://www.youtube.com/@#{normalized_handle}"

      begin
        metadata = ScrapingServices::YoutubeScraperService.extract_channel_metadata(channel_url, timeout: 8)
      rescue Timeout::Error
        return error('validação demorou — tente de novo')
      end

      return error("Perfil do YouTube não encontrado ou sem metadata válida: #{normalized_handle}") if metadata.nil?

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

      ScrapeYoutubeJob.perform_later(profile.id)
      success(format_profile(profile))
    else
      profile = SocialProfile.create!(
        platform: plt,
        platform_username: normalized_handle,
        platform_user_id: "pending:#{plt}:#{normalized_handle}",
        monitoring_status: 'active',
        collection_status: 'pending_validation'
      )

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
  description 'Remove (arquiva) um perfil do monitoramento em duas etapas (requer confirmação).'

  param :identifier, type: :string, desc: 'ID numérico ou username do perfil', required: true
  param :platform, type: :string, desc: 'Plataforma opcional para desambiguação', required: false

  def run(identifier:, platform: nil)
    return owner_error unless owner?

    profile = find_profile(identifier, platform)
    return error('Perfil ambíguo: especifique a plataforma') if profile == :ambiguous
    return error("Perfil não encontrado: #{identifier}") if profile.nil?

    current_user_id = Thread.current[:cleitin_actor][:user_id]
    current_turn = Thread.current[:cleitin_turn]
    cache_key = "profile_remove_pending:#{current_user_id}:#{profile.id}"
    pending = Rails.cache.read(cache_key)

    if pending.nil?
      Rails.cache.write(cache_key, { profile_id: profile.id, user_id: current_user_id, turn: current_turn }, expires_in: 2.minutes)
      posts_count = profile.social_posts.count
      snapshots_count = profile.profile_snapshots.count

      success({
                status: :confirmation_required,
                resumo: "perfil ##{profile.id} (#{profile.platform}/#{profile.platform_username}) — #{posts_count} posts, #{snapshots_count} snapshots",
                instrucao: "repita 'confirmo a remoção de #{profile.platform_username}' na próxima mensagem para executar"
              })
    elsif pending[:turn] != current_turn
      Rails.cache.delete(cache_key)
      profile.update!(archived_at: Time.current, monitoring_status: 'paused')

      success(format_profile(profile).merge(status: 'removed'))
    else
      posts_count = profile.social_posts.count
      snapshots_count = profile.profile_snapshots.count

      success({
                status: :confirmation_required,
                resumo: "perfil ##{profile.id} (#{profile.platform}/#{profile.platform_username}) — #{posts_count} posts, #{snapshots_count} snapshots",
                instrucao: "repita 'confirmo a remoção de #{profile.platform_username}' na próxima mensagem para executar"
              })
    end
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
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

    existing = SocialProfile.where(platform: plt).where('LOWER(platform_username) = ?', normalized_handle.downcase).first
    return { status: :already_monitored, data: format_profile(existing) } if existing

    profile = SocialProfile.create!(
      platform: plt,
      platform_username: normalized_handle,
      platform_user_id: "pending:#{plt}:#{normalized_handle}",
      bio: prospect.bio,
      monitoring_status: 'active',
      collection_status: 'pending_validation'
    )

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
