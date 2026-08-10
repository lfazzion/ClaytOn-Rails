# frozen_string_literal: true

require_relative "../services/analytics/post_scorer"

class ScorePostsJob < ApplicationJob
  queue_as :default

  def perform
    SocialProfile.monitored.find_each do |profile|
      Analytics::PostScorer.score_posts(profile: profile)
    rescue StandardError => e
      Rails.logger.error "[ScorePostsJob] Erro ao pontuar posts do perfil #{profile.id}: #{e.message}"
    end
  end
end
