# frozen_string_literal: true

class WeeklyDigestJob < ApplicationJob
  include DigestChannel

  queue_as :default

  def perform
    channel_id = ensure_digest_channel
    return unless channel_id

    message = build_weekly_digest
    send_digest_message(channel_id, message)

    Rails.logger.info "[WeeklyDigestJob] Digest enviado para canal #{channel_id}"
  end

  private

  def send_digest_message(channel_id, message)
    return if message.blank?

    if message.length <= 1900
      DiscordApiClient.send_message(channel_id, message)
    else
      chunks = []
      current_chunk = +""

      message.each_line do |line|
        if current_chunk.length + line.length > 1900
          chunks << current_chunk.strip
          current_chunk = line.dup
        else
          current_chunk << line
        end
      end
      chunks << current_chunk.strip if current_chunk.present?

      chunks.each do |chunk|
        DiscordApiClient.send_message(channel_id, chunk)
      end
    end
  end

  def build_weekly_digest
    lines = ["**📊 Digest Semanal — #{Date.current.strftime('%d/%m/%Y')}**", ""]

    monitored = SocialProfile.monitored.to_a

    lines << "**👥 Evolução de Seguidores (Perfis Monitorados):**"
    if monitored.any?
      monitored.each do |p|
        old_snap = p.profile_snapshots.where("recorded_at <= ?", 7.days.ago).order(recorded_at: :desc).first
        current = p.followers_count
        delta_str = if old_snap&.followers_count.present? && current.present?
                      diff = current - old_snap.followers_count
                      diff >= 0 ? "+#{diff}" : diff.to_s
                    else
                      "atual"
                    end
        name = p.display_name.presence || p.platform_username
        lines << "• **#{name}** (#{p.platform}): #{current || '—'} (#{delta_str})"
      end
    else
      lines << "Nenhum perfil monitorado."
    end
    lines << ""

    scored_posts = SocialPost.where("scored_at >= ?", 7.days.ago)
                             .where.not(performance_score: nil)
                             .order(performance_score: :desc)
                             .to_a

    lines << "**🚀 Top Desempenhos Apurados na Semana:**"
    if scored_posts.any?
      top_posts = scored_posts.first(3)
      top_posts.each_with_index do |post, idx|
        title = post.content.to_s.truncate(50)
        lines << "#{idx + 1}. **#{post.social_profile.platform_username}** — #{title} | #{post.views_count || '—'} views | Banda: #{post.performance_band} (z: #{post.performance_score})"
      end
    else
      lines << "Nenhum vídeo pontuado nesta semana."
    end
    lines << ""

    bottom_posts = scored_posts.size > 6 ? scored_posts.last(3) : []
    if bottom_posts.any?
      lines << "**🔻 Menores Desempenhos Apurados na Semana:**"
      bottom_posts.each_with_index do |post, idx|
        title = post.content.to_s.truncate(50)
        lines << "#{idx + 1}. **#{post.social_profile.platform_username}** — #{title} | #{post.views_count || '—'} views | Banda: #{post.performance_band} (z: #{post.performance_score})"
      end
      lines << ""
    end

    stale_profiles = SocialProfile.monitored.where("last_collected_at IS NULL OR last_collected_at < ?", 48.hours.ago)
    lines << "**⚠️ Perfis Sem Coleta > 48h:**"
    if stale_profiles.any?
      stale_profiles.each do |p|
        last_str = p.last_collected_at ? p.last_collected_at.strftime("%d/%m %H:%M") : "nunca coletado"
        lines << "• **#{p.platform_username}** (#{p.platform}) — #{last_str}"
      end
    else
      lines << "Nenhum perfil em atraso."
    end
    lines << ""

    new_prospects = DiscoveredProfile.prospects.where("classified_at >= ?", 7.days.ago).count
    lines << "**🎯 Novos prospects na semana:** #{new_prospects}"

    lines.join("\n")
  end
end
