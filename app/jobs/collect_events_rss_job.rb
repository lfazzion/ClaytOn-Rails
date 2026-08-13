# frozen_string_literal: true

class CollectEventsRssJob < ApplicationJob
  queue_as :default

  def perform
    items = ScrapingServices::EventsRssParser.fetch_events

    items.each do |item|
      event = Event.find_or_initialize_by(source_url: item[:source_url])
      next if event.updated_at && event.updated_at > 12.hours.ago

      event.assign_attributes(
        title: item[:title],
        description: item[:description],
        source: "rss",
        event_type: item[:event_type]
      )

      event.save! if event.changed?
    end

    Rails.logger.info "[CollectEventsRssJob] #{items.size} eventos processados"
  rescue StandardError => e
    Rails.logger.error "[CollectEventsRssJob] Erro: #{e.message}"
  end
end
