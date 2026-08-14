# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module ScrapingServices
  class IgdbUnauthorizedError < StandardError; end

  class IgdbClient
    BASE_URL = "https://api.igdb.com/v4"
    TOKEN_URL = "https://id.twitch.tv/oauth2/token"

    class << self
      def reset_access_token
        @access_token = nil
        @token_expires_at = nil
      end

      def fetch_popular_games(limit: 50)
        query = <<~APICALYPSE
          fields name,summary,first_release_date,rating,rating_count,cover.url,genres.name,platforms.name,status;
          sort rating desc;
          limit #{limit};
          where rating != null & first_release_date != null;
        APICALYPSE
        post("/games", query)
      end

      def fetch_upcoming_games(limit: 50)
        timestamp = Time.current.to_i
        query = <<~APICALYPSE
          fields name,summary,first_release_date,cover.url,genres.name,platforms.name,status;
          sort first_release_date asc;
          limit #{limit};
          where first_release_date > #{timestamp};
        APICALYPSE
        post("/games", query)
      end

      private

      def access_token
        if @access_token && @token_expires_at && @token_expires_at > Time.current
          return @access_token
        end

        @access_token = nil
        @token_expires_at = nil

        begin
          uri = URI(TOKEN_URL)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true

          request = Net::HTTP::Post.new(uri)
          request.set_form_data(
            client_id: ENV.fetch('IGDB_CLIENT_ID'),
            client_secret: ENV.fetch('IGDB_CLIENT_SECRET'),
            grant_type: 'client_credentials'
          )

          response = http.request(request)

          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)
            @access_token = data['access_token']
            expires_in = data['expires_in'].to_i
            @token_expires_at = expires_in > 0 ? Time.current + expires_in.seconds : nil
            @access_token
          else
            Rails.logger.error "[IgdbClient] Falha ao gerar token: HTTP #{response.code}"
            nil
          end
        rescue StandardError => e
          Rails.logger.error "[IgdbClient] Erro ao gerar token: #{e.message}"
          nil
        end
      end

      def post(path, body, retry_on_unauthorized: true)
        token = access_token
        return nil unless token

        uri = URI("#{BASE_URL}#{path}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Post.new(uri)
        request['Client-ID'] = ENV.fetch('IGDB_CLIENT_ID')
        request['Authorization'] = "Bearer #{token}"
        request['Accept'] = 'application/json'
        request['Content-Type'] = 'text/plain'
        request.body = body

        response = http.request(request)

        if response.is_a?(Net::HTTPUnauthorized) && retry_on_unauthorized
          raise IgdbUnauthorizedError
        end

        return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

        Rails.logger.warn "[IgdbClient] HTTP #{response.code} em #{path}"
        nil
      rescue IgdbUnauthorizedError
        reset_access_token
        post(path, body, retry_on_unauthorized: false)
      rescue StandardError => e
        Rails.logger.error "[IgdbClient] Erro: #{e.message}"
        nil
      end
    end
  end
end
