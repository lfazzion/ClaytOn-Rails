# frozen_string_literal: true

require 'open3'
require 'json'
require 'timeout'

module ScrapingServices
  class YoutubeScraperService
    # Prova tipada de rejeição de sessão. B4: a transição para coleta SEM
    # cookie só é legítima após UMA prova TÍPADA de sessão rejeitada — ou a
    # externa (Fetcher::CookieJar::Expired, no chamador) ou esta, levada aqui
    # quando o próprio serviço lê o stderr e detecta "cookies are no longer
    # valid". Os DOIS caminhos de sessão rejeitada passam pelo MESMO ponto de
    # transição (`transition_without_cookie`), e é por este tipo que a
    # transição é auditável — nunca por inferção de solta string em dois
    # lugares.
    class SessionRejected < StandardError
      attr_reader :cause_name

      def initialize(cause_name = "session_rejected")
        @cause_name = cause_name
        super("sessão rejeitada (#{cause_name}) — coleta sem cookie é a única transição legítima")
      end
    end

    # Classes de erro de REDE que podem ser levantadas no caminho do yt-dlp
    # (o processo externo falha e o Ruby expõe um Errno/Socket). B7:
    # resgatadas ANTES do rescue genérico de `StandardError` e mapeadas para a
    # causa `network` — o rescue largo as converteria em `unknown`. O processo
    # é subprocess (Open3.capture3), então rede vira Errno/SocketError, NUNCA
    # Faraday (client HTTP Ruby, que este caminho não usa). `filter_map` +
    # rescue espelha o desenho defensivo de RECOVERABLE_SCRAPER_ERRORS no job:
    # constância ausente no ambiente não quebra o boot.
    NETWORK_ERRORS = %w[
      SocketError
      Net::ReadTimeout Net::OpenTimeout Net::HTTPError
      Errno::ECONNRESET Errno::ECONNREFUSED Errno::ETIMEDOUT
      Errno::EHOSTUNREACH Errno::ENETUNREACH Errno::EADDRNOTAVAIL
      Errno::EAI_AGAIN Errno::EPIPE
      OpenSSL::SSL::SSLError
    ].filter_map { |name| Object.const_get(name) rescue nil }.freeze

    # B10: fonte ÚNICA dos padrões — lib/scraping/failure_cause_classify.rb,
    # consumida pelo serviço (este require) e pelo canário (bin/canario-youtube.sh,
    # via `ruby -r <este arquivo>`). A divergência do canário antigo ("sign in to
    # confirm"||"bot" sem fronteiras; `members-only` hifenizado não reconhecido)
    # ficou impossível de reocorrer: os DOIS lados executam o MESMO código.
    require_relative '../failure_cause_classify'

    # Causas reconhecidas pelo classificador (fonte única no módulo;
    # enumerada aqui só para documentação/validação do contrato de 3-tupla
    # que o job e o canário leem).
    FAILURE_CAUSES = %w[bot_check members_only timeout network session_rejected unknown].freeze

    # Erros de parse do output (JSON malformado) do yt-dlp: mapeados para a
    # causa `unknown` (parser não é uma causa nomeada do item 3, e NUNCA
    # libera fallback sem-cookie). O parser do JSON do Ruby expõe
    # `JSON::ParserError` (subclasse de `JSON::JSONError`); é a única classe
    # de parse que o caminho do yt-dlp pode levantar (JSON.parse em
    # parse_metadata / parse_video_list).
    PARSE_ERRORS = [JSON::ParserError, JSON::JSONError].freeze

    class << self
      # Cliente do player do YouTube para o extrator.
      #
      # Escolha: `mweb`. Motivo: em datacenter, `web`/`web_embedded` caem com
      # bloqueio de bot/PO Token; `mweb` é o mais tolerante para sessão com
      # cookies em headless/VM. O canário mede se esta escolha altera o
      # resultado na VM do maestro.
      PLAYER_CLIENT_ARGS = ["--extractor-args", "youtube:player_client=mweb"].freeze
      # B8a: devolve [metadata, causa]. Antes descartava o stderr
      # (`output, _, status`) e devolvia só `nil` — o job gravava `degraded`
      # com alerta genérico, e bot-check/membros/rede/sessão rejeitada no
      # caminho de metadata ficavam SEM causa. Agora captura o stderr,
      # classifica a causa e a PROPAGA: falha → [nil, causa nomeada];
      # sucesso → [dados, nil]. `Timeout::Error` continua propagando (o
      # AddProfileTool usa timeout: 8 e trata "validação demorou" — ver
      # profile_management_tools.rb).
      def extract_channel_metadata(channel_url, proxy: nil, timeout: 240, cookies_path: nil)
        command = build_metadata_command(channel_url, proxy, cookies_path: cookies_path)
        output, stderr, status = execute_yt_dlp(command, timeout: timeout)

        unless status.success? && output.strip.present?
          cause, = classify_failure_cause(stderr, output)
          return [nil, cause]
        end

        # video_count fica nil aqui: a contagem real enumera todas as entradas
        # das 3 abas (--flat-playlist; medido 72,5s p/ 5259 vídeos) e ficou sob
        # demanda — quem precisar chama `total_video_count` explicitamente.
        [parse_metadata(JSON.parse(output.strip)), nil]
      rescue Timeout::Error => e
        Rails.logger.error "[YoutubeScraperService] Timeout ao extrair metadata: #{e.message}"
        raise
      rescue *PARSE_ERRORS => e
        Rails.logger.error "[YoutubeScraperService] JSON inválido ao extrair metadata: #{e.message}"
        [nil, 'unknown']
      rescue StandardError => e
        Rails.logger.error "[YoutubeScraperService] Erro ao extrair metadata: #{e.message}"
        [nil, 'unknown']
      end

      def extract_videos_detailed(channel_url, limit: 10, proxy: nil, cookies_path: nil)
        videos_limit, shorts_limit = split_limits(limit)

        videos_cmd = build_videos_command(channel_url, videos_limit, proxy, cookies_path: cookies_path)
        videos_output, videos_stderr, videos_status = execute_yt_dlp(videos_cmd)

        # B8b: separa "aba /shorts ausente/vazia" de "falha operacional". Se o
        # /videos teve dados, o /shorts é apenas um ENRIQUECIMENTO — a sua
        # ausência inocente (canal sem a aba) segue sucesso; uma falha
        # OPERACIONAL (bot-check, rede, timeout, membros, sessão) vira parcial
        # nomeado, e NÃO mais "success" silencioso (o furo que B8b fechou).
        if videos_status.success? && videos_output.strip.present?
          videos = parse_video_list(videos_output)
          if shorts_limit.positive?
            shorts_cmd = build_shorts_command(channel_url, shorts_limit, proxy, cookies_path: cookies_path)
            shorts_output, shorts_stderr, shorts_status = execute_yt_dlp(shorts_cmd)
            return shorts_result(shorts_output, shorts_stderr, shorts_status, videos)
          end
          # Orçamento de shorts zero: nada a enriquecer, /videos segue valendo.
          return [videos, false, nil]
        end

        # /videos FALHOU: classifica a causa a partir do stderr.
        cause, = classify_failure_cause(videos_stderr, '')
        if cause == "session_rejected"
          # B4: prova TÍPADA — levanta a rejeição e o ÚNICO ponto de transição
          # sem cookie (transition_without_cookie) é quem a captura. Nenhum
          # outro caminho chama cookies_path: nil.
          raise SessionRejected.new("session_rejected")
        end
        # bot_check / members_only / timeout / network / unknown: run parcial
        # nomeado, mantendo o jar. NUNCA cai em coleta sem-cookie.
        [[], false, cause]
      rescue SessionRejected => proof
        transition_without_cookie(channel_url, limit: limit, proxy: proxy, proof: proof)
      rescue Timeout::Error
        # B7: timeout REAL (Timeout.timeout no execute_yt_dlp) vira parcial
        # nomeado 'timeout' — antes caía no rescue genérico → 'unknown'.
        Rails.logger.error '[YoutubeScraperService] Timeout em extract_videos_detailed — parcial nomeado (timeout)'
        [[], false, 'timeout']
      rescue *NETWORK_ERRORS => e
        # B7: erro de REDE (Errno/Socket) antes do rescue genérico.
        Rails.logger.error "[YoutubeScraperService] Erro de rede em extract_videos_detailed (#{e.class}) — parcial nomeado (network)"
        [[], false, 'network']
      rescue StandardError => e
        # Último recurso: bug/contrato não-classificável → 'unknown' parcial
        # NOMEADO mantendo o jar (antes era um flat com cookie 'unknown').
        Rails.logger.error "[YoutubeScraperService] Erro não-classificável em extract_videos_detailed (#{e.class}): #{e.message}"
        [[], false, 'unknown']
      end

      # B4: ÚNICO ponto de transição para coleta sem cookie. É auditável
      # porque só a prova TÍPADA SessionRejected (acima) — ou a
      # Fetcher::CookieJar::Expired do CHAMADOR, que o serviço NUNCA vê —
      # abre este caminho. É aqui que os dois caminhos de sessão rejeitada
      # (texto-inferido no serviço; Expired no job) se encontram: o job, ao
      # capturar o Expired, chama extract_videos_detailed já com cookies_path:
      # nil (o jar expirou e não há o quê manter); o texto-inferido levanta
      # SessionRejected e deságua em transition_without_cookie.
      def transition_without_cookie(channel_url, limit:, proxy:, proof:)
        flat_videos = extract_videos_flat(channel_url, limit: limit, proxy: proxy, cookies_path: nil)
        [flat_videos, true, proof.cause_name]
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

      # B8b/B8: monta o resultado quando o /videos teve dados e processa a
      # aba /shorts. Regra de causa (o bloqueador 8 fechou o falso sucesso):
      #   * causa NIL SÓ com status.success? E saída vazia/ausente comprovada
      #     (canal sem a aba /shorts — ausência inocente, /videos segue valendo);
      #   * QUALQUER status de falha vira PARCIAL NOMEADO, usando a causa do
      #     stderr; quando o stderr não casa nenhum padrão, 'unknown' é o
      #     fallback — NUNCA um "success" silencioso (o furo que B8 fechou).
      def shorts_result(shorts_output, shorts_stderr, shorts_status, videos)
        # Sucesso com saída vazia/ausente comprovada: a única situação que
        # devolve causa nil (aba ausente — canal sem /shorts).
        if shorts_status.success? && shorts_output.strip.empty?
          Rails.logger.warn '[YoutubeScraperService] Aba /shorts ausente/vazia (sucesso com saída vazia); seguindo apenas com /videos'
          return [videos, false, nil]
        end

        if shorts_status.success?
          # Sucesso COM dados: mescla /videos + /shorts, causa nil.
          return [videos + parse_video_list(shorts_output), false, nil]
        end

        # Status de FALHA: sempre parcial nomeado. 'unknown' é o fallback quando
        # o stderr não casa nenhum padrão reconhecido — uma falha operacional
        # com stderr não reconhecido NUNCA vira "success" silencioso.
        shorts_cause, = classify_failure_cause(shorts_stderr, shorts_output)
        Rails.logger.warn "[YoutubeScraperService] Aba /shorts com falha operacional (#{shorts_cause}); seguindo com /videos como parcial nomeado"
        [videos, false, shorts_cause]
      end

      def extract_videos_flat(channel_url, limit: 10, proxy: nil, cookies_path: nil)
        videos_limit, shorts_limit = split_limits(limit)

        videos_cmd = build_videos_flat_command(channel_url, videos_limit, proxy, cookies_path: cookies_path)
        videos_output, _, videos_status = execute_yt_dlp(videos_cmd)

        return [] unless videos_status.success? && videos_output.strip.present?

        videos = parse_video_list(videos_output)
        return videos unless shorts_limit.positive?

        shorts_cmd = build_shorts_flat_command(channel_url, shorts_limit, proxy, cookies_path: cookies_path)
        shorts_output, _, shorts_status = execute_yt_dlp(shorts_cmd)
        # Mesma semântica do caminho detalhado: /shorts vazio (canal sem aba)
        # não zera a coleta flat — segue só com os vídeos; só a falha do
        # /videos (tratada acima) degrada.
        shorts = if shorts_status.success? && shorts_output.strip.present?
                   parse_video_list(shorts_output)
                 else
                   Rails.logger.warn "[YoutubeScraperService] Aba /shorts sem dados no caminho flat; seguindo apenas com /videos"
                   []
                 end

        videos + shorts
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

      def build_metadata_command(channel_url, proxy, cookies_path: nil)
        cmd = [
          "yt-dlp",
          "--skip-download",
          "--dump-single-json",
          "--playlist-items", "0",
          localize(channel_url)
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd += PLAYER_CLIENT_ARGS
        cmd
      end

      def build_videos_command(channel_url, limit, proxy, cookies_path: nil)
        videos_url = localize("#{channel_url}/videos", persist: true)
        cmd = [
          "yt-dlp",
          "--dump-json",
          "--no-download",
          "--playlist-end", limit.to_s,
          "--sleep-interval", "8",
          "--max-sleep-interval", "20",
          "--js-runtimes", "deno:/usr/local/bin/deno"
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd += PLAYER_CLIENT_ARGS
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
          "--playlist-end", limit.to_s,
          "--sleep-interval", "8",
          "--max-sleep-interval", "20"
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd += PLAYER_CLIENT_ARGS
        cmd << videos_url
        cmd
      end

      # Achado 12 — a aba /shorts nunca era raspada. Mesmo padrão do
      # build_videos_command: localize com persist_hl (títulos originais em
      # pt-BR) + deno como js-runtime (evita o download embutido de runtime).
      def build_shorts_command(channel_url, limit, proxy, cookies_path: nil)
        shorts_url = localize("#{channel_url}/shorts", persist: true)
        cmd = [
          "yt-dlp",
          "--dump-json",
          "--no-download",
          "--playlist-end", limit.to_s,
          "--sleep-interval", "8",
          "--max-sleep-interval", "20",
          "--js-runtimes", "deno:/usr/local/bin/deno"
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd += PLAYER_CLIENT_ARGS
        cmd << shorts_url
        cmd
      end

      def build_shorts_flat_command(channel_url, limit, proxy, cookies_path: nil)
        shorts_url = localize("#{channel_url}/shorts", persist: true)
        cmd = [
          "yt-dlp",
          "--flat-playlist",
          "--dump-json",
          "--no-download",
          "--playlist-end", limit.to_s,
          "--sleep-interval", "8",
          "--max-sleep-interval", "20"
        ]
        cmd += ["--cookies", cookies_path] if cookies_path.present?
        cmd += ["--proxy", proxy] if proxy.present?
        cmd += PLAYER_CLIENT_ARGS
        cmd << shorts_url
        cmd
      end

      # Split do orçamento da coleta: 2/3 do limit vai para a aba /videos e
      # 1/3 para /shorts (o orçamento total de ~30 vídeos vira 20+10; 240s
      # de timeout cobrem ~30+15 vídeos a ~3s). shorts fica com o resto para
      # que limit pequeno (ex.: 1) nunca deixe a aba principal sem orçamento.
      VIDEOS_FRACTION = 2.0 / 3

      def split_limits(limit)
        videos_limit = (limit * VIDEOS_FRACTION).round
        [videos_limit, limit - videos_limit]
      end

      # Executa o yt-dlp e CAPTURA o stderr (2º retorno do Open3.capture3 —
      # a assinatura é [stdout, stderr, status], então o status é o 3º).
      #
      # Incidente 14/08: o caminho anterior descartava o stderr
      # (`output, _, status = Open3.capture3(*command)`), então quando o
      # ScrapeYoutubeJob caía no fallback flat-playlist por falha do caminho
      # detalhado, o ScrapingFailureAlertJob("partial_collection") disparava sem
      # NENHUMA pista do motivo (extrator JS/deno, bot-check, rate-limit, DOM
      # mudou). O diagnóstico depende exatamente desse stderr — ele é registrado
      # em falha (Rails.logger.error) e em warning quando o comando termina ok
      # mas fala algo, ex.: "cookies are no longer valid" vem como WARNING mesmo
      # com exit 0. O stderr é truncado a STDERR_LOG_LIMIT chars (MENOR 4): o
      # yt-dlp despeja URLs/progresso que enchem o log.
      STDERR_LOG_LIMIT = 2000

      def execute_yt_dlp(command, timeout: 600)
        output, stderr, status = Timeout.timeout(timeout) { Open3.capture3(*command) }

        stderr_msg = stderr.strip
        if stderr_msg.present?
          logged = truncate_stderr(stderr_msg)
          if status.success?
            Rails.logger.warn "[YoutubeScraperService] yt-dlp (ok): #{logged}"
          else
            Rails.logger.error "[YoutubeScraperService] yt-dlp falhou (exit #{status.exitstatus}): #{logged}"
          end
        end

        [output, stderr, status]
      end

      # Trunca mensagens de stderr longas para STDERR_LOG_LIMIT chars, preservando
      # o prefixo (onde costuma estar a causa raiz) e sinalizando o corte. O
      # limite é inclusivo: stderr de exatamente STDERR_LOG_LIMIT chars passa
      # íntegro; só acima disso é truncado.
      def truncate_stderr(message)
        return message if message.length <= STDERR_LOG_LIMIT

        "#{message[0, STDERR_LOG_LIMIT]}... [truncado, #{message.length} chars]"
      end

      # B10: delegação ao classificador de fonte ÚNICA
      # (lib/scraping/failure_cause_classify.rb) — o MESMO módulo que o canário
      # executa. Junta stderr+stdout, baixa para minúsculas (exatamente o que o
      # canário faz em bash) e devolve o par [causa, detalhes] do módulo. A
      # ordem de prioridade (semântico ganha do transporte) e as fronteiras
      # ("sign in to confirm your age" NÃO é bot; "robot"/"hobbit" NÃO são)
      # vivem no módulo — não há mais duas implementações para divergirem.
      def classify_failure_cause(stderr, stdout)
        message = [stderr, stdout].compact.join("\n").downcase
        FailureCauseClassify.classify_failure_cause(message)
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
          url_str = data['webpage_url'] || data['url'] || ''
          post_type = url_str.include?('/shorts/') ? 'short' : 'video'

          videos << {
            platform_post_id: data['id'],
            title: data['title'],
            post_type: post_type,
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
