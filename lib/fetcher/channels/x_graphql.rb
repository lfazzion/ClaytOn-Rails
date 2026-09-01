# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "set"
require "time"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"

module Fetcher
  module Channels
    # Busca no X (Twitter) via API GraphQL oficial — caminho nativo da plataforma.
    #
    # Enquanto o caminho de `X.search` (espelho SPA com Chrome) gastava sessao
    # ativa do dono para cada termo, este canal usa a API GraphQL `SearchTimeline`
    # que responde com JSON estruturado diretamente, sem renderizacao de cliente.
    #
    # Requisitos:
    # - Sessao autenticada no CookieJar (`auth_token` + `ct0`); guest-only nao funciona.
    # - Header `x-client-transaction-id` calculado via par dict + SHA-256 + XOR.
    #
    # End-point provado em 31/08/2026:
    #   GET https://x.com/i/api/graphql/flaR-PUMshxFWZWPNpq4zA/SearchTimeline?variables=...&features=...
    #
    # Resposta: data.search_by_raw_query.search_timeline.timeline.instructions[].entries[]
    module XGraphql
      QUERY_ID = "flaR-PUMshxFWZWPNpq4zA"  # twikit — verificado 31/08/2026
      COOKIE_DOMAIN = "x.com"
      GRAPHQL_BUDGET = { scope: "graphql_search", max: 4, per_hour: 30 }.freeze

      # Par dict fa0311: key -> { animationKey, verification }
      # Usado para assinatura do header x-client-transaction-id.
      # O par "WebKit" é dummy (bytes fixos), pares reais têm verification mais longo.
      # O primeiro par válido (índice >= 1) do dicionário real foi medido ao vivo.
      PAIR_DICT = {
        "WebKit" => {
          animation_key: "WebKit",
          verification: Base64.decode64(
            "V0lwcklQY2dFQUFCQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE="
          )
        },
        "fast_path" => {
          animation_key: "766e10fae147ae147ae02e147ae147ae1402e147ae147ae140fae147ae147ae00",
          verification: Base64.decode64(
            "6xwJgFKyZ5cdDQ3HxUIVmnzvgmnBux+RbfUoTCXMm0oUcEcmfV3aC4ss+3xrvoIt"
          )
        }
      }.freeze

      class Error < ::Fetcher::Channels::Error; end

      # ---------------------------------------------------------------------------
      # Interfacie publica
      # ---------------------------------------------------------------------------

      # Busca por assunto no X via GraphQL, substituindo o caminho SPA antigo.
      #
      # Retorna Array de Hash com chaves STRING no formato do PlatformSearchTool:
      #   { "title" => "...", "url" => "...", "screen_name" => "...",
      #     "text" => "...", "created_at" => "..." }
      def self.search(query:, limit: 10)
        termo = query.to_s.strip
        return [] if termo.empty?

        # Gates na ordem correta:
        # 1. query vazia -> 2. clamp (pending) -> 3. bloqueio remoto ->
        #    4. limitador local -> 5. guest/sessao -> 6. request
        return [] if remote_blocked?
        CookieJar.require!(COOKIE_DOMAIN)
        raise RateLimited.new(COOKIE_DOMAIN, GRAPHQL_BUDGET) if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **GRAPHQL_BUDGET)

        fetch_search(query: termo, limit: limit)
      end

      # Envia requisicao GET para o endpoint GraphQL e parseia a resposta.
      # Suporta paginacao via cursor (maximo 3 paginas) e rate limit remoto.
      def self.fetch_search(query:, limit: 10)
        all_items = []
        seen_urls = Set.new
        cursor = nil
        prev_cursor = nil
        max_pages = 3
        page_count = 0

        features = build_features
        query_id_resolver = XQueryIdResolver.new
        last_query_id = query_id_resolver.resolve("SearchTimeline")
        @refreshed_404 = false

        while page_count < max_pages
          page_count += 1
          variables = build_variables(query, limit, cursor)
          url = build_url(query, variables, features, last_query_id)
          headers = build_headers(variables, features, query_id: last_query_id)

          response = SafeHttpClient.get(url, headers: headers)

          # Tratamento de status especiais ANTES do raise generico
          case response.status
          when 429
            # Rate limit remoto: marca bloqueio e retorna erro imediato
            @remote_blocked = true
            @remote_block_until = Time.now + 60
            reset_at = parse_rate_limit_reset(response.headers)
            reset_info = reset_at ? " reset em #{reset_at.strftime('%H:%M:%S')}" : ""
            raise RateLimitedRemote.new("429 Too Many Requests#{reset_info}")
          when 401
            # Erro de autenticacao: unica chance de reativacao
            raise GraphQLError, "HTTP #{response.status} (nao autorizado)"
          when 403
            # Proibido sem retry
            raise GraphQLError, "HTTP #{response.status} (proibido)"
          when 404
            # Query-ID possivelmente invalido: tenta refresh unico
            unless @refreshed_404
              @refreshed_404 = true
              new_id = query_id_resolver.resolve("SearchTimeline", force: true)
              if new_id && new_id != last_query_id
                last_query_id = new_id
                # Desconta a pagina atual pois vamos refazer com o mesmo cursor
                page_count -= 1
                next
              end
            end
            raise GraphQLError, "HTTP #{response.status} (query nao encontrada)"
          else
            # Demais erros de HTTP
            raise GraphQLError, "HTTP #{response.status}" unless response.success?
          end

          # Atualiza budget local com base nos headers da resposta
          update_remote_budget!(response.headers)

          data = JSON.parse(response.body)
          items = parse_search_timeline(data)

          # Dedupe por URL
          items.each do |item|
            unless seen_urls.include?(item["url"])
              seen_urls << item["url"]
              all_items << item
            end
          end

          # Extrai cursor Bottom da resposta para proxima pagina
          cursor = extract_bottom_cursor(data)
          break if cursor.nil? || cursor.empty?
          break if cursor == prev_cursor  # Evita loop infinito se cursor se repetir
          prev_cursor = cursor
        end

        all_items
      rescue JSON::ParserError
        raise GraphQLError, "resposta nao eh JSON valido"
      end

      def self.build_features
        {
          rweb_tipjar_consumption_enabled: true,
          responsive_web_graphql_exclude_directive_enabled: true,
          verified_phone_label_enabled: false,
          creator_subscriptions_tweet_preview_api_enabled: true,
          responsive_web_graphql_timeline_navigation_enabled: true,
          responsive_web_graphql_skip_user_profile_image_extensions_enabled: false,
          communities_web_enable_tweet_community_results_fetch: true,
          c9s_tweet_anatomy_moderator_badge_enabled: true,
          articles_preview_enabled: true,
          responsive_web_edit_tweet_api_enabled: true,
          graphql_is_translatable_rweb_tweet_is_translatable_enabled: true,
          view_counts_everywhere_api_enabled: true,
          longform_notetweets_consumption_enabled: true,
          responsive_web_twitter_article_tweet_consumption_enabled: true,
          tweet_awards_web_tipping_enabled: false,
          creator_subscriptions_quote_tweet_preview_enabled: false,
          freedom_of_speech_not_reach_fetch_enabled: true,
          standardized_nudges_misinfo: true,
          tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled: true,
          rweb_video_timestamps_enabled: true,
          longform_notetweets_rich_text_read_enabled: true,
          longform_notetweets_inline_media_enabled: true,
          responsive_web_enhance_cards_enabled: false
        }
      end

      def self.build_variables(query, limit, cursor = nil)
        vars = {
          rawQuery: query,
          count: limit,
          querySource: "typed_query",
          product: "Latest"
        }
        vars[:cursor] = cursor if cursor
        vars
      end

      def self.extract_bottom_cursor(data)
        instructions = data.dig("data", "search_by_raw_query", "search_timeline", "timeline", "instructions")
        return nil unless instructions.is_a?(Array)

        instructions.each do |instruction|
          next unless instruction["type"] == "TimelineAddEntries"
          next unless instruction["entries"].is_a?(Array)

          instruction["entries"].each do |entry|
            next unless entry.is_a?(Hash)
            next unless entry["content"].is_a?(Hash)
            next unless entry["content"]["cursorType"] == "Bottom"
            next unless entry["content"].key?("value")

            return entry["content"]["value"].to_s
          end
        end
        nil
      end

      def self.update_remote_budget!(headers)
        remaining = headers["x-rate-limit-remaining"]
        return if remaining.nil? || remaining.empty?

        rem = remaining.to_i
        if rem <= 0
          @remote_blocked = true
          @remote_block_until = Time.now + 60
        else
          @remote_blocked = false
          @remote_block_until = nil
        end
      end

      def self.parse_rate_limit_reset(headers)
        reset_str = headers["x-rate-limit-reset"]
        return nil if reset_str.nil? || reset_str.empty?

        reset_ts = reset_str.to_i
        return nil if reset_ts <= 0

        # Validacao: reset deve ser no futuro (ou muito proximo)
        now_ts = Time.now.to_i
        if reset_ts > now_ts && reset_ts < now_ts + 3600
          Time.at(reset_ts)
        else
          # Fallback seguro: 60 segundos a partir de agora
          Time.now + 60
        end
      rescue ArgumentError, TypeError
        nil
      end

      def self.remote_blocked?
        if @remote_blocked && @remote_block_until && @remote_block_until > Time.now
          true
        else
          @remote_blocked = false
          @remote_block_until = nil
          false
        end
      end

      def self.clear_remote_state!
        @remote_blocked = false
        @remote_block_until = nil
      end

      # Limpa token(s) de transacao armazenados (para teste).
      def self.expire_token!
        @txid_cache&.clear
      end

      # ---------------------------------------------------------------------------
      # Parser
      # ---------------------------------------------------------------------------

      # Parseia a resposta GraphQL e extrai tweets das entries.
      #
      # Schema esperado: data.search_by_raw_query.search_timeline.timeline.instructions
      def self.parse_search_timeline(data)
        return [] unless data.is_a?(Hash)

        entries = data.dig("data", "search_by_raw_query", "search_timeline",
                           "timeline", "instructions")
        return [] unless entries.is_a?(Array)

        entries.flat_map do |instruction|
          next [] unless instruction["type"] == "TimelineAddEntries"
          next [] unless instruction["entries"].is_a?(Array)

          instruction["entries"].filter_map do |entry|
            next nil unless entry.is_a?(Hash)

            item_content = entry.dig("content", "itemContent")
            next nil unless item_content.is_a?(Hash)

            tweet_result = item_content.dig("tweet_results", "result")
            next nil unless tweet_result.is_a?(Hash)

            # Descarta Tweets indisponiveis (protegidos, removidos, etc.)
            next nil if tweet_result["__typename"] == "TweetUnavailable"

            legacy = tweet_result["legacy"]
            core = tweet_result["core"]
            next nil unless legacy.is_a?(Hash) && core.is_a?(Hash)

            user_result = core.dig("user_results", "result")
            next nil unless user_result.is_a?(Hash)

            user_legacy = user_result.dig("legacy")
            next nil unless user_legacy.is_a?(Hash)

            screen_name = user_legacy["screen_name"]
            next nil if screen_name.nil? || screen_name.empty?

            full_text = legacy["full_text"] || ""
            created_at = legacy["created_at"]

            {
              "title" => "#{screen_name}: #{full_text[0..100]}#{full_text.length > 100 ? '...' : ''}",
              "url" => "https://x.com/#{screen_name}/status/#{legacy['id_str'] || entry['entryId'].match(/(\d+)$/)&.to_s}",
              "screen_name" => screen_name,
              "text" => full_text,
              "created_at" => parse_created_at(created_at)
            }
          end
        end.uniq { |item| item["url"] }
      end

      # ---------------------------------------------------------------------------
      # BuildTxid — assinatura do header x-client-transaction-id
      # ---------------------------------------------------------------------------

      class BuildTxid
        attr_reader :pair_key, :verification_bytes, :animation_key, :payload

        # Por padrão usa o par "fast_path" (algoritmo real medido ao vivo).
        def initialize(pair_key = "fast_path")
          @pair_key = pair_key
          @pair = PAIR_DICT[pair_key]
          raise ArgumentError, "par dict desconhecido: #{pair_key}" unless @pair

          @animation_key = @pair[:animation_key]
          @verification_bytes = @pair[:verification]
        end

        def evidence_header(now_ms:, mask: nil, query_id: QUERY_ID, path_suffix: "SearchTimeline")
          seconds = (now_ms - 1_682_924_400_000) / 1000
          path = "/i/api/graphql/#{query_id}/#{path_suffix}"
          @payload = "GET!#{path}!#{seconds}obfiowerehiring#{@animation_key}"

          digest = Digest::SHA256.digest(@payload)
          current_mask = mask || rand(256)

          time_bytes = [seconds & 0xff, (seconds >> 8) & 0xff, (seconds >> 16) & 0xff, (seconds >> 24) & 0xff]
          seq = @verification_bytes.bytes + time_bytes + digest.bytes[0...16] + [3]
          out = [current_mask] + seq.map { |b| b ^ current_mask }

          Base64.strict_encode64(out.pack("C*")).delete("=")
        end

        def self.evidence_header(payload, now_ms)
          txid = new(payload[:animation_key] || payload.keys.first)
          txid.instance_variable_set(:@payload, payload[:payload]) if payload[:payload]
          txid.evidence_header(now_ms: now_ms)
        end
      end

      # ---------------------------------------------------------------------------
      # Internals
      # ---------------------------------------------------------------------------

      def self.build_url(query, variables, features, query_id = nil)
        encoded_vars = URI.encode_www_form_component(variables.to_json)
        encoded_feats = URI.encode_www_form_component(features.to_json)

        resolved_id = query_id || XQueryIdResolver.new.resolve("SearchTimeline")

        "https://#{COOKIE_DOMAIN}/i/api/graphql/#{resolved_id}/SearchTimeline?" \
          "variables=#{encoded_vars}&features=#{encoded_feats}"
      end

      def self.build_headers(variables, features, query_id: QUERY_ID)
        txid = BuildTxid.new
        now_ms = Time.now.to_f.to_i * 1000

        cookies = CookieJar.for(COOKIE_DOMAIN)
        auth_token = cookies.find { |c| c["name"] == "auth_token" }&.dig("value") || ""
        ct0 = cookies.find { |c| c["name"] == "ct0" }&.dig("value") || ""

        cookie_header = cookies.map { |c| "#{c['name']}=#{c['value']}" }.join("; ")

        {
          "x-client-transaction-id" => txid.evidence_header(now_ms: now_ms, query_id: query_id),
          "x-twitter-auth-type" => "OAuth2Session",
          "x-twitter-active-user" => "yes",
          "x-twitter-client-language" => "en",
          "x-csrf-token" => ct0,
          "Cookie" => cookie_header,
          "Authorization" => "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA",
          "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          "Accept" => "*/*",
          "Accept-Language" => "en-US,en;q=0.9",
          "Origin" => "https://x.com",
          "Referer" => "https://x.com/"
        }
      end

      def self.parse_created_at(created_at_str)
        return nil if created_at_str.nil? || created_at_str.empty?

        begin
          Time.parse(created_at_str).utc.iso8601
        rescue ArgumentError, TypeError
          nil
        end
      end

      # ---------------------------------------------------------------------------
      # Erros nomeados
      # ---------------------------------------------------------------------------

      class RateLimited < Error
        def initialize(host, budget = GRAPHQL_BUDGET)
          scope_suffix = budget[:scope] ? " [#{budget[:scope]}]" : ""
          super("rate limit local: #{host} atingiu #{budget[:max]} leitura(s)/min " \
                "ou #{budget[:per_hour]}/hora#{scope_suffix} — repita daqui a pouco")
        end
      end

      class GraphQLError < Error
        def initialize(message = "graphql retornou erro")
          super("busca GraphQL do X falhou: #{message}")
        end
      end

      class RateLimitedRemote < Error
        def initialize(message = "rate limit remoto atingido")
          super("rate limit remoto do X: #{message}")
        end
      end
    end
  end
end
