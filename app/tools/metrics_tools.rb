# frozen_string_literal: true

class EngagementRateTool < ToolBase
  description 'Calcula a taxa de engajamento de um perfil JÁ MONITORADO, a partir dos últimos posts ' \
              'JÁ SALVOS no banco local — NÃO lê a plataforma agora. Perfil não cadastrado aqui ' \
              'devolve erro, mesmo que exista de verdade na rede.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true

  def run(username:, platform:)
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    rate = profile.engagement_rate
    posts_analyzed = profile.social_posts.last(10)&.size || 0

    success({
              engagement_rate: rate,
              followers: profile.followers_count,
              posts_analyzed: posts_analyzed
            })
  end
end

class SnapshotTrendTool < ToolBase
  description 'Retorna a série histórica de seguidores/posts de um perfil JÁ MONITORADO, a partir dos ' \
              'snapshots JÁ SALVOS no banco local (coleta periódica) — NÃO lê a plataforma agora nem ' \
              'calcula projeção futura.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true
  param :days, type: :integer, desc: 'Número de dias para buscar (padrão 30)', required: false

  def run(username:, platform:, days: 30)
    days = days.to_i
    return error("Período inválido: days deve ser maior que 0") if days < 1

    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    snapshots = profile.profile_snapshots
                       .where('recorded_at >= ?', days.days.ago)
                       .ordered
                       .limit(20)

    success(snapshots.map do |s|
      {
        recorded_at: s.recorded_at,
        followers_count: s.followers_count,
        posts_count: s.posts_count
      }
    end)
  end
end

class ProfileRankingTool < ToolBase
  description 'Rankeia por seguidores ou engajamento os perfis JÁ CADASTRADOS no banco local deste ' \
              'projeto — NÃO busca perfil novo nem dado ao vivo.'

  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local (opcional): twitter, instagram, youtube ou ' \
              'tiktok — X/Twitter é "twitter" aqui. Vazio rankeia todas juntas.',
        required: false
  param :metric, type: :string, desc: 'Métrica (followers/engagement)', required: true
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(metric:, platform: nil, limit: 10)
    limit = 10 if limit.blank?
    limit = clamp(limit, 1, 50)

    case metric
    when 'followers'
      profiles = SocialProfile.where.not(followers_count: nil)
      profiles = profiles.by_platform(platform) if platform.present?
      profiles = profiles.order(followers_count: :desc).limit(limit)
      success(profiles.map { |p| format_profile(p) })
    when 'engagement'
      profiles = SocialProfile
                 .where.not(followers_count: nil)
                 .where('followers_count > 0')
                 .joins(:social_posts)
                 .group('social_profiles.id')
                 .select(<<~SQL.squish)
                   social_profiles.*,
                   (
                     SELECT AVG(sub.total_engagement) FROM (
                       SELECT (COALESCE(p.likes_count, 0) + COALESCE(p.comments_count, 0) + COALESCE(p.shares_count, 0)) AS total_engagement
                       FROM social_posts p
                       WHERE p.social_profile_id = social_profiles.id
                       ORDER BY COALESCE(p.posted_at, p.created_at) DESC, p.id DESC
                       LIMIT 10
                     ) sub
                   ) / social_profiles.followers_count * 100 AS computed_engagement_rate
                 SQL
      profiles = profiles.where(platform: platform) if platform.present?
      profiles = profiles.having('computed_engagement_rate IS NOT NULL')
                         .order(Arel.sql('computed_engagement_rate DESC'))
                         .limit(limit)

      success(profiles.map { |p| format_profile(p).merge(engagement_rate: p.computed_engagement_rate.round(2)) })
    else
      error("Métrica inválida: #{metric}. Use 'followers' ou 'engagement'.")
    end
  end
end
