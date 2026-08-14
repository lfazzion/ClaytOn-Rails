# frozen_string_literal: true

require 'rexml/document'
require 'net/http'
require 'uri'

module ScrapingServices
  class EventsRssParser
    FEEDS = [
      {
        type: "other",
        url: "https://news.google.com/rss/search?q=BGS+2026+OR+Brasil+Game+Show&hl=pt-BR&gl=BR&ceid=BR:pt-419"
      },
      {
        type: "other",
        url: "https://news.google.com/rss/search?q=CCXP+2026&hl=pt-BR&gl=BR&ceid=BR:pt-419"
      },
      {
        type: "other",
        url: "https://news.google.com/rss/search?q=Anime+Friends+2026&hl=pt-BR&gl=BR&ceid=BR:pt-419"
      }
    ].freeze

    class << self
      def fetch_events
        FEEDS.flat_map do |feed|
          items = parse_feed_url(feed[:url])
          items.map { |item| item.merge(event_type: infer_event_type(item[:title], feed[:type])) }
        end
      end

      private

      def parse_feed_url(url)
        xml = fetch(url)
        return [] unless xml

        parse_xml(xml)
      end

      def fetch(url)
        uri = URI(url)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'

        response = http.request(request)
        return response.body if response.is_a?(Net::HTTPSuccess)

        Rails.logger.warn "[EventsRssParser] HTTP #{response.code} ao buscar #{url}"
        nil
      rescue StandardError => e
        Rails.logger.error "[EventsRssParser] Erro: #{e.message}"
        nil
      end

      def parse_pub_date(value)
        return nil if value.blank?

        Time.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_xml(xml_content)
        doc = REXML::Document.new(xml_content)
        items = []

        doc.elements.each('rss/channel/item') do |item|
          title = item.elements['title']&.text
          link = item.elements['link']&.text
          description = item.elements['description']&.text
          pub_date = item.elements['pubDate']&.text

          next if title.nil? && link.nil?

          items << {
            title: title&.strip,
            source_url: link&.strip,
            description: description&.strip,
            pub_date: parse_pub_date(pub_date)
          }
        end

        items
      rescue REXML::ParseException => e
        Rails.logger.error "[EventsRssParser] XML malformado: #{e.message}"
        []
      end

      def infer_event_type(title, feed_type)
        return feed_type unless feed_type == "other"
        return "other" unless title

        downcased = title.downcase
        return "bgs" if downcased.match?(/bgs|brasil game show/)
        return "ccxp" if downcased.match?(/ccxp/)
        return "anime_friends" if downcased.match?(/anime friends/)

        "other"
      end
    end
  end
end
