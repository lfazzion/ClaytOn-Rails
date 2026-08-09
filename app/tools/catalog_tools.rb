# frozen_string_literal: true

class UpcomingCatalogTool < ToolBase
  description 'Lista, do catálogo JÁ COLETADO no banco local (TMDB/IGDB/AniList/RAWG), itens com ' \
              'lançamento futuro — NÃO consulta essas APIs agora. Para jogos, use source="rawg": ' \
              'mais completo para esse media_type que os demais.'

  param :source, type: :string, desc: 'Fonte: tmdb, igdb, anilist ou rawg. Para jogos usar rawg.', required: false
  param :media_type, type: :string, desc: 'Tipo de mídia (movie/tv/game/anime)', required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(source: nil, media_type: nil, limit: 10)
    limit = clamp(limit, 1, 50)
    items = ExternalCatalog.upcoming

    # Priorizar RAWG para jogos quando nenhuma fonte é especificada
    if source.blank? && media_type == "game"
      source = "rawg"
    end

    items = items.by_source(source) if source.present?
    items = items.by_media_type(media_type) if media_type.present?
    items = items.order(popularity: :desc).limit(limit)

    success(items.map { |i| format_catalog(i) })
  end

  private

  def format_catalog(item)
    {
      id: item.id,
      source: item.source,
      title: item.title,
      media_type: item.media_type,
      release_date: item.release_date,
      popularity: item.popularity,
      status: item.status
    }
  end
end

class PopularCatalogTool < ToolBase
  description 'Lista, do catálogo JÁ COLETADO no banco local (TMDB/IGDB/AniList/RAWG), os itens mais ' \
              'populares — NÃO consulta essas APIs agora.'

  param :source, type: :string, desc: 'Fonte: tmdb, igdb, anilist ou rawg', required: false
  param :media_type, type: :string, desc: 'Tipo de mídia (movie/tv/game/anime)', required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(source: nil, media_type: nil, limit: 10)
    limit = clamp(limit, 1, 50)
    items = ExternalCatalog.popular
    items = items.by_source(source) if source.present?
    items = items.by_media_type(media_type) if media_type.present?
    items = items.limit(limit)

    success(items.map { |i| format_catalog(i) })
  end

  private

  def format_catalog(item)
    {
      id: item.id,
      source: item.source,
      title: item.title,
      media_type: item.media_type,
      release_date: item.release_date,
      popularity: item.popularity,
      status: item.status
    }
  end
end
