# frozen_string_literal: true

class ProspectsTool < ToolBase
  description 'Lista, do banco local de descoberta, os perfis JÁ CLASSIFICADOS como ' \
              'PATROCINADOR_PROSPECTO pelo motor de classificação deste projeto — NÃO busca nem ' \
              'classifica perfil agora, só lê o que já foi analisado.'

  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 20)', required: false

  def run(limit: 20)
    limit = clamp(limit, 1, 50)
    prospects = DiscoveredProfile.prospects.limit(limit)

    success(prospects.map do |p|
      {
        id: p.id,
        platform: p.platform,
        username: p.username,
        classification: p.classification,
        classified_at: p.classified_at
      }
    end)
  end
end

class UnclassifiedProfilesTool < ToolBase
  description 'Lista, do banco local de descoberta, os perfis que AINDA NÃO foram classificados ' \
              '(concorrente/prospecto/ignorar) pelo motor deste projeto — NÃO busca nem classifica ' \
              'perfil agora.'

  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 20)', required: false

  def run(limit: 20)
    limit = clamp(limit, 1, 50)
    unclassified = DiscoveredProfile.unclassified.limit(limit)

    success(unclassified.map do |p|
      {
        id: p.id,
        platform: p.platform,
        username: p.username,
        classification: p.classification,
        classified_at: p.classified_at
      }
    end)
  end
end
