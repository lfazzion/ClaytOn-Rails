# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "uri"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../session_cookies"
require_relative "../host_rate_limiter"

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

      # Falha operacional do yt-dlp (exit não-zero) — NÃO é ausência de legenda.
      class YtdlpError < Error
        def initialize(exit_status, stderr_line)
          super("yt-dlp falhou (exit #{exit_status}): #{stderr_line}")
        end
      end

      # Busca em plataforma logada é onde rajada vira ban — a conta responde,
      # não só o IP. Estourar o teto é erro nomeado; devolver lista vazia faria
      # o modelo concluir "não existe nada sobre isso".
      class RateLimited < Error
        def initialize(host)
          super("rate limit local: #{host} atingiu #{MAX_PER_WINDOW} buscas/min — repita daqui a pouco")
        end
      end

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
          path, lang, auto_generated = pick_subtitle(dir, info)
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
              "auto_generated" => auto_generated,
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
        #
        # Mesmos dois portoes do caminho de leitura: a sessao vem do
        # `SessionCookies` (o jar puro ignorava a sessao viva do Chrome — a
        # divergencia que `session_cookies.rb` existe para eliminar) e o rate
        # limit roda ANTES de gastar processo, com o teto do canal.
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = [[limit.to_i, 1].max, MAX_RESULTADOS].min
          raise RateLimited, COOKIE_DOMAIN if HostRateLimiter.exceeded?(COOKIE_DOMAIN, max: MAX_PER_WINDOW)

          cookies, = SessionCookies.for(COOKIE_DOMAIN)
          CookieJar.with_netscape_file(COOKIE_DOMAIN, cookies: cookies) { |caminho| resultados(termo, n, caminho) }
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
        #
        # Única execução: `--sub-langs all` baixa todas as faixas de uma só vez.
        # O orçamento YTDLP_TIMEOUT (30s) inteiro vai para a única chamada.
        # Timeout::Error vira NoTranscript.
        def run(url, dir, cookie_path)
          download_subs(dir, cookie_path, url, "all", YTDLP_TIMEOUT)
        end

        # Uma chamada do yt-dlp para o `dir` informado. A escolha do budget
        # é do chamador. Timeout::Error é convertido em NoTranscript.
        def download_subs(dir, cookie_path, url, langs, timeout)
          command = [
            "yt-dlp", "--no-update", "--skip-download", "--ignore-no-formats-error",
            "--no-progress", "--no-warnings", "--quiet", "--no-simulate",
            "--write-subs", "--write-auto-subs", "--sub-format", "json3/vtt/srt/best",
            "--sub-langs", langs,
            "--print", INFO_TEMPLATE, "--cookies", cookie_path,
            "--socket-timeout", "15",
            "-o", File.join(dir, "%(id)s.%(ext)s"), url
          ]

          out, err, status = Timeout.timeout(timeout) { Open3.capture3(*command) }

          # A checagem do stderr roda MESMO com status 0: com
          # `--ignore-no-formats-error` o yt-dlp sai com sucesso e reporta a
          # sessao morta apenas como WARNING. Medido em 05/08 — a mensagem
          # "cookies are no longer valid" veio com exit=0.
          raise CookieJar::Expired, COOKIE_DOMAIN if sessao_rejeitada?(err)

          unless status.success?
            linha = err.to_s.lines.last&.strip.to_s
            raise YtdlpError.new(status.exitstatus, linha)
          end

          JSON.parse(out.to_s.lines.first.to_s)
        rescue JSON::ParserError
          {}
        rescue Timeout::Error
          raise NoTranscript, "yt-dlp não respondeu em #{timeout}s (--sub-langs #{langs})"
        end

        # Seleção determinística de legenda — sem lista de preferência de idioma.
        #
        # Regras (na ordem de prioridade):
        # 1) Manual (`info["subtitles"]`) vence automática (`info["automatic_captions"]`).
        #    Quando o mesmo lang existe nos dois, o manual é escolhido.
        # 2) Dentro do mesmo grupo (manual ou auto): ordem lexicográfica do código
        #    de idioma (ex.: "es" < "pt").
        # 3) Dentro do mesmo idioma: json3 > vtt > srt.
        #
        # Qualquer idioma serve — não há hardcode de língua alguma.
        #
        # Devolve [path, lang, auto_generated] — o terceiro elemento indica a
        # fonte (manual=false, auto=true) para que `build_from` preencha o
        # metadata sem recontar.
        FORMAT_WEIGHT = { "json3" => 1, "vtt" => 2, "srt" => 3 }.freeze

        def pick_subtitle(dir, info)
          video_id = info["id"]
          # disponiveis: lang => { ext => path }, json3 sobrescrevendo vtt/srt.
          disponiveis = {}
          FORMAT_WEIGHT.sort_by { |_, peso| peso }.each do |ext, peso|
            Dir[File.join(dir, "*.#{ext}")].each do |p|
              lang = lang_of(p, video_id)
              # Só atualiza se ainda não tem entrada OU se a entrada atual é
              # de extensão pior (peso maior).
              atual = disponiveis[lang]
              if atual.nil? || peso < FORMAT_WEIGHT[atual.keys.first]
                disponiveis[lang] = { ext => p }
              end
            end
          end
          return [nil, nil, nil] if disponiveis.empty?

          manual = info["subtitles"] || {}
          # 1) manual vence auto; 2) lexicográfico dentro de cada grupo.
          sorted = disponiveis.keys.sort_by do |lang|
            [manual.key?(lang) ? 0 : 1, lang]
          end

          lang = sorted.first
          entry = disponiveis[lang]
          # json3 > vtt > srt — pega a chave de menor peso.
          path = entry.key?("json3") ? entry["json3"] :
                 entry.key?("vtt") ? entry["vtt"] :
                 entry["srt"]
          auto_generated = !manual.key?(lang)
          [path, lang, auto_generated]
        end

        # yt-dlp grava `<id>.<lang>.<ext>`. O lang é tudo entre o id e a
        # extensão, então "en-GB" sobreviver a um lang que tem hífen e o
        # caller do id que tem ponto exige o strip duplo.
        def lang_of(path, video_id)
          base = File.basename(path)
          base = base.sub(/\A#{Regexp.escape(video_id.to_s)}\./, "")
          base = base.sub(/\.(json3|vtt|srt)\z/, "")
          base
        end

        # Dispatch por extensão. json3 mantém o contrato antigo (events com
        # segs/utf8) consumido por `render`. vtt e srt produzem events
        # sintéticos no MESMO formato (Hash com "text") para que `render`
        # não precise de branch.
        def events_from(path)
          case File.extname(path)
          when ".json3"
            JSON.parse(File.read(path))["events"]
          when ".vtt"
            parse_vtt(File.read(path))
          when ".srt"
            parse_srt(File.read(path))
          end
        rescue JSON::ParserError, Errno::ENOENT
          nil
        end

        # Parser VTT mínimo:
        # - "WEBVTT" na primeira linha é o sinal do formato. Pode vir seguido
        #   de título (WEBVTT - Some title) — `start_with?` cobre.
        # - Metadados opcionais (Kind:, Language:) e blocos NOTE / STYLE /
        #   REGION antes da primeira cue são descartados.
        # - NOTE pode aparecer COLADO à primeira cue (sem linha em branco
        #   entre o corpo do NOTE e o timestamp) — medido no fixture do
        #   harness e em alguns VTTs do YouTube. O loop de NOTE consome
        #   até linha em branco OU linha de timing, não até linha em
        #   branco apenas.
        # - Cada cue: linha com timestamp "-->", depois texto até a
        #   próxima linha em branco.
        # - Tags inline (<c>, <i>, <b>) são removidas — yt-dlp coloca
        #   `<c.colorXXXXX>` em legendas automáticas.
        # Devolve [{ "text" => "..." }, ...] no mesmo formato que `render`
        # espera.
        WEBVTT_INLINE_TAG  = /<[^>]+>/.freeze
        WEBVTT_TIMING      = /\A(\d{2}:)?\d{2}:\d{2}\.\d{3}\s+-->\s+(\d{2}:)?\d{2}:\d{2}\.\d{3}/.freeze
        WEBVTT_HEADER_KEYS = %w[Kind: Language:].freeze

        def parse_vtt(body)
          events = []
          lines  = body.to_s.split("\n")
          i = 0
          n = lines.size

          while i < n
            stripped = lines[i].to_s.strip

            # NOTE multilinha: consome até a próxima linha em branco OU até
            # uma linha de timing (NOTE pode aparecer colado na primeira cue
            # em alguns VTTs — o fixture do harness é exatamente este caso).
            if stripped == "NOTE"
              i += 1
              while i < n && lines[i].strip != "" && !lines[i].strip.match?(WEBVTT_TIMING)
                i += 1
              end
              next
            end

            # STYLE/REGION multilinha: consome até a próxima linha em branco.
            if stripped.start_with?("STYLE", "REGION")
              i += 1
              while i < n && lines[i].strip != ""
                i += 1
              end
              next
            end

            # Metadados chave: valor (Kind:, Language:) ou o próprio "WEBVTT"
            # que aparece na primeira linha.
            if i == 0 && stripped.start_with?("WEBVTT")
              i += 1
              next
            end
            if WEBVTT_HEADER_KEYS.any? { |k| stripped.start_with?(k) }
              i += 1
              next
            end

            # Linha de timing: junta linhas até a próxima em branco.
            if stripped.match?(WEBVTT_TIMING)
              i += 1
              buf = []
              while i < n && lines[i].strip != ""
                buf << lines[i]
                i += 1
              end
              texto = buf.join("\n").gsub(WEBVTT_INLINE_TAG, "").strip
              events << { "text" => texto } unless texto.empty?
              next
            end

            # Linha em branco ou linha não-reconhecida: avança.
            i += 1
          end
          events
        end

        # Parser SRT mínimo: blocos "1\nHH:MM:SS,mmm --> HH:MM:SS,mmm\ntexto\n"
        # separados por linha em branco. Vírgula no timestamp em vez de ponto.
        def parse_srt(body)
          events = []
          blocks = body.to_s.split(/\r?\n\r?\n+/)
          blocks.each do |blk|
            linhas = blk.lines.map(&:chomp)
            timing = linhas.find { |l| l.include?("-->") }
            next unless timing

            idx = linhas.index(timing)
            texto = linhas[(idx + 1)..].to_a.join("\n").gsub(/<[^>]+>/, "").strip
            events << { "text" => texto } unless texto.empty?
          end
          events
        end

        # Legenda automática repete a linha anterior a cada quadro de rolagem —
        # sem deduplicar, uma aula de 20 minutos vira o dobro de texto repetido.
        #
        # Dois formatos chegam aqui:
        # - json3: event = {"segs" => [{"utf8" => "..."}]}
        # - vtt/srt: event = {"text" => "..."} (produzido por parse_vtt/parse_srt)
        # O helper extrai o texto de qualquer um dos dois para o `render` ter um
        # só contrato.
        def render(events)
          linhas = Array(events).filter_map do |event|
            texto = if event.key?("segs")
                      Array(event["segs"]).map { |seg| seg["utf8"].to_s }.join
                    else
                      event["text"].to_s
                    end
            texto.strip.presence
          end
          linhas.chunk_while { |a, b| a == b }.map(&:first).join("\n")
        end
      end
    end
  end
end
