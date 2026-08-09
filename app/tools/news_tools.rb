# frozen_string_literal: true

class RecentArticlesTool < ToolBase
  description 'Lista artigos de notícia JÁ COLETADOS no banco local deste projeto via RSS — NÃO busca ' \
              'notícia nova na internet agora. Para notícia fora desses feeds, use web_search com time_range.'

  param :source, type: :string,
        desc: 'Nome exato de uma fonte RSS já presente no banco local (filtra por igualdade, não por ' \
              'busca). Deixe vazio para não filtrar por fonte.',
        required: false
  param :days, type: :integer, desc: 'Número de dias para buscar (padrão 7)', required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(source: nil, days: 7, limit: 10)
    limit = clamp(limit, 1, 50)
    articles = NewsArticle.recent(days)
    articles = articles.by_source(source) if source.present?
    articles = articles.limit(limit)

    success(articles.map do |a|
      {
        id: a.id,
        title: a.title,
        source: a.source,
        link: a.link,
        pub_date: a.pub_date
      }
    end)
  end
end
