# frozen_string_literal: true

require 'open3'
require 'json'
require 'timeout'

module ScrapingServices
  class YoutubeScraperService
    class << self
      def extract_channel_metadata(channel_url, proxy: nil, timeout: 240)
        command = build_metadata_command(channel_url, proxy)
        output, _, status = execute_yt_dlp(command, timeout: timeout)

        return nil unless status.success? && output.strip.present?

        # video_count fica nil aqui: a contagem real enumera todas as entradas
        # das 3 abas (--flat-playlist; medido 72,5s p/ 5259 vídeos) e ficou sob
        # demanda — quem precisar chama `total_video_count` explicitamente.
        parse_metadata(JSON.parse(output.strip))
      rescue Timeout::Error => e
        Rails.logger.error "[YoutubeScraperService] Timeout ao extrair metadata: #{e.message}"
        raise
      rescue JSON::ParserError => e
        Rails.logger.error "[YoutubeScraperService] JSON inválido ao extrair metadata: #{e.message}"
        nil
      rescue StandardError => e
        Rails.logger.error "[YoutubeScraperService] Erro ao extrair metadata: #{e.message}"
        nil
      end

      def extract_videos_detailed(channel_url, limit: 10, proxy: nil, cookies_path: nil)
        command = build_videos_command(channel_url, limit, proxy, cookies_path: cookies_path)
        output, _, status = execute_yt_dlp(command)

        if status.success? && output.strip.present?
          [parse_video_list(output.strip), false]
        else
          [extract_videos_flat(channel_url, limit: limit, proxy: proxy, cookies_path: cookies_path), true]
        end
      rescue StandardError => e
        Rails.logger.error "[YoutubeScraperService] Erro ao extrair videos detalhados: #{e.message}"
        [extract_videos_flat(channel_url, limit: limit, proxy: proxy, cookies_path: cookies_path), true]
      end

      # Soma o total de vídeos do canal pelas abas /videos, /shorts e /streams.
      # NÃO é chamado por extract_channel_metadata: cada aba é enumerada por
      # inteiro (--flat-playlist --dump-single-json), medido 72,5s para 5259
      # entradas em uma única aba — caro demais para rodar em toda extração.
      # Público para chamadas sob demanda; o chamador arca com o custo.
      def total_video_count(channel_url, proxy)
        counts = TABS.map { |tab| count_tab(channel_url, tab, proxy) }.compact
        return nil if counts.empty?

        counts.sum
      end

      private

      def extract_videos_flat(channel_url, limit: 10, proxy: nil, cookies_path: nil)
        command = build_videos_flat_command(channel_url, limit, proxy, cookies_path: cookies_path)
        output, _, status = execute_yt_dlp(command)

        return [] unless status.success? && output.strip.present?

        parse_video_list(output.strip)
      rescue StandardError => e
        Rails.logger.error "[YoutubeScraperService] Erro ao extrair videos flat: #{e.message}"
        []
      end

      # Sem isso, YouTube serve títulos auto-traduzidos para o inglês
      # (ex.: "CERATOCONE..." vira "Keratoconus...") quando o User-Agent/IP
      # do contêiner não for pt-BR. hl=idioma da UI, gl=geo.
      #
      # `persist_hl=1` é necessário para forçar títulos originais em listagens
      # (/videos, /shorts), MAS quebra a resposta da raiz do canal com
      # `--playlist-items 0` (channel_follower_count vem null). Por isso
      # `localize(url, persist: true)` só nas listagens.
      LOCALE_BASE = "hl=pt-BR&gl=BR"

      def localize(url, persist: false)
        params = persist ? "#{LOCALE_BASE}&persist_hl=1" : LOCALE_BASE
        separator = url.include?("?") ? "&" : "?"
        "#{url}#{separator}#{params}"
      end

      def build_metadata_command(channel_url, proxy)
        # --playlist-items 0: não itera nenhum vídeo, mas o yt-dlp ainda parseia
        # a página do canal e retorna o objeto-pai com channel_follower_count,
        # channel_id, description, etc. Mais confiável que --flat-playlist --playlist-items 1
        # que retornava campos do primeiro vídeo (com os campos do canal como null).
        cmd = [
          "yt-dlp",
          "--skip-download",
          "--dump-single-json",
          "--playlist-items", "0",
          localize(channel_url)
        ]
        cmd += ["--proxy", proxy] if proxy.present?
        cmd
      end

      def build_videos_command(channel_url, limit, proxy, cookies_path: nil)
        videos_url = localize("#{channel_url}/videos", persist: true)
        cmd = [
          "yt-dlp",
          "--dump-json",
          "--no-download",
          "--playlist-end", limit.to_s,
          "--js-runtimes", "deno:/usr/local/bin/deno"
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd << videos_url
        cmd
      end

      def build_videos_flat_command(channel_url, limit, proxy, cookies_path: nil)
        videos_url = localize("#{channel_url}/videos", persist: true)
        cmd = [
          "yt-dlp",
          "--flat-playlist",
          "--dump-json",
          "--no-download",
          "--playlist-end", limit.to_s
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd << videos_url
        cmd
      end

      def execute_yt_dlp(command, timeout: 240)
        Timeout.timeout(timeout) { Open3.capture3(*command) }
      end

      def parse_metadata(data)
        thumb = best_thumbnail(data)
        {
          channel_id:       data['channel_id'] || data['playlist_channel_id'] || data['id'],
          title:            data['channel'] || data['uploader'] || data['playlist_channel'] || data['playlist_uploader'] || data['title'],
          description:      data['description'],
          subscriber_count: data['channel_follower_count'],
          # playlist_count da raiz conta ABAS (ex.: 3), não vídeos; só
          # total_video_count (sob demanda) preenche video_count.
          video_count:      nil,
          thumbnail_url:    thumb,
          avatar_url:       thumb
        }
      end

      # `playlist_count` da raiz do canal conta abas (videos, shorts, streams),
      # não vídeos. A contagem real por aba é feita por count_tab (sob demanda).
      TABS = %w[videos shorts streams].freeze

      def count_tab(channel_url, tab, proxy)
        cmd = ['yt-dlp', '--flat-playlist', '--dump-single-json', '--skip-download', localize("#{channel_url}/#{tab}", persist: true)]
        cmd += ['--proxy', proxy] if proxy.present?
        output, _, status = execute_yt_dlp(cmd)
        return nil unless status.success? && output.strip.present?

        JSON.parse(output.strip)['playlist_count']
      rescue StandardError => e
        Rails.logger.warn "[YoutubeScraperService] Falha ao contar tab #{tab}: #{e.message}"
        nil
      end

      # O objeto-pai retornado pelo --dump-single-json traz `thumbnail` como nil
      # mas inclui um array `thumbnails` com até 9 resoluções. Seleciona a maior.
      def best_thumbnail(data)
        thumbs = Array(data['thumbnails']).select { |t| t['url'].present? }
        return data['thumbnail'] if thumbs.empty?

        thumbs.max_by { |t| t['width'].to_i }&.fetch('url', nil)
      end

      def parse_video_list(output)
        videos = []
        output.each_line do |line|
          next if line.strip.empty?

          data = JSON.parse(line.strip)
          videos << {
            platform_post_id: data['id'],
            title: data['title'],
            post_type: 'video',
            posted_at: data['upload_date'] ? Date.parse(data['upload_date']) : nil,
            views_count: data['view_count'],
            likes_count: data['like_count'],
            comments_count: data['comment_count'],
            thumbnail_url: data['thumbnail'],
            video_url: data['url'] || "https://www.youtube.com/watch?v=#{data['id']}"
          }
        rescue JSON::ParserError
          next
        end
        videos
      end
    end
  end
end
