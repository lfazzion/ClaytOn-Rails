# frozen_string_literal: true

class RecentPostsTool < ToolBase
  description 'Lista posts JÁ SALVOS no banco local (coleta periódica) de um perfil JÁ MONITORADO por ' \
              'este projeto — NÃO lê a plataforma agora. A maioria dos perfis não está monitorada; se ' \
              'vier "Perfil não encontrado", ou para o que o perfil postou/disse AGORA na plataforma, ' \
              'use platform_search.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true
  param :days, type: :integer, desc: 'Número de dias para buscar (padrão 30)', required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(username:, platform:, days: 30, limit: 10)
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    limit = clamp(limit, 1, 50)
    posts = profile.social_posts.recent(days).order(posted_at: :desc).limit(limit)

    success(posts.map { |p| format_post(p) })
  end
end

class TopPostsTool < ToolBase
  description 'Lista os posts mais populares dentre os JÁ SALVOS no banco local de um perfil JÁ ' \
              'MONITORADO por este projeto — NÃO lê a plataforma agora. Use sort_by para escolher a ' \
              'métrica: likes (curtidas), views (visualizações; preferível para YouTube), comments ' \
              '(comentários) ou engagement (likes+comments+shares). Default: engagement.'

  SORT_COLUMNS = {
    'likes' => :likes_count,
    'views' => :views_count,
    'comments' => :comments_count,
    'engagement' => nil # tratado em código pois engagement_count não é coluna
  }.freeze

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 5)', required: false
  param :sort_by, type: :string, desc: 'likes | views | comments | engagement (padrão: engagement)', required: false

  def run(username:, platform:, limit: 5, sort_by: 'engagement')
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    sort_by = sort_by.to_s.downcase
    unless SORT_COLUMNS.key?(sort_by)
      return error("sort_by inválido: #{sort_by}. Use: #{SORT_COLUMNS.keys.join(', ')}")
    end

    limit = clamp(limit, 1, 20)
    posts = top_posts_for(profile, sort_by, limit)

    success(posts.map { |p| format_post(p) })
  end

  private

  def top_posts_for(profile, sort_by, limit)
    if sort_by == 'engagement'
      # COALESCE evita posts com métricas nil ficando no fim por default;
      # soma os 3 campos de engajamento (compatível com SocialPost#engagement_count).
      profile.social_posts
             .order(Arel.sql('COALESCE(likes_count, 0) + COALESCE(comments_count, 0) + COALESCE(shares_count, 0) DESC'))
             .limit(limit)
    else
      column = SORT_COLUMNS[sort_by]
      # NULLS LAST para que posts sem a métrica não dominem o topo (SQLite >= 3.30 suporta nativo).
      profile.social_posts.order(Arel.sql("#{column} DESC NULLS LAST")).limit(limit)
    end
  end
end

class PostsByTypeTool < ToolBase
  description 'Lista, dentre os posts dos últimos 30 dias JÁ SALVOS no banco local de um perfil JÁ ' \
              'MONITORADO por este projeto, os de um tipo específico — NÃO lê a plataforma agora.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true
  param :post_type, type: :string, desc: 'Tipo de post (image/video/text/reel/story)', required: true
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(username:, platform:, post_type:, limit: 10)
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    limit = clamp(limit, 1, 50)
    posts = profile.social_posts.by_type(post_type).recent(30).limit(limit)

    success(posts.map { |p| format_post(p) })
  end
end

class PostEngagementTool < ToolBase
  description 'Retorna métricas de engajamento de um post JÁ SALVO no banco local (perfil JÁ ' \
              'MONITORADO por este projeto) — NÃO busca a plataforma agora. Requer o post_id ' \
              'devolvido por recent_posts, top_posts ou posts_by_type.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true
  param :post_id, type: :integer, desc: 'ID do post', required: true

  def run(username:, platform:, post_id:)
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    post = profile.social_posts.find_by(id: post_id)
    return error("Post não encontrado com ID: #{post_id}") unless post

    success({
              post_id: post.id,
              engagement_count: post.engagement_count,
              engagement_rate: post.engagement_rate(profile.followers_count),
              likes_count: post.likes_count,
              comments_count: post.comments_count,
              shares_count: post.shares_count
            })
  end
end
