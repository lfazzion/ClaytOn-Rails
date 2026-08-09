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
      HOST           = "news.ycombinator.com"
      ALGOLIA_HOST   = "hn.algolia.com"

      class << self
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
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        private

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
          partes << "por **#{author}** | #{points || 0} pontos | [Hacker News](#{hn_link})"
          partes << "Link externo: #{ext_url}" if ext_url.present? && ext_url != hn_link
          partes << text if text.present?

          unless comments.empty?
            partes << "## Comentários"
            comments.each do |c|
              partes << "- **#{c['author']}** (#{c['points']} pts): #{c['body']}"
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
