# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/services/alert_throttler'
require_relative '../../app/jobs/concerns/admin_alert_channel'
require_relative '../../app/jobs/scraping_failure_alert_job'

class ScrapingFailureAlertJobTest < ActiveSupport::TestCase
  setup do
    @original_discord_admin_channel_id = ENV['DISCORD_ADMIN_CHANNEL_ID']
    @original_alert_throttle_enabled = ENV['ALERT_THROTTLE_ENABLED']
    Rails.cache.delete('discord:admin_channel_id')
    Rails.cache.delete('discord:admin_channel_lock')
    Rails.cache.delete('alert_throttle:timeout')
  end

  teardown do
    if @original_discord_admin_channel_id
      ENV['DISCORD_ADMIN_CHANNEL_ID'] = @original_discord_admin_channel_id
    else
      ENV.delete('DISCORD_ADMIN_CHANNEL_ID')
    end
    if @original_alert_throttle_enabled
      ENV['ALERT_THROTTLE_ENABLED'] = @original_alert_throttle_enabled
    else
      ENV.delete('ALERT_THROTTLE_ENABLED')
    end
    Rails.cache.delete('discord:admin_channel_id')
    Rails.cache.delete('discord:admin_channel_lock')
    Rails.cache.delete('alert_throttle:timeout')
  end

  test 'perform envia mensagem de alerta ao Discord' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'

    DiscordApiClient.expects(:send_message).with('987654', kind_of(String)).returns(true)

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Connection timeout', 'timeout')
  end

  test 'perform loga warning quando canal admin não configurado' do
    ENV.delete('DISCORD_ADMIN_CHANNEL_ID')

    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    Rails.logger.expects(:warn).with('[ScrapingFailureAlertJob] Canal admin não configurado')

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Error', 'unknown_error')
  end

  test 'build_alert_message contém informações corretas' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'

    sent_message = nil
    DiscordApiClient.expects(:send_message).with('987654', kind_of(String)) do |_channel, msg|
      sent_message = msg
    end.returns(true)

    job = ScrapingFailureAlertJob.new
    job.perform('instagram', 99, 'Access denied by captcha', 'captcha')

    assert_not_nil sent_message
    assert_includes sent_message, 'instagram'
    assert_includes sent_message, '99'
    assert_includes sent_message, 'captcha'
    assert_includes sent_message, 'Access denied by captcha'
  end

  test 'perform não envia alerta quando throttled' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    Rails.cache.write('alert_throttle:timeout', 10, expires_in: 1.hour)

    Rails.logger.expects(:warn).with('[ScrapingFailureAlertJob] Throttled: timeout')

    job = ScrapingFailureAlertJob.new
    job.perform('twitter', 42, 'Connection timeout', 'timeout')
  end

  test 'perform decrementa throttler se envio ao Discord falhar' do
    ENV['DISCORD_ADMIN_CHANNEL_ID'] = '987654'
    ENV['ALERT_THROTTLE_ENABLED'] = 'true'

    DiscordApiClient.stubs(:send_message).raises(StandardError.new('Discord API error'))

    job = ScrapingFailureAlertJob.new
    assert_raises(StandardError) do
      job.perform('twitter', 42, 'Connection timeout', 'timeout')
    end

    assert_equal 0, Rails.cache.read('alert_throttle:timeout').to_i
  end
end
