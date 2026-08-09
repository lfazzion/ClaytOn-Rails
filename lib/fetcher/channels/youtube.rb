# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "uri"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../session_cookies"

module Fetcher
  module Channels
    # Transcrição de vídeo do YouTube pelo `yt-dlp`, com o cookie do jar.
    #
    # Medido em 04/08/2026, deste IP, com controle: NÃO existe caminho anônimo.
    # Dez variantes falharam com o mesmo "Sign in to confirm you're not a bot" —
    # com e sem runtime JS (o aviso de runtime some com o deno no PATH, provando
    # que o yt-dlp o usou, e o erro não muda), e em oito `player_client`
    # diferentes (tv, tv_simply, tv_embedded, ios, mweb, web_safari,
    # web_embedded, android_vr). O portão é reputação de IP; a única saída daqui
    # é sessão. O próprio yt-dlp aponta `--cookies` como o remédio.
    #
    # `yt-dlp` em vez do Chrome porque ele é mantido por muita gente e absorve
    # mudança de formato do YouTube sozinho — o `ytInitialPlayerResponse` que
    # este canal parseava à mão nunca foi verificado contra a página real. Roda
    # por `Open3` no container do Rails, como `ScrapingServices::YoutubeScraperService`
    # já fazia (youtube_scraper_service.rb:114); o binário está no Dockerfile:44.
    #
    # Só URL de vídeo. Canal e playlist devolvem nil e caem no caminho comum.
    module Youtube
      class NoTranscript < Error; end

      PREFERRED_LANGS = %w[pt-BR pt en en-US en-orig].freeze
      # Abaixo do CHANNEL_TIMEOUT (40s) do ExtractService, que por sua vez fica
      # abaixo dos 90s do plugin do reader.
      YTDLP_TIMEOUT = 30
      # Mais apertado que os 5/min da casa: a plataforma conta requisição por
      # conta, e rajada é assinatura de bot. 2/min dá ~30s entre chamadas.
      MAX_PER_WINDOW = 2
      COOKIE_DOMAIN  = "youtube.com"
      MAX_RESULTADOS = 25
      # Seleção de campos do yt-dlp: os mesmos dados úteis do info.json (14,6 MB
      # neste vídeo, quase tudo `automatic_captions`) em ~90 KB por stdout.
      INFO_TEMPLATE  = "%(.{id,title,channel,uploader,subtitles})j"
      # Vem do registro único em `CookieJar::AUTH_SENTINELS`, e não de uma cópia
      # aqui: os DOIS caminhos de persistência (yt-dlp e navegador) precisam da
      # mesma lista, e manter duas cópias é como o bug de 05/08 nasceu. `fetch`
      # de propósito — domínio sem sentinela cadastrada tem que estourar no boot,
      # não passar batido. O motivo de `__Secure-3PSID` ficar de fora está lá.
      AUTH_COOKIES   = CookieJar::AUTH_SENTINELS.fetch(COOKIE_DOMAIN)

      class << self
        def call(url:, response: nil)
          id = video_id_from(url)
          return nil if id.nil?

          # Erro nomeado antes de gastar processo: sem sessão não há caminho.
          cookies, origem = SessionCookies.for(COOKIE_DOMAIN)

          Dir.mktmpdir("ytdlp") do |dir|
            info = CookieJar.with_netscape_file(COOKIE_DOMAIN, cookies: cookies) do |cookie_path|
              resultado = run(url, dir, cookie_path)
              verify_session!(cookie_path)
              # Só faz sentido reescrever o jar quando o jar foi a fonte. Se a
              # sessão veio do navegador, é ELE que rotaciona e é dele a verdade —
              # gravar por cima criaria de novo a cópia dessincronizada que este
              # canal existe para evitar.
              if origem == :jar
                CookieJar.refresh_from_netscape!(domain: COOKIE_DOMAIN, path: cookie_path,
                                                 auth_cookies: AUTH_COOKIES)
              end
              resultado
            end
            build_from(dir: dir, url: url, info: info)
          end
        end

        # Público de propósito: é onde mora a leitura do que o yt-dlp escreveu, e
        # é por aqui que o teste entra sem precisar do binário nem da rede.
        def build_from(dir:, url:, info: {})
          path, lang = pick_subtitle(dir, info)
          raise NoTranscript, "vídeo sem faixa de legenda disponível" if path.nil?

          text = render(events_from(path))
          raise NoTranscript, "faixa de legenda veio vazia" if text.blank?

          {
            url:      url,
            title:    info["title"].to_s,
            content:  text,
            metadata: {
              "source"         => "youtube",
              "kind"           => "transcript",
              "lang"           => lang.to_s,
              "auto_generated" => !info.dig("subtitles", lang),
              "video_id"       => info["id"].to_s,
              "channel"        => (info["channel"] || info["uploader"]).to_s
            }
          }
        end

        # Busca no proprio YouTube, pelo `ytsearchN:` do yt-dlp — mesmo binario e
        # mesma sessao que a transcricao usa. Nao passa por buscador externo
        # porque nenhum indexa permalink de plataforma: medido em 05/08, bing,
        # google, duckduckgo, brave e startpage devolveram ZERO permalinks de
        # video, thread ou post, em qualquer consulta.
        #
        # `--flat-playlist` nao abre video nenhum, so lista o que a busca achou.
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = [[limit.to_i, 1].max, MAX_RESULTADOS].min
          CookieJar.require!(COOKIE_DOMAIN)
          CookieJar.with_netscape_file(COOKIE_DOMAIN) { |caminho| resultados(termo, n, caminho) }
        end

        def video_id_from(url)
          uri = URI.parse(url.to_s)
          host = uri.host.to_s.downcase.delete_prefix("www.")

          case host
          when "youtu.be"
            uri.path.to_s.delete_prefix("/").presence
          when "youtube.com", "m.youtube.com"
            return Regexp.last_match(1) if uri.path.to_s =~ %r{\A/shorts/([^/]+)}

            URI.decode_www_form(uri.query.to_s).to_h["v"].presence if uri.path == "/watch"
          end
        rescue URI::InvalidURIError
          nil
        end

        # Público de propósito: é o portão que precisa correr entre o yt-dlp
        # reescrever o arquivo e alguém persistir o que ele escreveu. Quem renova
        # a sessão fora deste canal (`RefreshSessionCookiesJob`) precisa do mesmo
        # portão — deixá-lo privado foi o que permitiu o job persistir sem ele e
        # apagar a sessão boa com o conjunto anônimo.
        def verify_session!(cookie_path)
          nomes = CookieJar.parse_netscape(cookie_path).map { |c| c["name"] }
          return if AUTH_COOKIES.intersect?(nomes)

          raise CookieJar::Expired, COOKIE_DOMAIN
        end

        private

        def resultados(termo, n, cookie_path)
          comando = [
            "yt-dlp", "--no-update", "--quiet", "--no-warnings", "--flat-playlist",
            "--ignore-no-formats-error", "--cookies", cookie_path,
            "--print", "%(id)s\t%(title)s\t%(channel)s\t%(duration)s",
            "--socket-timeout", "15", "ytsearch#{n}:#{termo}"
          ]
          out, err, = Timeout.timeout(YTDLP_TIMEOUT) { Open3.capture3(*comando) }
          raise CookieJar::Expired, COOKIE_DOMAIN if sessao_rejeitada?(err)

          out.to_s.lines.filter_map { |linha| linha_para_item(linha) }
        rescue Timeout::Error
          raise NoTranscript, "busca do YouTube não respondeu em #{YTDLP_TIMEOUT}s"
        end

        def linha_para_item(linha)
          id, titulo, canal, duracao = linha.chomp.split("\t")
          return nil if id.to_s.empty?

          {
            "url" => "https://www.youtube.com/watch?v=#{id}",
            "title" => titulo.to_s,
            "channel" => canal.to_s,
            # nil e nao 0 quando o yt-dlp nao sabe: zero seria "video de 0s".
            "duration_seconds" => (duracao.to_i if duracao.to_s.match?(/\A\d+\z/))
          }
        end

        # Sessão rejeitada NÃO pode virar "vídeo sem legenda".
        #
        # Medido em 04/08: com a sessão morta o yt-dlp sai com status 0, sem uma
        # linha de erro, e simplesmente devolve o vídeo sem nenhuma faixa — o
        # mesmo que um vídeo legitimamente sem legenda. A diferença só aparece no
        # arquivo de cookie que ele reescreve: o YouTube devolve apenas os
        # cookies anônimos (VISITOR_INFO1_LIVE, PREF, YSC, GPS) e some com os de
        # autenticação. É essa a evidência que separa os dois casos.
        # O proprio yt-dlp nomeia a causa quando reconhece; e diagnostico melhor
        # que a heuristica do arquivo de cookie, porque distingue sessao
        # rotacionada de bot-check por IP.
        SESSAO_MORTA = [
          "cookies are no longer valid",
          "Sign in to confirm"
        ].freeze

        def sessao_rejeitada?(stderr)
          texto = stderr.to_s
          SESSAO_MORTA.any? { |marca| texto.include?(marca) }
        end

        # O cookie vai por ARQUIVO, nunca por argumento: valor em linha de comando
        # aparece em `ps` para qualquer processo da máquina.
        #
        # Duas flags que a prova ao vivo de 04/08 mostrou serem obrigatórias:
        #
        # `--ignore-no-formats-error` — o desafio `n` do YouTube exige runtime JS
        # e falha aqui, o que zera a lista de formatos de MÍDIA. Sem esta flag o
        # yt-dlp aborta em "Requested format is not available" DEPOIS de já ter
        # achado as legendas, e não grava nada. Não baixamos mídia, então a
        # ausência de formato é irrelevante para este canal.
        #
        # `--print` no lugar de `--write-info-json` — o info.json deste vídeo deu
        # 14,6 MB, quase tudo `automatic_captions` de centenas de idiomas. A
        # seleção de campos devolve os mesmos dados úteis em ~90 KB por stdout.
        #
        # `--no-simulate` é OBRIGATÓRIO junto do `--print`: `--print` liga o modo
        # simulação, e em simulação o yt-dlp imprime mas NÃO grava arquivo nenhum.
        # Medido com controle: sem a flag, 0 arquivos json3; com ela, 3.
        def run(url, dir, cookie_path)
          command = [
            "yt-dlp", "--no-update", "--skip-download", "--ignore-no-formats-error",
            "--no-progress", "--no-warnings", "--quiet", "--no-simulate",
            "--write-subs", "--write-auto-subs", "--sub-format", "json3",
            "--sub-langs", PREFERRED_LANGS.join(","),
            "--print", INFO_TEMPLATE, "--cookies", cookie_path,
            "--socket-timeout", "15",
            "-o", File.join(dir, "%(id)s.%(ext)s"), url
          ]

          out, err, status = Timeout.timeout(YTDLP_TIMEOUT) { Open3.capture3(*command) }

          # A checagem do stderr roda MESMO com status 0: com
          # `--ignore-no-formats-error` o yt-dlp sai com sucesso e reporta a
          # sessao morta apenas como WARNING. Medido em 05/08 — a mensagem
          # "cookies are no longer valid" veio com exit=0.
          raise CookieJar::Expired, COOKIE_DOMAIN if sessao_rejeitada?(err)

          unless status.success?
            Rails.logger.warn "[Fetcher::Channels::Youtube] yt-dlp falhou: #{err.to_s.lines.last&.strip}"
          end

          JSON.parse(out.to_s.lines.first.to_s)
        rescue JSON::ParserError
          {}
        rescue Timeout::Error
          raise NoTranscript, "yt-dlp não respondeu em #{YTDLP_TIMEOUT}s"
        end

        # Manual antes de automática dentro do mesmo idioma: legenda enviada pelo
        # autor não repete linha nem erra nome próprio.
        def pick_subtitle(dir, info)
          disponiveis = Dir[File.join(dir, "*.json3")].to_h { |p| [lang_of(p, info["id"]), p] }
          return [nil, nil] if disponiveis.empty?

          PREFERRED_LANGS.each do |lang|
            return [disponiveis[lang], lang] if disponiveis.key?(lang)
          end
          lang, path = disponiveis.first
          [path, lang]
        end

        # yt-dlp escreve `<id>.<lang>.json3`.
        def lang_of(path, video_id)
          File.basename(path, ".json3").delete_prefix("#{video_id}.")
        end

        def events_from(path)
          JSON.parse(File.read(path))["events"]
        rescue JSON::ParserError, Errno::ENOENT
          nil
        end

        # Legenda automática repete a linha anterior a cada quadro de rolagem —
        # sem deduplicar, uma aula de 20 minutos vira o dobro de texto repetido.
        def render(events)
          linhas = Array(events).filter_map do |event|
            texto = Array(event["segs"]).map { |seg| seg["utf8"].to_s }.join.strip
            texto.presence
          end
          linhas.chunk_while { |a, b| a == b }.map(&:first).join("\n")
        end
      end
    end
  end
end
