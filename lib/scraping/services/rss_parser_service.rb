# frozen_string_literal: true

require 'rexml/document'
require 'net/http'
require 'uri'

module ScrapingServices
  class RssParserService
    GOOGLE_NEWS_RSS_URL = 'https://news.google.com/rss/search'

    class << self
      def parse_google_news(query:, days: 1)
        (Date.today - days).strftime('%Y-%m-%d')
        url = "#{GOOGLE_NEWS_RSS_URL}?q=#{URI.encode_www_form_component(query)}&hl=pt-BR&gl=BR&ceid=BR:pt-419&when=#{days}d"

        response = fetch_feed(url)
        return [] unless response

        parse_feed(response)
      end

      private

      def fetch_feed(url)
        uri = URI(url)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
        request['Accept'] = 'application/rss+xml, application/xml, text/xml'

        response = http.request(request)
        return response.body if response.is_a?(Net::HTTPSuccess)

        Rails.logger.warn "[RssParserService] HTTP #{response.code} ao buscar RSS: #{url}"
        nil
      rescue StandardError => e
        Rails.logger.error "[RssParserService] Erro ao buscar feed: #{e.message}"
        nil
      end

      def parse_pub_date(value)
        return nil if value.blank?

        Time.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_feed(xml_content)
        doc = REXML::Document.new(xml_content)
        items = []

        doc.elements.each('rss/channel/item') do |item|
          title = item.elements['title']&.text
          link = item.elements['link']&.text
          description = item.elements['description']&.text
          pub_date = item.elements['pubDate']&.text
          source = item.elements['source']&.text

          next if title.nil? && link.nil?

          items << {
            title: title&.strip,
            link: link&.strip,
            description: description&.strip,
            pub_date: parse_pub_date(pub_date),
            source: source&.strip
          }
        end

        items
      rescue REXML::ParseException => e
        Rails.logger.error "[RssParserService] XML malformado: #{e.message}"
        []
      end
    end
  end
end
