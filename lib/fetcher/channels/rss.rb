# frozen_string_literal: true

require "feedjira"
require "time"
require_relative "../markdown_converter"

module Fetcher
  module Channels
    # Feed RSS 2.0, Atom 1.0 e RDF, pelo `feedjira`.
    #
    # Roteado por content-type, não por host: um blog pode servir Atom em /feed
    # sem dizer na URL. Como `application/xml` cobre qualquer XML, a confirmação é
    # pelo conteúdo — sitemap e SOAP chegam com o mesmo cabeçalho e têm que voltar
    # para o caminho comum.
    #
    # A primeira versão deste canal era um parser REXML escrito à mão, 132 linhas.
    # Trocado por biblioteca porque nada aqui é específico deste projeto: namespace
    # de Atom, CDATA, RDF, FeedBurner e encoding torto são problema resolvido há
    # uma década, e cada um era um bug esperando num parser caseiro. Os testes não
    # mudaram na troca — são a especificação, e passaram nas duas implementações.
    module Rss
      MAX_ITEMS     = 30
      SUMMARY_CHARS = 600
      ATOM_PARSERS  = %w[Feedjira::Parser::Atom Feedjira::Parser::AtomFeedBurner].freeze

      class << self
        def call(url:, response: nil)
          return nil if response.nil?

          feed = parse(response.body.to_s)
          return nil if feed.nil?

          build(url, response, feed)
        end

        private

        # `NoParserAvailable` é o caminho normal para sitemap e SOAP, não erro. O
        # `rescue StandardError` cobre o resto do que um XML hostil pode causar
        # dentro do SAX — a entrada vem de fora e não é confiável.
        def parse(xml)
          feed = Feedjira.parse(xml)
          # XML truncado pode selecionar um parser por prefixo e mesmo assim não
          # render nada. Sem título E sem entradas não é feed, é lixo que casou.
          return nil if feed.nil? || (feed.title.blank? && feed.entries.blank?)

          feed
        rescue Feedjira::NoParserAvailable
          nil
        rescue StandardError => e
          Rails.logger.info "[Fetcher::Channels::Rss] XML não parseou: #{e.class}: #{e.message}"
          nil
        end

        def build(url, response, feed)
          todos  = Array(feed.entries)
          usados = todos.first(MAX_ITEMS)

          {
            url:      response.final_url.to_s.presence || url,
            title:    feed.title.to_s,
            content:  render(usados),
            metadata: {
              "source"     => "rss",
              "kind"       => "feed",
              "format"     => ATOM_PARSERS.include?(feed.class.name) ? "atom" : "rss",
              "item_count" => usados.size,
              "item_total" => todos.size,
              "truncated"  => todos.size > usados.size
            }
          }
        end

        def render(items)
          items.map { |item| render_item(item) }.join("\n\n---\n\n")
        end

        def render_item(item)
          partes = ["## #{item.title.presence || '(sem título)'}"]
          partes << publicado_em(item)
          partes << item.url if item.url.present?
          partes << summarize(item.summary.presence || item.content)
          partes.compact_blank.join("\n\n")
        end

        def publicado_em(item)
          item.published&.utc&.iso8601
        rescue StandardError
          nil
        end

        # Descrição de feed vem com HTML dentro. O conversor da casa já resolve, e
        # reusá-lo mantém uma regra só de markdown no projeto inteiro.
        def summarize(raw)
          return nil if raw.blank?

          texto = MarkdownConverter.call(raw).strip
          texto = raw.strip if texto.empty?
          texto.length > SUMMARY_CHARS ? "#{texto[0, SUMMARY_CHARS]}…" : texto
        end
      end
    end
  end
end
