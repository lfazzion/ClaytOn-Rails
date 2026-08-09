# frozen_string_literal: true

class ToolBase < RubyLLM::Tool
  # Modelo inventa parâmetro — é fato permanente de tool calling, não acidente.
  # Medido em 05/08: o chatbot chamou `page_fetch(url:, engine: "youtube", ...)`
  # porque o prompt citava `engine` como campo da RESPOSTA e ele leu como
  # entrada. Keyword desconhecida levanta `ArgumentError` na própria chamada,
  # ANTES do corpo do método — então nem o `rescue` de dentro da tool pega, a
  # exceção sobe e o usuário fica sem resposta útil.
  #
  # O filtro mora aqui, e não em cada tool, porque a falha vale para as 19.
  def execute(**kwargs)
    Rails.logger.info "[#{self.class.name}] chamado com #{kwargs.inspect}"

    aceitos, ignorados = split_params(kwargs)
    if ignorados.any?
      Rails.logger.warn "[#{self.class.name}] parâmetros desconhecidos ignorados: #{ignorados.keys.inspect}"
    end

    faltando = required_params - aceitos.keys
    return error("faltou parâmetro obrigatório: #{faltando.join(', ')}") if faltando.any?

    run(**aceitos)
  end

  private

  # Uma tool que declara `**extras` assume a responsabilidade e recebe tudo.
  def split_params(kwargs)
    parametros = method(:run).parameters
    return [kwargs, {}] if parametros.any? { |tipo, _| tipo == :keyrest }

    nomes = parametros.filter_map { |tipo, nome| nome if %i[key keyreq].include?(tipo) }
    aceitos, ignorados = kwargs.partition { |chave, _| nomes.include?(chave) }
    [aceitos.to_h, ignorados.to_h]
  end

  def required_params
    method(:run).parameters.filter_map { |tipo, nome| nome if tipo == :keyreq }
  end

  def clamp(value, min, max)
    [[value.to_i, min].max, max].min
  end

  def success(data)
    { status: :success, data: data }
  end

  def error(reason)
    { status: :error, reason: reason }
  end

  def format_profile(profile)
    {
      id: profile.id,
      platform: profile.platform,
      username: profile.platform_username,
      display_name: profile.display_name,
      followers_count: profile.followers_count,
      following_count: profile.following_count,
      bio: profile.bio,
      verified: profile.verified,
      platform_url: profile.platform_url,
      posts_count: profile.posts_count,
      is_private: profile.is_private
    }
  end

  def format_post(post)
    {
      id: post.id,
      platform_post_id: post.platform_post_id,
      post_type: post.post_type,
      content: post.content,
      likes_count: post.likes_count,
      comments_count: post.comments_count,
      shares_count: post.shares_count,
      views_count: post.views_count,
      posted_at: post.posted_at,
      engagement_count: post.engagement_count
    }
  end
end
