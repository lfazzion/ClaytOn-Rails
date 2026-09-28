# frozen_string_literal: true

require "json"
require "time"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"
require_relative "../ssrf_guard"
require_relative "x_graphql"
require_relative "x_conversation"
require_relative "x_escrita"

module Fetcher
  module Channels
    # Perfil e posts de uma conta (placar do experimento-x): seguidores e, por post, impressões,
    # respostas, curtidas e reposts. Métrica que o X não mandou fica nil — nunca 0.
    module XConta
      COOKIE_DOMAIN = "x.com"
      BUDGET = { scope: "graphql_conta", max: 4, per_hour: 30 }.freeze
      USER_FEATURES = {
        "hidden_profile_subscriptions_enabled" => true,
        "rweb_tipjar_consumption_enabled" => true,
        "responsive_web_graphql_exclude_directive_enabled" => true,
        "verified_phone_label_enabled" => false,
        "subscriptions_verification_info_is_identity_verified_enabled" => true,
        "subscriptions_verification_info_verified_since_enabled" => true,
        "highlights_tweets_tab_ui_enabled" => true,
        "responsive_web_twitter_article_notes_tab_enabled" => true,
        "subscriptions_feature_can_gift_premium" => true,
        "creator_subscriptions_tweet_preview_api_enabled" => true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled" => false,
        "responsive_web_graphql_timeline_navigation_enabled" => true
      }.freeze
      E = XEscrita

      module_function

      def perfil(usuario:)
        dados = get!("UserByScreenName", { "screen_name" => usuario.to_s, "withSafetyModeUserFields" => true },
                     USER_FEATURES)
        user = dados.dig("data", "user", "result")
        raise E::ResponseError, "UserByScreenName: conta #{usuario} não encontrada" unless user.is_a?(Hash) && user["rest_id"]

        # Forma medida em 2026-09-27: contadores em `relationship_counts`/`tweet_counts`, sem `legacy`.
        # A forma antiga (`legacy.*_count`) fica como reserva.
        legacy = user["legacy"] || {}
        { "id" => user["rest_id"].to_s,
          "usuario" => user.dig("core", "screen_name") || legacy["screen_name"],
          "seguidores" => user.dig("relationship_counts", "followers") || legacy["followers_count"],
          "seguindo" => user.dig("relationship_counts", "following") || legacy["friends_count"],
          "posts" => user.dig("tweet_counts", "tweets") || legacy["statuses_count"] }
      end

      # UserTweetsAndReplies (e não UserTweets): as respostas da conta entram no placar. A timeline
      # traz posts de terceiros (a conversa em volta das respostas) e os reposts da própria conta;
      # os dois ficam de fora. Variáveis = as do cliente web (medido em 27/09), sem promovidos.
      def posts(usuario_id:, limite: 20)
        variaveis = { "userId" => usuario_id.to_s, "count" => limite.to_i, "includePromotedContent" => false,
                      "withCommunity" => true, "withQuickPromoteEligibilityTweetFields" => true, "withVoice" => true }
        # POST: com as flags de FEATURES a URL do GET passa do teto de 2048 do SsrfGuard (medido).
        dados = get!("UserTweetsAndReplies", variaveis, XConversation::FEATURES, method: "POST")
        tweets = []
        coleta(dados, tweets)
        tweets.select { |t| t.dig("legacy", "user_id_str").to_s == usuario_id.to_s && !repost?(t) }
              .uniq { |t| t["rest_id"] }.first(limite.to_i).map { |t| formata(t) }
      end

      # Repost da própria conta: o post original (se for da conta) já vem como entrada separada
      # (medido em 27/09), então o embrulho do repost não conta.
      def repost?(tweet)
        legacy = tweet["legacy"]
        legacy.key?("retweeted_status_result") || legacy["full_text"].to_s.start_with?("RT @")
      end

      def get!(operacao, variaveis, features, method: "GET")
        CookieJar.require!(COOKIE_DOMAIN)
        raise E::RateLimited, "trava local de leitura da conta" if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **BUDGET)

        resposta = E.com_query_id(operacao) do |query_id|
          url = XGraphql.build_url("", variaveis, features, query_id, operation: operacao, method: method)
          headers = XGraphql.build_headers(variaveis, features, query_id: query_id, operation: operacao, method: method)
          if method == "POST"
            corpo = { "variables" => variaveis, "features" => features, "queryId" => query_id }
            SafeHttpClient.post(url, json: corpo, headers: headers)
          else
            SafeHttpClient.get(url, headers: headers)
          end
        end
        E.interpreta!(resposta, operacao)
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        # Leitura: não há ação a ficar incerta, então toda falha de rede é ResponseError.
        raise E::ResponseError, "falha de rede em #{operacao} (#{e.class.name}): #{e.message}"
      end

      # Caminha o JSON inteiro: a timeline muda de forma (módulos, pins, conversas) com frequência.
      def coleta(no, saida)
        case no
        when Hash
          resultado = no.dig("tweet_results", "result")
          resultado = resultado["tweet"] if resultado.is_a?(Hash) && resultado["__typename"] == "TweetWithVisibilityResults"
          saida << resultado if resultado.is_a?(Hash) && resultado["rest_id"] && resultado["legacy"].is_a?(Hash)
          no.each_value { |v| coleta(v, saida) }
        when Array then no.each { |v| coleta(v, saida) }
        end
      end

      def formata(tweet)
        legacy = tweet["legacy"]
        views = tweet.dig("views", "count")
        { "id" => tweet["rest_id"].to_s, "texto" => legacy["full_text"].to_s,
          "criado_em" => (Time.parse(legacy["created_at"].to_s).utc.iso8601 rescue nil),
          "impressoes" => views && Integer(views, exception: false),
          "respostas" => legacy["reply_count"], "curtidas" => legacy["favorite_count"],
          "reposts" => legacy["retweet_count"] }
      end
    end
  end
end
