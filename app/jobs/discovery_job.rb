# frozen_string_literal: true

class DiscoveryJob < ApplicationJob
  queue_as :default

  DAYS_WINDOW = 15

  def perform
    profiles = SocialProfile.where.not(last_collected_at: nil)

    Rails.logger.info "[DiscoveryJob] Analisando #{profiles.size} perfis para discovery"

    profiles.find_each do |profile|
      process_profile(profile)
    end
  end

  private

  def process_profile(profile)
    handles = Discovery::SocialGraphAnalyzer.extract_handles(profile, days: DAYS_WINDOW)
    return if handles.empty?

    Rails.logger.info "[DiscoveryJob] #{handles.size} handles novos encontrados em @#{profile.platform_username}"

    classifications = Discovery::ProfileClassifier.classify(handles, source_profile: profile)

    classifications.each do |result|
      save_discovered_profile(result, profile)
    end
  rescue Llm::BaseClient::QuotaExceededError => e
    Rails.logger.warn "[DiscoveryJob] Quota LLM esgotada ao processar #{profile.platform_username}: #{e.message}"
  end

  def save_discovered_profile(result, source_profile)
    handle = result[:handle].to_s.delete_prefix('@')
    return if handle.blank?

    dp = DiscoveredProfile.find_or_initialize_by(
      platform: result[:platform] || source_profile.platform,
      username: handle
    )

    dp.assign_attributes(
      classification: normalize_classification(result[:categoria]),
      classification_reason: result[:razao],
      source_profile: source_profile,
      classified_at: Time.current
    )

    dp.save! if dp.changed?

    return unless dp.classification == 'PATROCINADOR_PROSPECTO'

    Rails.logger.info "[DiscoveryJob] Prospecto detectado: @#{handle}"
  end

  def normalize_classification(raw)
    return nil if raw.nil?

    value = raw.to_s.upcase.strip
    return value if DiscoveredProfile::CLASSIFICATIONS.include?(value)

    'IGNORAR'
  end
end
