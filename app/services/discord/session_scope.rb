# frozen_string_literal: true

module Discord
  # Decide, a partir do canal, se a conversa é individual ou da sala inteira.
  # É a única classe que conhece DISCORD_OPEN_CHANNEL_IDS e o prefixo de silêncio.
  class SessionScope
    DEFAULT_MUTE_PREFIX = "//"

    Scope = Struct.new(:key, :channel_id, :user_id, :shared, :open_channel_id, keyword_init: true)

    class << self
      def for(user_id:, channel_id:, open_channel_id: nil)
        channel = channel_id.to_s
        abrir = (open_channel_id || channel).to_s
        return Scope.new(key: "c:#{channel}", channel_id: channel, user_id: nil, shared: true,
                         open_channel_id: abrir) if
          open_channel?(abrir)

        user = user_id.to_s
        Scope.new(key: "u:#{user}:c:#{channel}", channel_id: channel, user_id: user, shared: false,
                  open_channel_id: abrir)
      end

      def open_channel?(channel_id)
        channel = channel_id.to_s
        return false if channel.empty?

        open_channel_ids.include?(channel)
      end

      def open_channel_ids
        ENV["DISCORD_OPEN_CHANNEL_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)
      end

      def mute_prefix
        prefix = ENV["DISCORD_MUTE_PREFIX"].to_s.strip
        prefix.empty? ? DEFAULT_MUTE_PREFIX : prefix
      end

      def muted?(content)
        content.to_s.strip.start_with?(mute_prefix)
      end
    end
  end
end
