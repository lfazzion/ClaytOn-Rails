# frozen_string_literal: true

module Discovery
  class SocialGraphAnalyzer
    HANDLE_REGEX = /@([a-zA-Z0-9._]{2,50})/

    class << self
      def extract_handles(profile, days: 15)
        posts = profile.social_posts.recent(days)
        raw_handles = extract_raw_handles(posts)
        filter_known_handles(raw_handles)
      end

      private

      def extract_raw_handles(posts)
        handles = Set.new

        posts.each do |post|
          next if post.content.blank?

          post.content.scan(HANDLE_REGEX) do |match|
            username = match.first.sub(/\.+\z/, "").downcase
            handles << username if username.length >= 2
          end
        end

        handles.map do |username|
          { platform: 'unknown', username: "@#{username}", bio: nil }
        end
      end

      def filter_known_handles(raw_handles)
        return [] if raw_handles.empty?

        clean_usernames = raw_handles.map { |h| h[:username].delete_prefix('@') }

        known_usernames = SocialProfile.where(
          platform_username: clean_usernames
        ).pluck(:platform_username).to_set

        existing_discovered = DiscoveredProfile.where(
          username: clean_usernames
        ).where('classified_at > ?', 7.days.ago).pluck(:username).to_set

        raw_handles.reject do |h|
          clean = h[:username].delete_prefix('@')
          known_usernames.include?(clean) || existing_discovered.include?(clean)
        end
      end
    end
  end
end
