# frozen_string_literal: true

require "json"
require "time"
require "timeout"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"
require_relative "x_graphql"

module Fetcher
  module Channels
    # Lê a CONVERSA (post raiz + comentários) de um post do X (Twitter)
    # através da API GraphQL `TweetDetail` — POST, com `variables`+`features`
    # no corpo JSON (as flags de features estouram `SsrfGuard::MAX_URL_LENGTH`
    # se fossem embutidas na query string).
    #
    # Estrutura REAL da resposta (medida na fixture versionada
    # `test/fixtures/files/x/tweet_detail.json`, HTTP 200 de 21/09 — 29 entries: 1 item raiz, 27 modules com 30 comentários,
    # 1 cursor Bottom):
    #
    #   data.threaded_conversation_with_injections_v2.instructions[]
    #     - { "type" => "TimelineClearCache" }
    #     - { "type" => "TimelineAddEntries", "entries" => [...] }
    #     - { "direction" => "Top", "type" => "TimelineTerminateTimeline" }
    #
    #   Cada entry: `content` + `entryId` + `sortIndex`. Tipos relevantes:
    #     - `TimelineTimelineItem`: content.itemContent.tweet_results.result
    #       -> POST RAIZ (1 na fixture).
    #     - `TimelineTimelineModule`: content.items[].item.itemContent.tweet_results
    #       -> COMENTÁRIOS (os 30 vivem AQUI — o caminho do topo não os vê;
    #       o parser olha os DOIS, senão perde todos os comentários).
    #       Módulos podem trazer itens-cursor (`ShowMore`) SEM `tweet_results`:
    #       não explodem a leitura — devolvem o que tem.
    #     - `TimelineTimelineCursor` com `cursorType == "Bottom"`:
    #       content.value = cursor da PRÓXIMA PÁGINA (paginação).
    #
    # Campos por tweet: `rest_id` (String, = `legacy.id_str`), `legacy.full_text`,
    # `legacy.created_at`, `legacy.favorite_count`, `legacy.reply_count`. Autor em
    # `core.user_results.result.legacy.screen_name`, com fallback para
    # `core.user_results.result.core.screen_name` — na fixture real o
    # `legacy.screen_name` vem nulo e é o fallback que resolve. O envelope
    # `TweetWithVisibilityResults` (com o tweet cru em `result.tweet`) é
    # desembalado quando presente; todos os 31 tweets da fixture vieram
    # `Tweet` cru.
    #
    # Contrato de saída (chaves STRING, mesmo tom dos outros canais):
    #   { "root"    => { id, author, text, created_at, likes, replies },
    #     "replies" => [ { id, author, text, created_at, likes, replies } ... ],
    #     "cursor"  => "…"/nil }
    # ("replies" dentro de um tweet = `legacy.reply_count` daquele tweet;
    # `likes` = `legacy.favorite_count`.)
    # "Post sem comentários" é resposta legítima: root presente, `replies: []`.
    # Falha de rede/HTTP ou resposta inválida levanta exceção tipada —
    # nada sai calado.
    #
    # Log de prova por página (NUNCA cookie, ct0 ou headers):
    #   [XConversation] op=TweetDetail qid=… page=k status=… entries=…
    module XConversation
      # queryId do TweetDetail MEDIDO pelo maestro (não a constante do twscrape,
      # nem o resolver — que cai no PIN da SearchTimeline e a API responderia 404).
      QUERY_ID      = "zoF7_t363wZyzylk-BLfZQ"
      OPERATION     = "TweetDetail"
      COOKIE_DOMAIN = "x.com"

      # Teto de tempo TOTAL de um fetch (30 s), como manda a casa.
      TOTAL_TIMEOUT     = 30
      DEFAULT_LIMIT     = 40
      DEFAULT_MAX_PAGES = 3

      # Janela de bloqueio remoto ao estourar sem header `x-rate-limit-reset`
      # (mesmo piso de 60 s do `XGraphql`).
      REMOTE_BLOCK_SECONDS = 60

      # Jitter entre páginas (mesma banda do transporte do X): espaça as
      # requisições para não martelar a API. Nunca dorme na última página.
      PAGE_JITTER_SECONDS = 0.8..2.0

      # Orçamento local para o caminho de conversa (freio independente do busca).
      GRAPHQL_BUDGET = { scope: "graphql_conversation", max: 4, per_hour: 30 }.freeze

      # As 7 chaves FIXAS de variables booleanas do `TweetDetail`
      # (fonte: REPORT-FX1r2.md). Todos os valores são true.
      VARIABLES_KEYS = %w[
        with_rux_injections
        includePromotedContent
        withCommunity
        withQuickPromoteEligibilityTweetFields
        withBirdwatchNotes
        withVoice
        withV2Timeline
      ].freeze

      # 38 flags literais de `features` (fonte primária: `GQL_FEATURES` do
      # twscrape — a mesma que o maestro usou na captura da fixture
      # versionada `test/fixtures/files/x/tweet_detail.json`; os flags vieram
      # da fonte primária, o `tmp/` era só a área de captura efêmera,
      # não versionado). COPY — não inventar nenhuma flag.
      FEATURES = {
        "articles_preview_enabled" => false,
        "c9s_tweet_anatomy_moderator_badge_enabled" => true,
        "communities_web_enable_tweet_community_results_fetch" => true,
        "creator_subscriptions_quote_tweet_preview_enabled" => false,
        "creator_subscriptions_tweet_preview_api_enabled" => true,
        "freedom_of_speech_not_reach_fetch_enabled" => true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled" => true,
        "longform_notetweets_consumption_enabled" => true,
        "longform_notetweets_inline_media_enabled" => true,
        "longform_notetweets_rich_text_read_enabled" => true,
        "responsive_web_edit_tweet_api_enabled" => true,
        "responsive_web_enhance_cards_enabled" => false,
        "responsive_web_graphql_exclude_directive_enabled" => true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled" => false,
        "responsive_web_grok_community_note_auto_translation_is_enabled" => false,
        "responsive_web_graphql_timeline_navigation_enabled" => true,
        "responsive_web_grok_imagine_annotation_enabled" => false,
        "responsive_web_media_download_video_enabled" => false,
        "responsive_web_profile_redirect_enabled" => true,
        "responsive_web_twitter_article_tweet_consumption_enabled" => true,
        "rweb_tipjar_consumption_enabled" => true,
        "rweb_video_timestamps_enabled" => true,
        "standardized_nudges_misinfo" => true,
        "tweet_awards_web_tipping_enabled" => false,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled" => true,
        "tweet_with_visibility_results_prefer_gql_media_interstitial_enabled" => false,
        "tweetypie_unmention_optimization_enabled" => true,
        "verified_phone_label_enabled" => false,
        "view_counts_everywhere_api_enabled" => true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled" => false,
        "premium_content_api_read_enabled" => false,
        "profile_label_improvements_pcf_label_in_post_enabled" => false,
        "responsive_web_grok_share_attachment_enabled" => false,
        "responsive_web_grok_analyze_post_followups_enabled" => false,
        "responsive_web_grok_image_annotation_enabled" => false,
        "responsive_web_grok_analysis_button_from_backend" => false,
        "responsive_web_jetfuel_frame" => false,
        "rweb_video_screen_enabled" => true,
        "responsive_web_grok_show_grok_translated_post" => true
      }.freeze

      class Error < ::Fetcher::Channels::Error; end

      # Falha de transporte/protocolo: POST falhou (rede, timeout, SSRF),
      # status fora do mapa, corpo não-JSON. É a raiz das falhas "de rede".
      class ResponseError < Error; end
      # Rate limit LOCAL (teto da casa, como os outros canais).
      class RateLimited < Error
        def initialize(host, budget = GRAPHQL_BUDGET)
          scope_suffix = budget[:scope] ? " [#{budget[:scope]}]" : ""
          super("rate limit local: #{host} atingiu #{budget[:max]} leitura(s)/min " \
                "ou #{budget[:per_hour]}/hora#{scope_suffix} — repita daqui a pouco")
        end
      end
      # Rate limit REMOTO (429 do X).
      class RateLimitedRemote < Error; end
      # Post removido/protegido/inexistente, ou query id inválida (404).
      class NotFound < Error; end
      # Sessão inválida (401/403 — txid/csrf/sessão rejeitados).
      class AuthError < Error; end
      # Resposta HTTP 200 que NÃO é uma conversa de TweetDetail válida
      # (focal ausente, envelope inexistente, conversa sem tweets).
      class ParseError < Error; end
      # Teto total (`total_timeout`) estourou.
      class TimedOut < Error; end
      # `limit` inválido na entrada (não inteiro ou menor que 1) — validado
      # em `fetch` antes de gastar rede (0 e negativo não cortam "calado").
      class InvalidLimit < Error
        def initialize(limit)
          super("limit inválido: #{limit.inspect} — deve ser inteiro >= 1")
        end
      end

      # ------------------------------------------------------------------
      # Interface pública
      # ------------------------------------------------------------------

      class << self
        # Lê a conversa de um post. Pagina o `TweetDetail` pelo cursor
        # Bottom até juntar `limit` comentários, esgotar `max_pages` ou o
        # cursor se repetir/sumir. Respeita o teto TOTAL de 30 s e dorme
        # entre páginas (jitter 0.8–2 s, nunca na última).
        #
        # Retorna chaves STRING:
        #   { "root"    => {id, author, text, created_at, likes, replies},
        #     "replies" => [mesmo shape, um por comentário],
        #     "cursor"  => "…"/nil }
        # Post sem comentários devolve root + `replies: []` (vazio ≠ falha).
        # Falha de transporte, status não-2xx (mapeado para
        # `NotFound`/`RateLimitedRemote`/`AuthError`/`ResponseError`) ou
        # resposta inválida (`ParseError`) levantam exceção tipada.
        def fetch(tweet_id:, limit: DEFAULT_LIMIT, max_pages: DEFAULT_MAX_PAGES,
                  total_timeout: TOTAL_TIMEOUT)
          id = tweet_id.to_s.strip
          raise ArgumentError, "tweet_id é obrigatório" if id.empty?
          # `limit` deve ser inteiro positivo: 0 devolvia `[]` calado e
          # negativo levanta `ArgumentError` cru em `replies.first` — os dois
          # viram `InvalidLimit` (erro tipado da família `Channels::Error`),
          # ANTES de `gate!` gastar estado de rate limit ou rede.
          raise InvalidLimit, limit unless limit.is_a?(Integer) && limit.positive?

          gate!

          # O teto TOTAL é INJETÁVEL (`total_timeout`, default `TOTAL_TIMEOUT`)
          # para permitir teste causal do alarme com orçamento minúsculo —
          # relógio real (thread de monitor do `Timeout`), então 30 s de
          # espera é inaceitável na suíte. O MESMO alarme/verificação de
          # sempre; só o valor do teto varia.
          Timeout.timeout(total_timeout) do
            collect(tweet_id: id, limit: limit, max_pages: max_pages)
          end
        rescue Timeout::Error
          raise TimedOut, "fetch da conversa excedeu #{total_timeout}s"
        end

        # Parser puro, sem rede. Entra com o corpo JSON já decodificado de
        # UMA página da resposta do `TweetDetail`.
        #
        # Olha os DOIS caminhos de tweet (item raiz + module comentários)
        # e desembala o envelope `TweetWithVisibilityResults`
        # (`result.tweet`) quando presente. Devolve chaves STRING:
        #   { "root" => {id, author, text, created_at, likes, replies},
        #     "replies" => [tweet], "cursor" => "Bottom"/nil }
        #
        # - Conversa válida com post sem comentários -> root presente,
        #   `replies: []` (vazio não é falha).
        # - Resposta que NÃO é conversa de TweetDetail (sem envelope, ou
        #   com `focal_id` que não aparece nos tweets) -> `ParseError`.
        # - Módulo sem `tweet_results` não explode: devolve o que tem.
        # - Sem `focal_id` (página de continuação), tweets vazios devolvem
        #   `{ "root" => nil, "replies" => [], "cursor" => ... }` — só a
        #   página inicial com `focal_id` exige o post focal.
        def parse_conversation(data, focal_id: nil)
          envelope = conversation_envelope(data)
          raise ParseError, "resposta sem 'threaded_conversation_with_injections_v2'" if envelope.nil?

          tweets, cursor = collect_entries(envelope)

          if tweets.empty?
            raise ParseError, "conversa sem nenhum tweet (post #{focal_id.inspect} ausente)" if focal_id

            return { "root" => nil, "replies" => [], "cursor" => cursor }
          end

          root = pick_root(tweets, focal_id)
          raise ParseError, "post focal #{focal_id.inspect} não está na conversa" if focal_id && root.nil?

          {
            "root"    => root,
            "replies" => tweets.reject { |t| t.equal?(root) || t["id"] == root["id"] },
            "cursor"  => cursor
          }
        end

        # Cursor Bottom de UMA página. `collect_entries` é a ÚNICA fonte que
        # caminha o envelope; este método público é só a delegação (mantido
        # para a API de teste) — a leitura em duplicata foi eliminada: não
        # existe segundo caminhador que possa divergir do `parse_conversation`.
        def extract_bottom_cursor(data)
          envelope = conversation_envelope(data)
          return nil unless envelope

          collect_entries(envelope).last
        end

        # ------------------------------------------------------------------
        # Freio de rate limit remoto (429). Padrão do `XGraphql` ao armar e
        # consultar: 429 arma `@remote_blocked` + janela; `gate!`
        # consulta ANTES de gastar rede, então chamadas seguidas não
        # voltam a bater na API até a janela esgotar. O freio local (4/min)
        # segue valendo para o volume; o remoto trava o próximo fetch inteiro.
        # Diferença real (não confundir): no `XGraphql` a 429 trava 60 s
        # FIXOS — o `x-rate-limit-reset` entra só no TEXTO da exceção
        # (`x_graphql.rb:422-425`); AQUI a janela vem do reset quando ele é
        # plausível, senão o piso de `REMOTE_BLOCK_SECONDS`.
        # ------------------------------------------------------------------

        # `429` do X armou bloqueio remoto — devolve verdadeiro dentro da
        # janela; fora dela zera o estado e devolve falso.
        def remote_blocked?
          if @remote_blocked && @remote_block_until && @remote_block_until > Time.now
            true
          else
            @remote_blocked = false
            @remote_block_until = nil
            false
          end
        end

        # Limpa o freio remoto (uso em teste / reset manual).
        def clear_remote_state!
          @remote_blocked = false
          @remote_block_until = nil
        end

        # ------------------------------------------------------------------
        # Internals
        # ------------------------------------------------------------------

        private

        def gate!
          # Falha rápida ANTES de gastar rede: sem sessão no jar, o POST
          # sairia com Cookie vazio e viraria 401/403 remoto — melhor
          # devolver o `Expired` local (mesmo tom do `XGraphql.search`).
          # 429 anterior armou o freio remoto local: chamadas seguidas
          # NÃO voltam a bater na API até a janela esgotar.
          raise RateLimitedRemote,
                "429 anterior em #{COOKIE_DOMAIN} — bloqueio remoto local, aguarde a janela" if remote_blocked?

          CookieJar.require!(COOKIE_DOMAIN)
          raise RateLimited.new(COOKIE_DOMAIN, GRAPHQL_BUDGET) if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **GRAPHQL_BUDGET)
        end

        def collect(tweet_id:, limit:, max_pages:)
          root = nil
          replies = []
          seen = {}
          cursor = nil
          prev_cursor = nil
          page = 0

          max_pages.times do
            page += 1
            response, parsed = post_page!(tweet_id: tweet_id, limit: limit, cursor: cursor)

            # Página 1: o post focal (raiz) TEM que estar na resposta.
            # Continuação (cursor): só comentários — sem `focal_id`, o
            # `root` local é âncora de dedupe, não a raiz global.
            conv = parse_conversation(parsed, focal_id: page == 1 ? tweet_id : nil)
            root ||= conv["root"]
            root_id = root && root["id"]

            # Todos os tweets da página viram candidatos; a âncora local vai
            # NA FRENTE (é o 1º tweet lido da página de continuação — se fosse
            # adicionada no fim, o corte de `limit` descartaria o que chegou
            # primeiro); a raiz global e os já-vistos são descartados.
            page_tweets = [conv["root"]].compact + Array(conv["replies"])
            new_replies = page_tweets.reject { |t| seen[t["id"]] || (root_id && t["id"] == root_id) }
            new_replies.each { |t| seen[t["id"]] = true }
            replies.concat(new_replies)
            # Corte determinístico: `limit` é o teto TOTAL de comentários
            # coletados; mantém os PRIMEIROS `limit` na ordem em que
            # chegaram (a página é lida íntegra para o log, mas o contrato
            # devolve no máximo `limit`). Sem isto `replies` passaria de
            # `limit` quando a API devolve mais comentários do que o teto.
            replies = replies.first(limit)

            # `entries` = tweets LIDOS nesta página (pré-dedupe): a prova de
            # quanto a API devolveu. `status` é o HTTP da página.
            log_page(page: page, query_id: QUERY_ID, status: response.status, entries: page_tweets.size)

            # Paginação pelo cursor Bottom: cursor novo = há mais;
            # repetido/ausente = conversa exausta (freio anti-loop).
            cursor = conv["cursor"]
            break if cursor.nil? || cursor.empty?
            break if cursor == prev_cursor
            prev_cursor = cursor

            # Só adianta continuar se ainda faltar comentários e restar página.
            break if replies.size >= limit
            break if page == max_pages

            Kernel.sleep(rand(PAGE_JITTER_SECONDS))
          end

          { "root" => root, "replies" => replies, "cursor" => cursor }
        end

        def post_page!(tweet_id:, limit:, cursor:)
          variables = build_variables(tweet_id, limit, cursor)
          # `QUERY_ID` MEDIDO (constante do brief): URL e assinatura do txid
          # fecham com o mesmo id — o resolver cairia no PIN (outra operação)
          # e a API responderia 404.
          url = XGraphql.build_url("", variables, FEATURES, QUERY_ID, operation: OPERATION, method: "POST")
          headers = XGraphql.build_headers(variables, FEATURES, query_id: QUERY_ID, operation: OPERATION, method: "POST")

          response = SafeHttpClient.post(url, json: { variables: variables, features: FEATURES }, headers: headers)
          handle_status!(response)

          parsed =
            begin
              JSON.parse(response.body.to_s)
            rescue JSON::ParserError
              raise ResponseError, "corpo de #{OPERATION} não é JSON"
            end
          [response, parsed]
        rescue Fetcher::SafeHttpClient::Error, Fetcher::SsrfGuard::Blocked => e
          # Falha de rede/transporte (timeout, DNS, redirect, SSRF) vira
          # exceção tipada da casa — o chamador resgata `Channels::Error`.
          raise ResponseError, "falha de rede lendo #{OPERATION} (#{e.class.name}): #{e.message}"
        end

        def handle_status!(response)
          case response.status.to_i
          when 200..299 then response
          when 404
            raise NotFound, "post ou query de #{OPERATION} não encontrado (HTTP 404)"
          when 429
            arm_remote_block!(response.headers)
            raise RateLimitedRemote, "429 do X — rate limit remoto, tente daqui a pouco"
          when 401, 403
            raise AuthError, "HTTP #{response.status} — txid/csrf/sessão inválidos"
          else
            raise ResponseError, "HTTP #{response.status} ao ler #{OPERATION}"
          end
        end

        # 429 arma o freio remoto local: `@remote_blocked` + janela. A janela
        # vem do reset lido pelo PÚBLICO `XGraphql.parse_rate_limit_reset`
        # (futuro, <1h): header plausível devolve `Time.at(reset)`; fora da
        # faixa plausível o próprio método devolve `now + 60`; ausente, vazio
        # ou ≤ 0 devolve nil e o piso de `REMOTE_BLOCK_SECONDS` entra.
        # Estado LOCAL a este módulo (não toca o `@remote_blocked` do
        # `XGraphql`): a busca e a conversa têm freios independentes — por
        # isso `remote_blocked?`/`clear_remote_state!` seguem locais
        # (leem/escrevem o estado DESTE módulo); só a leitura pura do reset,
        # que não tem estado próprio, foi delegada.
        def arm_remote_block!(headers)
          @remote_blocked = true
          @remote_block_until = XGraphql.parse_rate_limit_reset(headers) || Time.now + REMOTE_BLOCK_SECONDS
        end

        def build_variables(tweet_id, limit, cursor = nil)
          vars = { "focalTweetId" => tweet_id, "count" => limit.to_i }
          VARIABLES_KEYS.each { |k| vars[k] = true }
          vars["cursor"] = cursor unless cursor.nil? || cursor.empty?
          vars
        end

        def log_page(page:, query_id:, status:, entries:)
          # PROVA: op, qid, page, status, entries. NUNCA cookie, ct0, headers.
          msg = "[XConversation] op=#{OPERATION} qid=#{query_id} page=#{page} " \
                "status=#{status} entries=#{entries}"
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.info(msg)
          else
            Kernel.warn(msg)
          end
        end

        # Navega o envelope `threaded_conversation_with_injections_v2`:
        # instrucoes -> entries, baixando cada tweet (item E module) e o
        # cursor Bottom de paginação. Módulos sem `tweet_results` (itens-
        # cursor `ShowMore`) não quebram a leitura — só não contribuem
        # com tweets.
        def collect_entries(envelope)
          tweets = []
          cursor = nil

          Array(envelope["instructions"]).each do |instruction|
            next unless instruction.is_a?(Hash)
            next unless instruction["type"] == "TimelineAddEntries"
            next unless instruction["entries"].is_a?(Array)

            instruction["entries"].each do |entry|
              content = entry.is_a?(Hash) ? entry["content"] : nil
              next unless content.is_a?(Hash)

              case content["entryType"]
              when "TimelineTimelineItem"
                extract_tweet(content, tweets)
              when "TimelineTimelineModule"
                Array(content["items"]).each do |item|
                  extract_tweet(item.is_a?(Hash) ? item["item"] : nil, tweets)
                end
              when "TimelineTimelineCursor"
                cursor = content["value"].to_s if content["cursorType"] == "Bottom" && content.key?("value")
              end
            end
          end

          [tweets, cursor]
        end

        # Extrai um tweet de UM nó (item raiz: `itemContent` no topo; item de
        # módulo: a chave `item` do nó). Tolerante: silêncio quando não há
        # `tweet_results` (itens-cursor `ShowMore`).
        def extract_tweet(hash, sink)
          return unless hash.is_a?(Hash)

          result = hash.dig("itemContent", "tweet_results", "result")
          return unless result.is_a?(Hash)

          # Envelope de visibilidade: o tweet cru vive em `result.tweet`.
          result = result["tweet"] if result["__typename"] == "TweetWithVisibilityResults"
          return unless result.is_a?(Hash)

          shaped = shape_tweet(result)
          sink << shaped if shaped
        end

        def shape_tweet(result)
          legacy = result["legacy"]
          return nil unless legacy.is_a?(Hash)

          {
            "id"         => result["rest_id"] || legacy["id_str"],
            "author"     => resolve_author(result),
            "text"       => legacy["full_text"].to_s,
            "created_at" => parse_created_at(legacy["created_at"]),
            "likes"      => legacy["favorite_count"],
            "replies"    => legacy["reply_count"]
          }
        end

        # `legacy.screen_name` primeiro; fallback `core.screen_name` —
        # na fixture real o `legacy.screen_name` vem nulo e é o fallback
        # que resolve (o autor medido da raiz da fixture é `MonidHQ`).
        def resolve_author(result)
          user = result.dig("core", "user_results", "result")
          return nil unless user.is_a?(Hash)

          legacy = user["legacy"]
          return legacy["screen_name"] if legacy.is_a?(Hash) && legacy["screen_name"]
          return user.dig("core", "screen_name") if user.dig("core", "screen_name")

          nil
        end

        def pick_root(tweets, focal_id)
          return tweets.find { |t| t["id"].to_s == focal_id.to_s } if focal_id

          # Sem `focal_id` (continuação): âncora de dedupe — a raiz global
          # já está fora de `replies` no `collect`.
          tweets.first
        end

        def conversation_envelope(data)
          return nil unless data.is_a?(Hash)
          data.dig("data", "threaded_conversation_with_injections_v2")
        end

        def parse_created_at(created_at)
          return nil if created_at.nil? || created_at.empty?

          Time.parse(created_at).utc.iso8601
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
