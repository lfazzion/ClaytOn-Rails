# frozen_string_literal: true

module Fetcher
  module Channels
    # Formato de um post lido do X: "artigo" (Article), "longo" (note_tweet, acima de 280) ou "curto".
    # Forma medida em 2026-09-29 (UserTweetsAndReplies): com `articles_preview_enabled` o Article vem em
    # `article.article_results.result` (`title`, `preview_text`) e o `full_text` é só o t.co para
    # `x.com/i/article/<id>`; o link é a reserva quando o bloco não vem. O post longo traz o texto
    # inteiro em `note_tweet` e o `full_text` cortado.
    module XFormato
      LINK_ARTIGO = %r{\Ahttps?://(?:x|twitter)\.com/i/article/\d+}

      module_function

      def campos(tweet)
        if artigo?(tweet)
          artigo = bloco_artigo(tweet) || {}
          return { "formato" => "artigo", "artigo" => { "titulo" => artigo["title"], "previa" => artigo["preview_text"] } }
        end
        { "formato" => nota(tweet) ? "longo" : "curto" }
      end

      # Artigo: título + prévia (o `full_text` seria só o t.co). Longo: o texto inteiro do note_tweet.
      def texto(tweet)
        artigo = bloco_artigo(tweet)
        partes = artigo ? [artigo["title"], artigo["preview_text"]].compact : []
        return partes.join("\n\n") unless partes.empty?

        (nota(tweet) || tweet.dig("legacy", "full_text")).to_s
      end

      def nota(tweet) = tweet.dig("note_tweet", "note_tweet_results", "result", "text")

      def bloco_artigo(tweet)
        artigo = tweet.dig("article", "article_results", "result")
        artigo if artigo.is_a?(Hash)
      end

      def artigo?(tweet)
        return true if bloco_artigo(tweet)

        urls = tweet.dig("legacy", "entities", "urls")
        urls.is_a?(Array) && urls.any? { |u| u.is_a?(Hash) && u["expanded_url"].to_s.match?(LINK_ARTIGO) }
      end
    end
  end
end
