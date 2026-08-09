# frozen_string_literal: true

require "json"
require "uri"
require_relative "registry"
require_relative "../safe_http_client"
require_relative "../host_rate_limiter"

module Fetcher
  module Channels
    # Canal para extração de Issues e Pull Requests do GitHub via REST API (api.github.com).
    module Github
      class Error < Fetcher::Channels::Error; end
      class ApiError < Error; end
      class IssueNotFound < Error; end

      MAX_PER_WINDOW = 5
      MAX_COMMENTS   = 20
      HOST           = "github.com"
      API_HOST       = "api.github.com"

      # Identificadores do GitHub: letras, dígitos, hífen, underscore, ponto —
      # mas não podem ser ".", ".." nem começar com hífen. A âncora total
      # (sem sufixos) impede que /issues/12/comments ou path estranho seja
      # tratado como issue válida.
      OWNER_REPO   = %r{[A-Za-z0-9_.-]+}
      PATH_PATTERN = %r{\A/(?<owner>#{OWNER_REPO})/(?<repo>#{OWNER_REPO})/(?<kind>issues|pull)/(?<number>\d+)\z}

      class << self
        def call(url:, response: nil)
          info = issue_or_pr_info(url)
          return nil if info.nil?

          owner, repo, kind, number = info
          headers = build_headers

          issue_url = "https://#{API_HOST}/repos/#{owner}/#{repo}/issues/#{number}"
          http_resp = SafeHttpClient.get(issue_url, headers: headers)

          raise IssueNotFound, "issue/PR #{owner}/#{repo}##{number} não encontrado" if http_resp.status == 404
          # 403/429 (cota do tier anônimo estourada) e 5xx não são "não existe":
          # o canal se declara incompetente (nil) e o ExtractService escala para o
          # HTML do GitHub, que funcionava antes deste canal existir. Sem isso, a
          # cota anônima de 60 req/h derrubaria TODAS as issues com error duro.
          return nil if http_resp.status.in?([403, 429]) || http_resp.status >= 500
          raise ApiError, "API do GitHub respondeu HTTP #{http_resp.status}" unless http_resp.success?

          payload = parse_json(http_resp.body)
          raise ApiError, "resposta inválida da API do GitHub" if payload.nil?

          comments = fetch_comments(owner, repo, number, headers) if payload["comments"].to_i.positive?
          comments ||= []

          build(url, owner, repo, number, payload, comments)
        end

        def issue_or_pr_info(url)
          uri = URI.parse(url.to_s)
          host = uri.host.to_s.downcase
          return nil unless host == HOST || host == "www.#{HOST}"

          match = uri.path.to_s.match(PATH_PATTERN)
          return nil unless match

          owner = match[:owner]
          repo  = match[:repo]
          return nil if owner == "." || owner == ".." || repo == "." || repo == ".."

          [owner, repo, match[:kind], match[:number].to_i]
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        private

        def build_headers
          headers = { "Accept" => "application/vnd.github+json" }
          token = ENV["GH_TOKEN"].presence || ENV["GITHUB_TOKEN"].presence
          headers["Authorization"] = "Bearer #{token}" if token.present?
          headers
        end

        def parse_json(raw)
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end

        def fetch_comments(owner, repo, number, headers)
          url = "https://#{API_HOST}/repos/#{owner}/#{repo}/issues/#{number}/comments?per_page=#{MAX_COMMENTS}"
          http_resp = SafeHttpClient.get(url, headers: headers)

          # Silêncio aqui produziria resumo "completo" sem os comentários que a
          # própria API anunciou (comment_total > 0). É erro nomeado, não []; o
          # ExtractService converte em campo error por URL.
          raise ApiError, "API de comentários do GitHub respondeu HTTP #{http_resp.status}" unless http_resp.success?

          list = parse_json(http_resp.body)
          raise ApiError, "resposta inválida da API de comentários do GitHub" unless list.is_a?(Array)

          list.filter_map do |c|
            body = c["body"].to_s.strip
            next nil if body.empty?

            {
              "author" => c.dig("user", "login").to_s,
              "body"   => body
            }
          end
        end

        def build(url, owner, repo, number, payload, comments)
          title = payload["title"].to_s
          state = payload["state"].to_s
          author = payload.dig("user", "login").to_s
          created_at = payload["created_at"].to_s
          is_pr = payload.key?("pull_request")
          labels = Array(payload["labels"]).map { |l| l["name"].to_s }
          body = payload["body"].to_s.strip

          content = render_markdown(title, state, is_pr, author, created_at, labels, body, comments)

          {
            url:          url,
            title:        title,
            content:      content,
            raw_content:  nil,
            metadata: {
              "source"        => "github",
              "kind"          => is_pr ? "pull_request" : "issue",
              "owner"         => owner,
              "repo"          => repo,
              "number"        => number,
              "state"         => state,
              "labels"        => labels,
              "num_comments"  => comments.size,
              "comment_total" => payload["comments"].to_i
            }
          }
        end

        def render_markdown(title, state, is_pr, author, created_at, labels, body, comments)
          type_label = is_pr ? "Pull Request" : "Issue"
          partes = ["# #{title}"]

          meta_line = "**Status:** #{state.upcase} | **Tipo:** #{type_label} | **Autor:** @#{author}"
          meta_line += " | **Data:** #{created_at}" if created_at.present?
          partes << meta_line

          partes << "**Labels:** #{labels.join(', ')}" if labels.any?

          if body.present?
            partes << "## Descrição"
            partes << body
          end

          unless comments.empty?
            partes << "## Comentários"
            comments.each do |c|
              partes << "- **@#{c['author']}**: #{c['body']}"
            end
          end

          partes.join("\n\n")
        end
      end
    end
  end
end
