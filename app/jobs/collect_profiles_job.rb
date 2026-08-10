# frozen_string_literal: true

class CollectProfilesJob < ApplicationJob
  queue_as :scraping

  def perform
    Rails.logger.info "[CollectProfilesJob] Varrendo perfis monitorados para coleta diária"

    SocialProfile.monitored.each do |profile|
      if profile.blocked_until.present? && profile.blocked_until > Time.current
        Rails.logger.info "[CollectProfilesJob] Perfil #{profile.id} ignorado (blocked_until futuro: #{profile.blocked_until})"
        next
      end

      jitter_minutes = (profile.id * 37) % 45
      wait_time = jitter_minutes.minutes

      case profile.platform
      when "youtube"
        ScrapeYoutubeJob.set(wait: wait_time).perform_later(profile.id)
        Rails.logger.info "[CollectProfilesJob] Enfileirado ScrapeYoutubeJob para perfil #{profile.id} (wait: #{jitter_minutes}m)"
      when "twitter"
        ScrapeTwitterJob.set(wait: wait_time).perform_later(profile.id)
        Rails.logger.info "[CollectProfilesJob] Enfileirado ScrapeTwitterJob para perfil #{profile.id} (wait: #{jitter_minutes}m)"
      when "instagram"
        ScrapeInstagramJob.set(wait: wait_time).perform_later(profile.id)
        Rails.logger.info "[CollectProfilesJob] Enfileirado ScrapeInstagramJob para perfil #{profile.id} (wait: #{jitter_minutes}m)"
      when "tiktok"
        if profile.collection_status != "unsupported"
          profile.update!(collection_status: "unsupported")
        end
        Rails.logger.info "[CollectProfilesJob] Perfil #{profile.id} (tiktok) marcado como unsupported"
      else
        Rails.logger.warn "[CollectProfilesJob] Perfil #{profile.id} possui plataforma desconhecida: '#{profile.platform}'"
      end
    end
  end
end
