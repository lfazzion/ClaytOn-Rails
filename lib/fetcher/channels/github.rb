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
      class RateLimited < Error
        def initialize(host)
          super("rate limit local: #{host} atingiu #{MAX_PER_WINDOW} requisições/min — repita daqui a pouco")
        end
      end

      MAX_PER_WINDOW = 5
      MAX_COMMENTS   = 20
      MAX_RESULTADOS = 25
      HOST           = "github.com"
      API_HOST       = "api.github.com"

      # Identificadores do GitHub: letras, dígitos, hífen, underscore, ponto —
      # mas não podem ser ".", ".." nem começar com hífen. A âncora total
      # (sem sufixos) impede que /issues/12/comments ou path estranho seja
      # tratado como issue válida.
      OWNER_REPO   = %r{[A-Za-z0-9_.-]+}
      PATH_PATTERN = %r{\A/(?<owner>#{OWNER_REPO})/(?<repo>#{OWNER_REPO})/(?<kind>issues|pull)/(?<number>\d+)\z}

      class << self
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = clamp_limit(limit)
          raise RateLimited, API_HOST if HostRateLimiter.exceeded?(API_HOST, max: MAX_PER_WINDOW)

          since_date = (Time.now.utc - 30.days).strftime("%Y-%m-%d")
          q = "#{termo} created:>=#{since_date}"
          params = { q: q, sort: "reactions", order: "desc", per_page: n }
          search_url = "https://#{API_HOST}/search/issues?#{URI.encode_www_form(params)}"

          headers = build_headers
          http_resp = SafeHttpClient.get(search_url, headers: headers)

          if http_resp.status.in?([403, 429]) || http_resp.status >= 500
            Rails.logger.warn "[Fetcher::Channels::Github] search falhou com HTTP #{http_resp.status}"
            return []
          end

          raise ApiError, "API de busca do GitHub respondeu HTTP #{http_resp.status}" unless http_resp.success?

          payload = parse_json(http_resp.body)
          raise ApiError, "resposta inválida da API de busca do GitHub" unless payload.is_a?(Hash) && payload["items"].is_a?(Array)

          payload["items"].filter_map { |item| item_de_busca(item) }.first(n)
        end

        def call(url:, response: nil)
          info = issue_or_pr_info(url)
          return nil if info.nil?

          owner, repo, _kind, number = info
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
          raise ApiError, "resposta inválida da API do GitHub" unless payload.is_a?(Hash)
          # ACHADO D (revisão do sol, 13/08): a API pode responder 200 com um
          # Hash vazio ({}). `is_a?(Hash)` sozinho o aceitava e gerava um
          # resultado com título/autor vazios. Rejeitar o caso vazio força o
          # `rescue`/tratamento correto em vez de um issue fantasma.
          raise ApiError, "resposta da API do GitHub veio sem campos (Hash vazio)" if payload.empty?

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

        def clamp_limit(limit)
          [[limit.to_i, 1].max, MAX_RESULTADOS].min
        end

        def item_de_busca(item)
          return nil unless item.is_a?(Hash)

          url = item["html_url"].to_s
          return nil if url.blank?

          reactions = item["reactions"]
          total_reactions = if reactions.is_a?(Hash) && reactions["total_count"].is_a?(Numeric)
                              reactions["total_count"].to_i
                            elsif reactions.is_a?(Numeric)
                              reactions.to_i
                            else
                              0
                            end

          {
            "url"        => url,
            "title"      => item["title"].to_s,
            "source"     => "github",
            "reactions"  => total_reactions,
            "comments"   => (item["comments"].to_i if item["comments"].is_a?(Numeric)),
            "author"     => item.dig("user", "login").to_s,
            "created_at" => item["created_at"].to_s
          }
        end

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
