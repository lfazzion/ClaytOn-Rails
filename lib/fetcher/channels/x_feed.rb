# frozen_string_literal: true

require "time"
require_relative "x_conta"

module Fetcher
  module Channels
    # Timeline da conta (experimento-x): "Para você" (HomeTimeline) e "Seguindo" (HomeLatestTimeline),
    # uma página por chamada, com o cursor da próxima. Promovidos ficam de fora; métrica que o X não
    # mandou fica nil — nunca 0.
    module XFeed
      BUDGET = { scope: "graphql_feed", max: 6, per_hour: 120 }.freeze
      OPERACOES = { "para_voce" => "HomeTimeline", "seguindo" => "HomeLatestTimeline" }.freeze
      LIMITE_MAX = 40
      # As flags de HomeTimeline/HomeLatestTimeline no bundle (medido em 28/09/2026) = as de
      # XConversation mais estas, que mandamos desligadas.
      FEATURES = XConversation::FEATURES.merge(
        %w[rweb_cashtags_enabled rweb_cashtags_composer_attachment_enabled rweb_sports_post_context_enabled
           responsive_web_grok_annotations_enabled rweb_conversational_replies_downvote_enabled
           content_disclosure_indicator_enabled content_disclosure_ai_generated_indicator_enabled
           post_ctas_fetch_enabled responsive_web_nested_quote_preview_enabled].to_h { |k| [k, false] }
      ).freeze
      E = XEscrita

      module_function

      def ler(tipo:, cursor: nil, limite: 20)
        operacao = OPERACOES.fetch(tipo.to_s) { raise ArgumentError, "tipo deve ser para_voce ou seguindo" }
        limite = Integer(limite)
        raise ArgumentError, "limite deve ser de 1 a #{LIMITE_MAX}" unless (1..LIMITE_MAX).cover?(limite)

        # POST como UserTweetsAndReplies (a URL do GET passa do teto do SsrfGuard).
        dados = XConta.get!(operacao, variaveis(operacao, cursor, limite), FEATURES, method: "POST", budget: BUDGET)
        timeline = dados.dig("data", "home", "home_timeline_urt")
        raise E::ResponseError, "#{operacao}: resposta sem home_timeline_urt" unless timeline.is_a?(Hash)

        entradas = Array(timeline["instructions"]).flat_map { |i| Array(i["entries"]) + [i["entry"]].compact }
        posts = entradas.flat_map { |e| tweets(e) }.map { |t| formata(t) }.uniq { |p| p["id"] }.first(limite)
        { "posts" => posts, "proximo_cursor" => cursor_de_baixo(entradas) }
      end

      # As do cliente web (medido em 28/09/2026). `requestContext: "launch"` só na primeira página.
      def variaveis(operacao, cursor, limite)
        v = { "count" => limite, "includePromotedContent" => false, "latestControlAvailable" => true }
        cursor.to_s.empty? ? v["requestContext"] = "launch" : v["cursor"] = cursor.to_s
        operacao == "HomeTimeline" ? v["withCommunity"] = true : v["enableRanking"] = false
        v
      end

      # Tweets de uma entrada: item solto ou módulo (conversa). Promovido (entrada `promoted-*` ou item
      # com `promotedMetadata`), tombstone e resultado sem legacy ficam de fora.
      def tweets(entrada)
        return [] if entrada["entryId"].to_s.start_with?("promoted-")

        conteudo = entrada["content"] || {}
        itens = conteudo["itemContent"] ? [conteudo["itemContent"]] : Array(conteudo["items"]).map { |i| i.dig("item", "itemContent") }
        itens.compact.reject { |ic| ic.key?("promotedMetadata") }.filter_map { |ic| desembrulha(ic.dig("tweet_results", "result")) }
      end

      def desembrulha(resultado)
        resultado = resultado["tweet"] if resultado.is_a?(Hash) && resultado["__typename"] == "TweetWithVisibilityResults"
        resultado if resultado.is_a?(Hash) && resultado["rest_id"] && resultado["legacy"].is_a?(Hash)
      end

      def cursor_de_baixo(entradas)
        entradas.map { |e| e["content"] || {} }.find { |c| c["cursorType"] == "Bottom" }&.fetch("value", nil)
      end

      # Repost: sai o post ORIGINAL (id, autor, texto e métricas dele, para responder/curtir o post
      # certo), marcado com `e_repost` e com quem repostou.
      def formata(tweet)
        original = desembrulha(tweet.dig("legacy", "retweeted_status_result", "result"))
        base = original || tweet
        legacy = base["legacy"]
        autor = autor(base)
        views = base.dig("views", "count")
        { "id" => base["rest_id"].to_s, "autor" => autor,
          "texto" => XFormato.texto(base),
          "criado_em" => (Time.parse(legacy["created_at"].to_s).utc.iso8601 rescue nil),
          "impressoes" => views && Integer(views, exception: false),
          "respostas" => legacy["reply_count"], "curtidas" => legacy["favorite_count"], "reposts" => legacy["retweet_count"],
          "url" => "https://x.com/#{autor || 'i'}/status/#{base['rest_id']}",
          "e_resposta" => !legacy["in_reply_to_status_id_str"].to_s.empty?,
          "e_repost" => !original.nil?, "repostado_por" => original && autor(tweet) }.merge(XFormato.campos(base))
      end

      def autor(tweet)
        usuario = tweet.dig("core", "user_results", "result") || {}
        usuario.dig("core", "screen_name") || usuario.dig("legacy", "screen_name")
      end
    end
  end
end
