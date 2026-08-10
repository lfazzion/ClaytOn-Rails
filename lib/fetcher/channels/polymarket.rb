# frozen_string_literal: true

require "cgi"
require "json"
require "uri"
require_relative "registry"
require_relative "../safe_http_client"
require_relative "../host_rate_limiter"

module Fetcher
  module Channels
    # Canal para extração de eventos do Polymarket via API Gamma pública (gamma-api.polymarket.com).
    module Polymarket
      class Error < Fetcher::Channels::Error; end
      class ApiError < Error; end
      class InvalidResponse < Error; end
      class EventNotFound < Error; end
      class RateLimited < Error
        def initialize(host)
          super("rate limit local: #{host} atingiu #{MAX_PER_WINDOW} requisições/min — repita daqui a pouco")
        end
      end

      MAX_PER_WINDOW = 5
      MAX_RESULTADOS = 25
      HOST           = "polymarket.com"
      GAMMA_HOST     = "gamma-api.polymarket.com"
      # Só /event/: a Gamma API de eventos é consultada por slug de EVENTO;
      # /market/<slug> responderia EventNotFound (erro duro) porque o slug de
      # mercado não existe em /events — então market cai no caminho comum (nil).
      PATH_PATTERN   = %r{\A/event/([^/?#]+)\z}

      class << self
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = clamp_limit(limit)
          raise RateLimited, GAMMA_HOST if HostRateLimiter.exceeded?(GAMMA_HOST, max: MAX_PER_WINDOW)

          search_url = "https://#{GAMMA_HOST}/events?#{URI.encode_www_form(search: termo, limit: n)}"
          http_resp = SafeHttpClient.get(search_url)

          unless http_resp.success?
            Rails.logger.warn "[Fetcher::Channels::Polymarket] search falhou com HTTP #{http_resp.status}"
            return []
          end

          events = parse_json(http_resp.body)
          unless events.is_a?(Array)
            Rails.logger.warn "[Fetcher::Channels::Polymarket] resposta de busca inválida da Gamma API"
            return []
          end

          events.filter_map { |event| item_de_busca(event) }.first(n)
        end

        def call(url:, response: nil)
          slug = event_slug_from(url)
          return nil if slug.nil?

          api_url = "https://#{GAMMA_HOST}/events?slug=#{CGI.escape(slug)}"
          http_resp = SafeHttpClient.get(api_url)

          raise ApiError, "API do Polymarket respondeu HTTP #{http_resp.status}" unless http_resp.success?

          events = parse_json(http_resp.body)
          raise InvalidResponse, "resposta inválida da API do Polymarket" unless events.is_a?(Array)
          raise EventNotFound, "evento '#{slug}' não encontrado na Gamma API" if events.empty?

          event = events.first
          build(url, slug, event)
        end

        def event_slug_from(url)
          uri = URI.parse(url.to_s)
          host = uri.host.to_s.downcase
          return nil unless host == HOST || host == "www.#{HOST}"

          match = uri.path.to_s.match(PATH_PATTERN)
          match ? match[1] : nil
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        private

        def clamp_limit(limit)
          [[limit.to_i, 1].max, MAX_RESULTADOS].min
        end

        def item_de_busca(event)
          return nil unless event.is_a?(Hash)

          slug = event["slug"].to_s
          return nil if slug.blank?

          created_at = event["createdAt"].presence || event["created_at"].presence || event["creationDate"].presence

          {
            "url"        => "https://polymarket.com/event/#{slug}",
            "title"      => event["title"].to_s,
            "source"     => "polymarket",
            "volume"     => (event["volume"].to_f if event["volume"].is_a?(Numeric)),
            "liquidity"  => (event["liquidity"].to_f if event["liquidity"].is_a?(Numeric)),
            "created_at" => created_at
          }
        end

        def parse_json(raw)
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end

        def build(url, slug, event)
          title = event["title"].to_s
          description = event["description"].to_s.strip
          volume = event["volume"]
          liquidity = event["liquidity"]

          markets = Array(event["markets"]).map do |m|
            parse_market(m)
          end

          content = render_markdown(title, description, volume, liquidity, markets)

          {
            url:          url,
            title:        title,
            content:      content,
            raw_content:  nil,
            metadata: {
              "source"        => "polymarket",
              "kind"          => "event",
              "slug"          => slug,
              "markets_count" => markets.size,
              "volume"        => volume,
              "liquidity"     => liquidity
            }
          }
        end

        def parse_market(m)
          question = m["question"].to_s.presence || m["groupItemTitle"].to_s.presence || "(mercado)"
          outcomes = parse_array_field(m["outcomes"])
          prices = parse_array_field(m["outcomePrices"])

          # Sem preço não vira "0.0%": zero é informação falsa (CLAUDE.md Regra 3).
          # Só monta o par quando preço veio de verdade.
          pairs = outcomes.zip(prices).filter_map do |o, p|
            next nil if p.nil?

            price_val = p.to_f
            next nil unless price_val.positive?

            pct = (price_val * 100).round(1)
            "#{o}: #{pct}%"
          end

          {
            "question" => question,
            "outcomes" => pairs,
            "volume"   => m["volume"]
          }
        end

        def parse_array_field(field)
          return field if field.is_a?(Array)

          if field.is_a?(String)
            parsed = parse_json(field)
            return parsed if parsed.is_a?(Array)
          end

          []
        end

        def render_markdown(title, description, volume, liquidity, markets)
          partes = ["# #{title}"]

          if description.present?
            partes << description
          end

          stats = []
          stats << "**Volume Total:** $#{format_number(volume)}" if volume
          stats << "**Liquidez:** $#{format_number(liquidity)}" if liquidity
          partes << stats.join(" | ") if stats.any?

          unless markets.empty?
            partes << "## Mercados"
            markets.each do |m|
              partes << "### #{m['question']}"
              partes << "- **Probabilidades:** #{m['outcomes'].join(', ')}" if m["outcomes"].any?
              partes << "- **Volume:** $#{format_number(m['volume'])}" if m["volume"]
            end
          end

          partes.join("\n\n")
        end

        def format_number(val)
          num = val.to_f
          if num >= 1_000_000
            "#{format('%.2f', num / 1_000_000)}M"
          elsif num >= 1_000
            "#{format('%.2f', num / 1_000)}K"
          else
            format("%.2f", num)
          end
        rescue StandardError
          val.to_s
        end
      end
    end
  end
end
