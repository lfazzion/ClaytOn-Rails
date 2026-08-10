# frozen_string_literal: true

require "cgi"
require "json"
require "uri"
require_relative "registry"
require_relative "../safe_http_client"
require_relative "../host_rate_limiter"

module Fetcher
  module Channels
    # Canal para extração de itens (stories/threads) do Hacker News via API pública da Algolia (hn.algolia.com).
    module Hackernews
      class Error < Fetcher::Channels::Error; end
      class ApiError < Error; end
      class ItemNotFound < Error; end
      class RateLimited < Error
        def initialize(host)
          super("rate limit local: #{host} atingiu #{MAX_PER_WINDOW} requisições/min — repita daqui a pouco")
        end
      end

      MAX_PER_WINDOW = 5
      MAX_COMMENTS   = 20
      MAX_RESULTADOS = 25
      HOST           = "news.ycombinator.com"
      ALGOLIA_HOST   = "hn.algolia.com"

      class << self
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = clamp_limit(limit)
          raise RateLimited, ALGOLIA_HOST if HostRateLimiter.exceeded?(ALGOLIA_HOST, max: MAX_PER_WINDOW)

          epoch = (Time.now.utc - 30.days).to_i
          params = {
            query: termo,
            tags: "story",
            hitsPerPage: n,
            numericFilters: "created_at_i>#{epoch}"
          }
          search_url = "https://#{ALGOLIA_HOST}/api/v1/search?#{URI.encode_www_form(params)}"
          http_resp = SafeHttpClient.get(search_url)

          raise ApiError, "API do HN respondeu HTTP #{http_resp.status}" unless http_resp.success?

          payload = parse_json(http_resp.body)
          raise ApiError, "resposta inválida da API do HN" unless payload.is_a?(Hash) && payload["hits"].is_a?(Array)

          payload["hits"].filter_map { |hit| item_de_busca(hit) }.first(n)
        end

        def call(url:, response: nil)
          id = item_id_from(url)
          return nil if id.nil?

          api_url = "https://#{ALGOLIA_HOST}/api/v1/items/#{id}"
          http_resp = SafeHttpClient.get(api_url)

          raise ItemNotFound, "item #{id} não encontrado no HN" if http_resp.status == 404
          raise ApiError, "API do HN respondeu HTTP #{http_resp.status}" unless http_resp.success?

          payload = parse_json(http_resp.body)
          raise ApiError, "resposta inválida da API do HN" if payload.nil?

          build(url, id, payload)
        end

        def item_id_from(url)
          uri = URI.parse(url.to_s)
          host = uri.host.to_s.downcase

          if host == HOST || host == "www.#{HOST}"
            return nil unless uri.path == "/item"

            params = URI.decode_www_form(uri.query.to_s).to_h
            id = params["id"].to_s
            id.match?(/\A\d+\z/) ? id : nil
          elsif host == ALGOLIA_HOST
            m = uri.path.to_s.match(%r{\A/item/(\d+)\z})
            m ? m[1] : nil
          end
        rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError
          nil
        end

        private

        def clamp_limit(limit)
          [[limit.to_i, 1].max, MAX_RESULTADOS].min
        end

        def item_de_busca(hit)
          return nil unless hit.is_a?(Hash)

          object_id = hit["objectID"].to_s
          return nil if object_id.blank?

          created_at_i = hit["created_at_i"]
          created_at = if created_at_i.is_a?(Numeric)
                         Time.at(created_at_i.to_i).utc.iso8601
                       else
                         hit["created_at"].to_s.presence
                       end

          {
            "url"          => "https://news.ycombinator.com/item?id=#{object_id}",
            "title"        => hit["title"].to_s.presence || hit["story_title"].to_s.presence || "(sem título)",
            "source"       => "hackernews",
            "points"       => (hit["points"].to_i if hit["points"].is_a?(Numeric)),
            "comments"     => (hit["num_comments"].to_i if hit["num_comments"].is_a?(Numeric)),
            "author"       => hit["author"].to_s,
            "created_at"   => created_at,
            "external_url" => hit["url"].to_s.presence
          }
        end

        def parse_json(raw)
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end

        def build(url, id, payload)
          title = payload["title"].to_s.presence || payload["story_title"].to_s.presence || "(sem título)"
          author = payload["author"].to_s
          points = payload["points"]
          ext_url = payload["url"].to_s
          text = strip_html(payload["text"].to_s)

          children = Array(payload["children"])
          comments = children.filter_map do |c|
            body = strip_html(c["text"].to_s)
            next nil if body.blank?

            {
              "author" => c["author"].to_s,
              "points" => c["points"].to_i,
              "body"   => body
            }
          end.first(MAX_COMMENTS)

          content = render_markdown(title, author, points, id, ext_url, text, comments)

          {
            url:          url,
            title:        title,
            content:      content,
            raw_content:  nil,
            metadata: {
              "source"        => "hackernews",
              "kind"          => "story",
              "item_id"       => id.to_s,
              "author"        => author,
              "points"        => points,
              "num_comments"  => comments.size,
              "comment_total" => children.size
            }
          }
        end

        def render_markdown(title, author, points, id, ext_url, text, comments)
          hn_link = "https://news.ycombinator.com/item?id=#{id}"
          partes = ["# #{title}"]
          # Métrica ausente não vira "0 pontos": zero é informação falsa para o
          # modelo (CLAUDE.md Regra 3). Sem pontos, omite o número.
          meta = "por **#{author}** | [Hacker News](#{hn_link})"
          meta = "por **#{author}** | #{points} pontos | [Hacker News](#{hn_link})" if points
          partes << meta
          partes << "Link externo: #{ext_url}" if ext_url.present? && ext_url != hn_link
          partes << text if text.present?

          unless comments.empty?
            partes << "## Comentários"
            comments.each do |c|
              score = c['points'].to_i
              score_label = score.positive? ? " (#{score} pts)" : ""
              partes << "- **#{c['author']}**#{score_label}: #{c['body']}"
            end
          end

          partes.join("\n\n")
        end

        def strip_html(html)
          return "" if html.blank?

          str = CGI.unescapeHTML(html.to_s)
          str.gsub!(%r{<p/?>|<br\s*/?>}, "\n\n")
          str.gsub!(/<[^>]+>/, "")
          str.gsub!(/\n{3,}/, "\n\n")
          str.strip
        end
      end
    end
  end
end
