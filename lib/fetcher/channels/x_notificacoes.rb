# frozen_string_literal: true

require "json"
require "time"
require_relative "x_conta"
require_relative "x_feed"

module Fetcher
  module Channels
    # Menções à conta, lidas da aba "Menções" das notificações — o que o cliente web faz. A busca
    # (`(@conta OR to:conta) -from:conta`) volta sempre vazia para a conta do porteiro: contas novas ou de
    # pouca reputação não aparecem na busca do X, mas as menções chegam nas notificações.
    #
    # Contrato medido ao vivo em 2026-09-29: operação GraphQL `NotificationsTimeline` (chunk
    # `bundle.Notifications`; a REST antiga `notifications/mentions.json` só sobrou no `main`),
    # variáveis `{ timeline_type: "Mentions", count, cursor }`, resposta em
    # `data.viewer_v2.user_results.result.notification_timeline.timeline.instructions`. Timeline vazia =
    # só a entrada de cursor Top. A conta do porteiro não tinha menção nenhuma na medida, então a forma
    # das entradas COM posts não foi vista: os posts são achados por `tweet_results` em qualquer nível
    # (mesmo caminhar de `XConta.coleta`) e, se houver entradas que não sejam cursor e nenhum post
    # sair delas, é `ResponseError` — nunca lista vazia calada.
    module XNotificacoes
      BUDGET = { scope: "graphql_notif", max: 4, per_hour: 30 }.freeze
      OPERACAO = "NotificationsTimeline"
      TIPO = "Mentions"
      LIMITE_MAX = 40
      # `featureSwitches` da operação no bundle (medido em 2026-09-29); valor = o que o feed já manda,
      # e o que ele não conhece vai desligado.
      FLAGS = %w[
        rweb_video_screen_enabled rweb_cashtags_enabled profile_label_improvements_pcf_label_in_post_enabled
        responsive_web_profile_redirect_enabled rweb_tipjar_consumption_enabled verified_phone_label_enabled
        creator_subscriptions_tweet_preview_api_enabled responsive_web_graphql_timeline_navigation_enabled
        premium_content_api_read_enabled communities_web_enable_tweet_community_results_fetch
        c9s_tweet_anatomy_moderator_badge_enabled responsive_web_grok_analyze_button_fetch_trends_enabled
        responsive_web_grok_analyze_post_followups_enabled rweb_cashtags_composer_attachment_enabled
        responsive_web_jetfuel_frame rweb_sports_post_context_enabled responsive_web_grok_share_attachment_enabled
        responsive_web_grok_annotations_enabled articles_preview_enabled responsive_web_edit_tweet_api_enabled
        rweb_conversational_replies_downvote_enabled graphql_is_translatable_rweb_tweet_is_translatable_enabled
        view_counts_everywhere_api_enabled longform_notetweets_consumption_enabled
        responsive_web_twitter_article_tweet_consumption_enabled content_disclosure_indicator_enabled
        content_disclosure_ai_generated_indicator_enabled responsive_web_grok_show_grok_translated_post
        responsive_web_grok_analysis_button_from_backend post_ctas_fetch_enabled freedom_of_speech_not_reach_fetch_enabled
        standardized_nudges_misinfo tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled
        longform_notetweets_rich_text_read_enabled longform_notetweets_inline_media_enabled
        responsive_web_nested_quote_preview_enabled responsive_web_grok_image_annotation_enabled
        responsive_web_grok_imagine_annotation_enabled responsive_web_grok_community_note_auto_translation_is_enabled
        responsive_web_enhance_cards_enabled
      ].freeze
      FEATURES = FLAGS.to_h { |k| [k, XFeed::FEATURES.fetch(k, false)] }.freeze
      E = XEscrita

      module_function

      # Posts de terceiros que mencionam ou respondem a conta, do mais novo para o mais antigo.
      def mencoes(limite: 40)
        limite = Integer(limite)
        raise ArgumentError, "limite deve ser de 1 a #{LIMITE_MAX}" unless (1..LIMITE_MAX).cover?(limite)

        # POST como o resto das timelines: com as flags a URL do GET passa do teto do SsrfGuard.
        dados = XConta.get!(OPERACAO, { "timeline_type" => TIPO, "count" => limite }, FEATURES,
                            method: "POST", budget: BUDGET)
        dono, entradas = le_timeline!(dados)
        tweets = []
        XConta.coleta(entradas, tweets)
        if tweets.empty? && entradas.any? { |e| !cursor?(e) }
          raise E::ResponseError, "#{OPERACAO}: entradas sem posts reconhecíveis (forma nova?)"
        end

        tweets.reject { |t| t.dig("legacy", "user_id_str").to_s == dono }
              .uniq { |t| t["rest_id"] }.first(limite).map { |t| formata(t) }
      end

      # [id da conta, entradas]. Sem o id da conta não dá para excluir os posts dela, e sem `instructions`
      # a resposta não é uma timeline: ambos são erro, não vazio.
      def le_timeline!(dados)
        usuario = dados.dig("data", "viewer_v2", "user_results", "result")
        timeline = usuario.is_a?(Hash) ? usuario.dig("notification_timeline", "timeline") : nil
        instrucoes = timeline.is_a?(Hash) ? timeline["instructions"] : nil
        dono = usuario.is_a?(Hash) ? usuario["rest_id"].to_s : ""
        unless instrucoes.is_a?(Array) && !dono.empty?
          raise E::ResponseError, "#{OPERACAO}: resposta sem notification_timeline.timeline.instructions"
        end

        [dono, instrucoes.flat_map { |i| i.is_a?(Hash) ? Array(i["entries"]) + [i["entry"]].compact : [] }]
      end

      def cursor?(entrada)
        conteudo = entrada.is_a?(Hash) ? entrada["content"] : nil
        conteudo.is_a?(Hash) && conteudo.key?("cursorType")
      end

      def formata(tweet)
        legacy = tweet["legacy"]
        autor = XFeed.autor(tweet)
        resposta_a = legacy["in_reply_to_status_id_str"].to_s
        { "id" => tweet["rest_id"].to_s, "autor" => autor, "texto" => XFormato.texto(tweet),
          "criado_em" => (Time.parse(legacy["created_at"].to_s).utc.iso8601 rescue nil),
          "url" => "https://x.com/#{autor || 'i'}/status/#{tweet['rest_id']}",
          "em_resposta_a" => resposta_a.empty? ? nil : resposta_a, "e_resposta" => !resposta_a.empty? }
      end
    end
  end
end
