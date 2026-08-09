# frozen_string_literal: true

class UpcomingEventsTool < ToolBase
  description 'Lista eventos futuros JÁ CADASTRADOS no banco local deste projeto (coletados via RSS) ' \
              '— NÃO busca evento novo na internet agora.'

  param :event_type, type: :string, desc: 'Tipo de evento (bgs/ccxp/anime_friends/other)', required: false
  param :limit, type: :integer, desc: 'Número máximo de resultados (padrão 10)', required: false

  def run(event_type: nil, limit: 10)
    limit = clamp(limit, 1, 30)
    events = Event.upcoming
    events = events.by_type(event_type) if event_type.present?
    events = events.limit(limit)

    success(events.map do |e|
      {
        id: e.id,
        title: e.title,
        event_type: e.event_type,
        location: e.location,
        start_date: e.start_date,
        end_date: e.end_date,
        source_url: e.source_url
      }
    end)
  end
end
