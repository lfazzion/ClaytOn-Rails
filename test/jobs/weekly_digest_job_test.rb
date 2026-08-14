# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/services/discord_message_chunker'
require_relative '../../app/jobs/weekly_digest_job'

class WeeklyDigestJobTest < ActiveSupport::TestCase
  test 'perform monta mensagem com delta de seguidores, top/bottom por scored_at e alertas' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    p1 = create(:social_profile, platform: 'youtube', platform_username: 'user1', display_name: 'User One', followers_count: 10_000, last_collected_at: 1.hour.ago)
    create(:profile_snapshot, social_profile: p1, followers_count: 9_500, recorded_at: 7.days.ago)

    p2 = create(:social_profile, platform: 'twitter', platform_username: 'user2', display_name: 'User Two', followers_count: 500, last_collected_at: 3.days.ago)

    create(:social_post, social_profile: p1, post_type: 'video', views_count: 100_000, performance_score: 2.5, performance_band: 'excelente', scored_at: 2.days.ago, posted_at: 10.days.ago)
    create(:social_post, social_profile: p1, post_type: 'video', views_count: 100, performance_score: -1.5, performance_band: 'ruim', scored_at: 2.days.ago, posted_at: 12.days.ago)

    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal 1, sent_messages.size
    msg = sent_messages.first
    assert_includes msg, 'Digest Semanal'
    assert_includes msg, '+500'

    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end


  # Achado 5 (PR #36): o job DELEGA o chunking ao DiscordMessageChunker
  # (helper único). O algoritmo migrou para o unit test do chunker
  # (test/services/discord_message_chunker_test.rb) — lá o limite é verificado
  # como <= 1900, mais estrito que o <= 2000 deste teste antigo. Aqui fica o
  # contrato de integração: 1 chamada ao helper + 1 send_message por chunk
  # devolvido (mensagem longa → 2 chunks → 2 envios).
  test 'perform delega chunking ao DiscordMessageChunker devolvendo multiplos chunks' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    DiscordMessageChunker.expects(:chunk).returns(['chunk_um', 'chunk_dois'])

    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal ['chunk_um', 'chunk_dois'], sent_messages,
                 'job deve enviar 1 mensagem por chunk devolvido pelo helper'
    assert sent_messages.size > 1, 'mensagem longa deve gerar multiplos envios'

    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
  end

  test 'perform cria canal se não existir' do
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')

    DiscordApiClient.stubs(:get_bot_guilds).returns([{ 'id' => 'guild123' }])
    # DigestChannel (rodada 10): verifica canais existentes antes de criar
    DiscordApiClient.stubs(:get_guild_channels).returns([])
    DiscordApiClient.stubs(:create_text_channel).returns({ 'id' => 'channel456' })
    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal 1, sent_messages.size
  end

  test 'perform omite a seção Menores quando há poucos posts (evita duplicar o top)' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    profile = create(:social_profile, platform: 'twitter', platform_username: 'fewposts')
    (1..3).each do |i|
      create(:social_post, social_profile: profile, post_type: 'video', views_count: 100,
                           performance_score: i.to_f, performance_band: 'bom',
                           scored_at: 2.days.ago, content: "video #{i}")
    end

    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal 1, sent_messages.size
    msg = sent_messages.first
    assert_includes msg, '**🚀 Top Desempenhos Apurados na Semana:**'
    refute_includes msg, '**🔻 Menores Desempenhos Apurados na Semana:**'
    assert_equal 3, msg.scan('(z:').size, 'com <= 6 posts só o top 3 deve aparecer'
  end

  test 'perform mostra apenas os 3 piores na seção Menores quando há mais de 6 posts' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    profile = create(:social_profile, platform: 'twitter', platform_username: 'manyposts')
    (1..7).each do |i|
      create(:social_post, social_profile: profile, post_type: 'video', views_count: 100,
                           performance_score: i.to_f, performance_band: 'bom',
                           scored_at: 2.days.ago, content: "video #{i}")
    end

    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal 1, sent_messages.size
    msg = sent_messages.first
    assert_includes msg, '**🔻 Menores Desempenhos Apurados na Semana:**'
    assert_includes msg, '(z: 1.0)'
    assert_includes msg, '(z: 2.0)'
    assert_includes msg, '(z: 3.0)'
    refute_includes msg, '(z: 4.0)'
    assert_equal 6, msg.scan('(z:').size, 'top 3 + menores 3, sem repetição'
  end

  test 'perform usa — quando followers_count é nil' do
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = '123456'

    create(:social_profile, platform: 'twitter', platform_username: 'nilfollowers',
                            display_name: 'Nil Fol', followers_count: nil)

    sent_messages = []
    DiscordApiClient.stubs(:send_message).with do |_channel_id, msg|
      sent_messages << msg
      true
    end

    job = WeeklyDigestJob.new
    job.perform

    assert_equal 1, sent_messages.size
    msg = sent_messages.first
    assert_includes msg, ': — (atual)'
    refute_includes msg, ': 0 (atual)'
  end

end

