# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/jobs/friday_ideation_job'

class FridayIdeationJobTest < ActiveSupport::TestCase
  setup do
    @original_digest_channel = ENV['DISCORD_DIGEST_CHANNEL_ID']
  end

  teardown do
    if @original_digest_channel
      ENV['DISCORD_DIGEST_CHANNEL_ID'] = @original_digest_channel
    else
      ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
    end
  end

  test 'perform monta mensagem corretamente' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'
    create(:event, title: 'BGS 2026', event_type: 'bgs', start_date: 3.days.from_now)
    create(:external_catalog, source: 'tmdb', title: 'Popular Movie', popularity: 80.0)
    create(:news_article, title: 'Tech News', source: 'tech', link: 'https://example.com/tech', pub_date: 1.day.ago)

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordApiClient.expects(:send_message).with do |channel_id, msg|
      channel_id == '123456' &&
        msg.include?('BGS 2026') &&
        msg.include?('Popular Movie') &&
        msg.include?('Tech News') &&
        msg.include?('Sugestões de conteúdo do LLM')
    end.returns(true)

    job = FridayIdeationJob.new
    job.perform
  end

  test 'perform cria canal se não existir' do
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:create_text_channel).returns({ 'id' => 'channel456' })

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordApiClient.expects(:send_message).with('channel456', kind_of(String)).returns(true)

    job = FridayIdeationJob.new
    job.perform
  end
end
