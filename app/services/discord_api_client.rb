# frozen_string_literal: true

require 'net/http'
require 'json'

class DiscordApiClient
  API_BASE = 'https://discord.com/api/v10'

  class << self
    def get_channel(channel_id)
      response = request(:get, "/channels/#{channel_id}")
      JSON.parse(response.body)
    end

    def create_text_channel(guild_id, name)
      body = { name: name, type: 0 }.to_json
      response = request(:post, "/guilds/#{guild_id}/channels", body)
      JSON.parse(response.body)
    end

    def send_message(channel_id, content)
      body = { content: content }.to_json
      response = request(:post, "/channels/#{channel_id}/messages", body)
      JSON.parse(response.body)
    end

    def get_bot_guilds
      response = request(:get, '/users/@me/guilds')
      JSON.parse(response.body)
    end

    def get_guild_channels(guild_id)
      response = request(:get, "/guilds/#{guild_id}/channels")
      JSON.parse(response.body)
    end

    private

    MAX_RETRIES = 3

    def request(method, path, body = nil, retries: 0)
      uri = URI("#{API_BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      case method
      when :get
        req = Net::HTTP::Get.new(uri)
      when :post
        req = Net::HTTP::Post.new(uri)
        req.body = body
        req['Content-Type'] = 'application/json'
      end

      req['Authorization'] = "Bot #{ENV['DISCORD_BOT_TOKEN']}"

      response = http.request(req)

      if response.code.to_i == 429 && retries < MAX_RETRIES
        retry_after = parse_retry_after(response)
        Rails.logger.warn "[DiscordApiClient] Rate limited. Retry em #{retry_after}s (tentativa #{retries + 1}/#{MAX_RETRIES})"
        sleep(retry_after)
        return request(method, path, body, retries: retries + 1)
      end

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error "[DiscordApiClient] Erro #{response.code}: #{response.body}"
        raise "Discord API error: #{response.code} #{response.message}"
      end

      response
    end

    def parse_retry_after(response)
      json = begin
        JSON.parse(response.body)
      rescue StandardError
        {}
      end
      retry_after = json['retry_after'] || response['Retry-After'] || 1
      [retry_after.to_f.ceil, 5].min
    end
  end
end
