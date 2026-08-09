# frozen_string_literal: true

class ProfileLookupTool < ToolBase
  # A ressalva do "seguidores" não é enfeite: medido em 07/08/2026, a versão anterior
  # desta descrição ("...use platform_search") fez três modelos diferentes trocarem
  # esta tool pelo platform_search em "quantos seguidores o @fulano tem?" — e o
  # platform_search lista posts, não conta seguidor. A pergunta ficava sem resposta.
  description 'Cadastro de UM perfil JÁ MONITORADO por este projeto (banco local, última coleta): ' \
              'seguidores, seguindo, bio, verificado, nº de posts, perfil privado. Para NÚMERO DE ' \
              'SEGUIDORES e qualquer métrica de perfil esta é a ÚNICA fonte que existe — ' \
              'platform_search lista posts e não sabe contar seguidor. Se o perfil não estiver ' \
              'cadastrado, diga isso; não troque por outra tool. Use platform_search apenas para o ' \
              'CONTEÚDO que o perfil publicou.'

  param :username, type: :string, desc: 'Username do perfil', required: true
  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search).',
        required: true

  def run(username:, platform:)
    profile = SocialProfile.where(platform: platform).where('LOWER(platform_username) = LOWER(?)', username).first
    return error("Perfil não encontrado: #{username} em #{platform}") unless profile

    success(format_profile(profile))
  end
end

class ProfileListTool < ToolBase
  description 'Lista perfis JÁ CADASTRADOS no banco local deste projeto, opcionalmente filtrando por ' \
              'plataforma — NÃO descobre nem busca perfil novo na internet. Para achar perfil ainda ' \
              'não cadastrado, use platform_search ou web_search.'

  param :platform, type: :string,
        desc: 'Plataforma do perfil no banco local: twitter, instagram, youtube ou tiktok — ' \
              'X/Twitter é "twitter" aqui ("x" só existe como valor em platform_search). Vazio lista todas.',
        required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(platform: nil, limit: 10)
    limit = clamp(limit, 1, 50)
    profiles = SocialProfile.all
    profiles = profiles.by_platform(platform) if platform.present?
    profiles = profiles.order(followers_count: :desc).limit(limit)

    success(profiles.map { |p| format_profile(p) })
  end
end

class ProfileSearchTool < ToolBase
  description 'Busca por texto livre nos perfis JÁ CADASTRADOS no banco local deste projeto (username, ' \
              'bio ou display_name) — NÃO pesquisa a internet. Use quando souber o nome mas não a ' \
              'plataforma exata, ou como segunda tentativa depois de profile_lookup falhar. Se nada ' \
              'casar, o perfil não é monitorado: diga isso, em vez de substituir por outra tool.'

  param :query, type: :string, desc: 'Termo de busca', required: true
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(query:, limit: 10)
    limit = clamp(limit, 1, 30)
    sanitized = SocialProfile.sanitize_sql_like(query)
    profiles = SocialProfile.where('bio LIKE :q OR display_name LIKE :q OR platform_username LIKE :q', q: "%#{sanitized}%").limit(limit)

    success(profiles.map { |p| format_profile(p) })
  end
end

class ProfileCompareTool < ToolBase
  description 'Compara dois perfis JÁ CADASTRADOS no banco local deste projeto — seguidores, bio e ' \
              'métricas salvas na última coleta, NÃO dados ao vivo da plataforma.'

  param :username_a, type: :string, desc: 'Username do primeiro perfil', required: true
  param :platform_a, type: :string,
        desc: 'Plataforma do primeiro perfil no banco local: twitter, instagram, youtube ou tiktok ' \
              '(X/Twitter é "twitter" aqui)',
        required: true
  param :username_b, type: :string, desc: 'Username do segundo perfil', required: true
  param :platform_b, type: :string,
        desc: 'Plataforma do segundo perfil no banco local: twitter, instagram, youtube ou tiktok ' \
              '(X/Twitter é "twitter" aqui)',
        required: true

  def run(username_a:, platform_a:, username_b:, platform_b:)
    profile_a = SocialProfile.where(platform: platform_a).where('LOWER(platform_username) = LOWER(?)', username_a).first
    return error("Perfil não encontrado: #{username_a} em #{platform_a}") unless profile_a

    profile_b = SocialProfile.where(platform: platform_b).where('LOWER(platform_username) = LOWER(?)', username_b).first
    return error("Perfil não encontrado: #{username_b} em #{platform_b}") unless profile_b

    success({
              profile_a: format_profile(profile_a),
              profile_b: format_profile(profile_b)
            })
  end
end
