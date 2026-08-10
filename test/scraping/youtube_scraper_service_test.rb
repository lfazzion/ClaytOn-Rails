# frozen_string_literal: true

require 'test_helper'

class YoutubeScraperServiceTest < ActiveSupport::TestCase
  test 'extract_channel_metadata returns valid data when yt-dlp available' do
    skip 'yt-dlp not installed' unless system('which yt-dlp > /dev/null 2>&1')

    result = ScrapingServices::YoutubeScraperService.extract_channel_metadata(
      'https://www.youtube.com/@YouTube'
    )

    skip 'YouTube blocked unauthenticated request' if result.nil?

    assert_not_nil result
    assert result[:channel_id].present?, 'channel_id deve estar presente'
    assert result[:title].present?, 'title deve estar presente'
    assert_not_nil result[:subscriber_count], 'subscriber_count não deve ser nil com --playlist-items 0'
  end

  test 'extract_videos_detailed parses output correctly' do
    skip 'yt-dlp not installed' unless system('which yt-dlp > /dev/null 2>&1')

    videos, _fallback = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      'https://www.youtube.com/@YouTube',
      limit: 3
    )

    assert videos.is_a?(Array)
    return if videos.empty?

    video = videos.first
    assert video[:platform_post_id].present?
    assert video[:post_type] == 'video'
  end

  test 'extract_videos_detailed retorna fallback false quando caminho detalhado funciona' do
    fake_status = Struct.new(:success?).new(true)
    json_output = "{\"id\":\"vid1\",\"title\":\"Video 1\",\"view_count\":100,\"like_count\":10,\"comment_count\":5}\n"
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).returns([json_output, '', fake_status])

    videos, fallback = ScrapingServices::YoutubeScraperService.extract_videos_detailed('https://www.youtube.com/@TeGeCe', limit: 1)

    assert_equal 1, videos.size
    refute fallback, 'fallback deve ser false quando o caminho detalhado tem sucesso'
  end

  test 'extract_videos_detailed cai no fallback e retorna fallback true quando caminho detalhado falha' do
    fake_fail_status = Struct.new(:success?).new(false)
    fake_success_status = Struct.new(:success?).new(true)
    flat_output = "{\"id\":\"vid1\",\"title\":\"Video 1\",\"view_count\":100}\n"

    ScrapingServices::YoutubeScraperService.stubs(:build_videos_command).returns(['yt-dlp', 'detailed'])
    ScrapingServices::YoutubeScraperService.stubs(:build_videos_flat_command).returns(['yt-dlp', 'flat'])

    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).with(['yt-dlp', 'detailed']).returns(['', 'Sign in to confirm', fake_fail_status])
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).with(['yt-dlp', 'flat']).returns([flat_output, '', fake_success_status])

    videos, fallback = ScrapingServices::YoutubeScraperService.extract_videos_detailed('https://www.youtube.com/@TeGeCe', limit: 1)

    assert_equal 1, videos.size
    assert fallback, 'fallback deve ser true quando caminho detalhado falha'
  end

  test 'parse_metadata extrai subscriber_count de channel_follower_count' do
    data = {
      'channel_id' => 'UCn8Szh52CH89yEOItjCI6iw',
      'channel' => 'TeGeCe',
      'channel_follower_count' => 230_000,
      'playlist_count' => 2,
      'description' => 'Descrição do canal',
      'thumbnails' => [
        { 'url' => 'https://example.com/thumb_small.jpg', 'width' => 88, 'height' => 88 },
        { 'url' => 'https://example.com/thumb_large.jpg', 'width' => 900, 'height' => 900 }
      ]
    }

    result = ScrapingServices::YoutubeScraperService.send(:parse_metadata, data)

    assert_equal 'UCn8Szh52CH89yEOItjCI6iw', result[:channel_id]
    assert_equal 'TeGeCe', result[:title]
    assert_equal 230_000, result[:subscriber_count]
    # playlist_count da raiz conta ABAS (videos/shorts/streams), não vídeos:
    # parse_metadata não pode preenchê-lo — só total_video_count (sob demanda).
    assert_nil result[:video_count]
    assert_equal 'https://example.com/thumb_large.jpg', result[:thumbnail_url], 'deve selecionar o thumbnail de maior resolução'
    assert_equal result[:thumbnail_url], result[:avatar_url]
  end

  test 'parse_metadata handles missing fields' do
    data = { 'id' => 'UC123', 'title' => 'Test Channel' }
    result = ScrapingServices::YoutubeScraperService.send(:parse_metadata, data)

    assert_equal 'UC123', result[:channel_id]
    assert_equal 'Test Channel', result[:title]
    assert_nil result[:subscriber_count]
  end

  test 'best_thumbnail retorna thumbnail direto quando array vazio' do
    data = { 'thumbnail' => 'https://example.com/thumb.jpg', 'thumbnails' => [] }
    result = ScrapingServices::YoutubeScraperService.send(:best_thumbnail, data)
    assert_equal 'https://example.com/thumb.jpg', result
  end

  test 'best_thumbnail retorna maior resolucao do array' do
    data = {
      'thumbnail' => nil,
      'thumbnails' => [
        { 'url' => 'https://example.com/small.jpg', 'width' => 48 },
        { 'url' => 'https://example.com/large.jpg', 'width' => 2560 },
        { 'url' => 'https://example.com/medium.jpg', 'width' => 240 }
      ]
    }
    result = ScrapingServices::YoutubeScraperService.send(:best_thumbnail, data)
    assert_equal 'https://example.com/large.jpg', result
  end

  test 'parse_video_list handles empty output' do
    videos = ScrapingServices::YoutubeScraperService.send(:parse_video_list, '')
    assert_empty videos
  end

  test 'propagates Timeout::Error when command times out' do
    Timeout.expects(:timeout).raises(Timeout::Error)

    assert_raises(Timeout::Error) do
      ScrapingServices::YoutubeScraperService.extract_channel_metadata(
        'https://www.youtube.com/@YouTube'
      )
    end
  end

  test 'count_tab parses playlist_count from flat-playlist output' do
    fake_status = Struct.new(:success?).new(true)
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).returns(['{"playlist_count":62}', '', fake_status])

    result = ScrapingServices::YoutubeScraperService.send(:count_tab, 'https://www.youtube.com/@TeGeCe', 'videos', nil)
    assert_equal 62, result
  end

  test 'count_tab returns nil when yt-dlp fails (e.g. tab does not exist)' do
    fake_status = Struct.new(:success?).new(false)
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).returns(['', 'ERROR: tab not found', fake_status])

    result = ScrapingServices::YoutubeScraperService.send(:count_tab, 'https://www.youtube.com/@TeGeCe', 'streams', nil)
    assert_nil result
  end

  test 'total_video_count somando videos + shorts + streams' do
    svc = ScrapingServices::YoutubeScraperService
    svc.stubs(:count_tab).with(anything, 'videos', anything).returns(62)
    svc.stubs(:count_tab).with(anything, 'shorts', anything).returns(90)
    svc.stubs(:count_tab).with(anything, 'streams', anything).returns(nil)

    assert_equal 152, svc.send(:total_video_count, 'https://www.youtube.com/@TeGeCe', nil)
  end

  test 'total_video_count retorna nil quando todas as abas falham' do
    svc = ScrapingServices::YoutubeScraperService
    svc.stubs(:count_tab).returns(nil)

    assert_nil svc.send(:total_video_count, 'https://www.youtube.com/@TeGeCe', nil)
  end

  test 'localize sem persist anexa hl+gl' do
    result = ScrapingServices::YoutubeScraperService.send(:localize, 'https://www.youtube.com/@TeGeCe')
    assert_equal 'https://www.youtube.com/@TeGeCe?hl=pt-BR&gl=BR', result
  end

  test 'localize com persist=true adiciona persist_hl=1' do
    result = ScrapingServices::YoutubeScraperService.send(:localize, 'https://www.youtube.com/@TeGeCe/videos', persist: true)
    assert_equal 'https://www.youtube.com/@TeGeCe/videos?hl=pt-BR&gl=BR&persist_hl=1', result
  end

  test 'localize usa & quando URL ja tem query' do
    result = ScrapingServices::YoutubeScraperService.send(:localize, 'https://www.youtube.com/@TeGeCe/videos?foo=1', persist: true)
    assert_equal 'https://www.youtube.com/@TeGeCe/videos?foo=1&hl=pt-BR&gl=BR&persist_hl=1', result
  end

  test 'build_metadata_command localiza a URL sem persist_hl (preserva follower_count)' do
    cmd = ScrapingServices::YoutubeScraperService.send(:build_metadata_command, 'https://www.youtube.com/@TeGeCe', nil)
    assert_includes cmd, 'https://www.youtube.com/@TeGeCe?hl=pt-BR&gl=BR'
    refute(cmd.any? { |a| a.include?('persist_hl=1') })
  end

  test 'build_videos_command localiza com persist_hl e deno js-runtimes sem remote-components' do
    cmd = ScrapingServices::YoutubeScraperService.send(:build_videos_command, 'https://www.youtube.com/@TeGeCe', 50, nil)
    assert_includes cmd, 'https://www.youtube.com/@TeGeCe/videos?hl=pt-BR&gl=BR&persist_hl=1'
    assert_includes cmd, '--js-runtimes'
    assert_includes cmd, 'deno:/usr/local/bin/deno'
    refute_includes cmd, '--remote-components'
    refute_includes cmd, 'ejs:github'
  end

  test 'build_videos_command e build_videos_flat_command incluem --cookies quando cookies_path informado' do
    cmd1 = ScrapingServices::YoutubeScraperService.send(:build_videos_command, 'https://www.youtube.com/@TeGeCe', 50, nil, cookies_path: '/tmp/cookies.txt')
    assert_includes cmd1, '--cookies'
    assert_includes cmd1, '/tmp/cookies.txt'

    cmd2 = ScrapingServices::YoutubeScraperService.send(:build_videos_flat_command, 'https://www.youtube.com/@TeGeCe', 50, nil, cookies_path: '/tmp/cookies.txt')
    assert_includes cmd2, '--cookies'
    assert_includes cmd2, '/tmp/cookies.txt'
  end
end
