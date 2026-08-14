# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/services/discord_message_chunker'
require_relative '../../app/jobs/friday_ideation_job'

class FridayIdeationJobTest < ActiveSupport::TestCase
  setup do
    Rails.cache.delete('discord:digest_channel_id')
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  teardown do
    Rails.cache.delete('discord:digest_channel_id')
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform monta mensagem corretamente' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'
    create(:event, title: 'BGS 2026', event_type: 'bgs', start_date: 3.days.from_now)
    create(:external_catalog, source: 'tmdb', title: 'Popular Movie', popularity: 80.0)
    create(:news_article, title: 'Tech News', source: 'tech', link: 'https://example.com/tech', pub_date: 1.day.ago)

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordMessageChunker.stubs(:chunk).returns(['conteudo do digest'])
    DiscordApiClient.expects(:send_message).with('123456', 'conteudo do digest')

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform cria canal quando ENV não configurado e usa canal criado' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([])
    DiscordApiClient.expects(:create_text_channel).with('guild123', 'digest-updates').returns({ 'id' => 'channel456' })

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordMessageChunker.stubs(:chunk).returns(['conteudo do digest'])
    DiscordApiClient.expects(:send_message).with('channel456', 'conteudo do digest')

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform reutiliza canal existente por nome quando ENV não configurado' do
    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    DiscordApiClient.stubs(:get_guild_channels).returns([
      { 'id' => 'reused_channel', 'name' => 'digest-updates' }
    ])
    DiscordApiClient.expects(:create_text_channel).never

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordMessageChunker.stubs(:chunk).returns(['conteudo do digest'])
    DiscordApiClient.expects(:send_message).with('reused_channel', 'conteudo do digest')

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform usa cache de canal quando disponível' do
    Rails.cache.write('discord:digest_channel_id', 'cached_channel_999', expires_in: 30.days)

    mock_response = stub(content: 'Sugestões de conteúdo do LLM')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordMessageChunker.stubs(:chunk).returns(['conteudo do digest'])
    DiscordApiClient.expects(:send_message).with('cached_channel_999', 'conteudo do digest')
    DiscordApiClient.expects(:get_bot_guilds).never
    DiscordApiClient.expects(:get_guild_channels).never
    DiscordApiClient.expects(:create_text_channel).never

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform envia cada chunk como mensagem separada no mesmo canal' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    mock_response = stub(content: 'conteudo longo')
    AiRouter.stubs(:complete).returns(mock_response)

    fragmentos = ['fragmento 1', 'fragmento 2']
    DiscordMessageChunker.stubs(:chunk).returns(fragmentos)
    DiscordApiClient.expects(:send_message).with('123456', 'fragmento 1')
    DiscordApiClient.expects(:send_message).with('123456', 'fragmento 2')

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform envia mensagem unica quando chunker devolve um fragmento' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    mock_response = stub(content: 'conteudo curto')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscordMessageChunker.stubs(:chunk).returns(['conteudo curto'])
    DiscordApiClient.expects(:send_message).once.with('123456', 'conteudo curto')

    job = FridayIdeationJob.new
    job.perform
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

test 'perform formata sugestoes quando LLM devolve bloco JSON' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    json_content = <<~JSON
      ```json
      {
        "sugestoes_de_conteudo": [
          {
            "titulo": "Top 5 Games",
            "descricao": "Guia da semana.",
            "formatos_sugeridos": ["Reels", "TikTok"]
          }
        ]
      }
      ```
    JSON

    mock_response = stub(content: json_content)
    AiRouter.stubs(:complete).returns(mock_response)

    sent_message = nil
    DiscordApiClient.stubs(:send_message).with do |_channel, msg|
      sent_message = msg
      true
    end

    job = FridayIdeationJob.new
    job.perform

    assert_not_nil sent_message
    assert_includes sent_message, "**Sugestões de conteúdo:**\n1. **Top 5 Games** — Guia da semana. Formatos: Reels, TikTok"
    refute_includes sent_message, '```json'
    refute_includes sent_message, 'sugestoes_de_conteudo'
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform preserva sugestoes quando LLM devolve texto puro' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    plain_content = "1. **Ideia Texto** — Detalhes em texto puro."
    mock_response = stub(content: plain_content)
    AiRouter.stubs(:complete).returns(mock_response)

    sent_message = nil
    DiscordApiClient.stubs(:send_message).with do |_channel, msg|
      sent_message = msg
      true
    end

    job = FridayIdeationJob.new
    job.perform

    assert_not_nil sent_message
    assert_includes sent_message, "**Sugestões de conteúdo:**\n1. **Ideia Texto** — Detalhes em texto puro."
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end
end

