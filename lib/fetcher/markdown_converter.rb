# frozen_string_literal: true

require "nokogiri"

module Fetcher
  # HTML de artigo → Markdown.
  #
  # O consumidor é um LLM: markdown corta a maior parte dos tokens do HTML
  # (tags, atributos, classes) preservando o que dá estrutura à leitura —
  # títulos, listas, tabelas, links e blocos de código. Texto cru perderia
  # essa hierarquia; HTML cru custa caro sem acrescentar nada.
  module MarkdownConverter
    BLOCK_TAGS = %w[p div section article header footer main aside figure figcaption
                    h1 h2 h3 h4 h5 h6 ul ol li pre blockquote table tr hr br].freeze
    DROPPED_TAGS = %w[script style noscript svg canvas iframe form input button select
                      textarea nav].freeze

    class << self
      def call(html)
        return "" if html.to_s.strip.empty?

        doc = Nokogiri::HTML::DocumentFragment.parse(html.to_s)
        doc.css(DROPPED_TAGS.join(",")).each(&:remove)

        tidy(render(doc))
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::MarkdownConverter] falhou: #{e.class}: #{e.message}"
        ""
      end

      private

      def render(node, depth: 0, list: nil, index: 0)
        return escape_text(node.text) if node.text?
        return "" unless node.element? || node.fragment?

        case node.name
        when "h1", "h2", "h3", "h4", "h5", "h6"
          level = node.name[1].to_i
          block("#{'#' * level} #{inline(node)}")
        when "p"        then block(inline(node))
        when "br"       then "\n"
        when "hr"       then block("---")
        when "pre"      then block(code_block(node))
        when "blockquote"
          block(children(node, depth: depth).strip.split("\n").map { |l| "> #{l}".rstrip }.join("\n"))
        when "ul", "ol" then block(list_items(node, depth: depth))
        when "li"       then list_item(node, depth: depth, list: list, index: index)
        when "table"    then block(table(node))
        when "img"      then image(node)
        when "a"        then link(node)
        when "code"     then "`#{node.text.strip}`"
        when "strong", "b" then wrap(node, "**")
        when "em", "i"     then wrap(node, "*")
        else
          children(node, depth: depth)
        end
      end

      def children(node, depth: 0)
        node.children.map { |child| render(child, depth: depth) }.join
      end

      # Conteúdo inline de um bloco: colapsa quebras internas.
      def inline(node)
        children(node).gsub(/\s*\n\s*/, " ").squeeze(" ").strip
      end

      def block(text)
        text.to_s.strip.empty? ? "" : "\n\n#{text.strip}\n\n"
      end

      def wrap(node, marker)
        content = inline(node)
        content.empty? ? "" : "#{marker}#{content}#{marker}"
      end

      def link(node)
        text = inline(node)
        href = node["href"].to_s.strip
        return text if href.empty? || href.start_with?("javascript:", "data:")
        return href if text.empty?

        "[#{text}](#{href})"
      end

      def image(node)
        alt = node["alt"].to_s.strip
        alt.empty? ? "" : "![#{alt}]"
      end

      def code_block(node)
        "```\n#{node.text.to_s.strip}\n```"
      end

      def list_items(node, depth:)
        ordered = node.name == "ol"
        items = node.xpath("./li")
        items.each_with_index.map do |li, i|
          list_item(li, depth: depth, list: ordered ? :ol : :ul, index: i + 1)
        end.join("\n")
      end

      def list_item(node, depth:, list:, index:)
        marker = list == :ol ? "#{index}." : "-"
        indent = "  " * depth

        nested = node.xpath("./ul | ./ol").map do |sub|
          list_items(sub, depth: depth + 1)
        end.join("\n")

        own = node.children.reject { |c| %w[ul ol].include?(c.name) }
                  .map { |c| render(c, depth: depth) }.join
        own = own.gsub(/\s*\n\s*/, " ").squeeze(" ").strip

        line = "#{indent}#{marker} #{own}".rstrip
        nested.empty? ? line : "#{line}\n#{nested}"
      end

      def table(node)
        rows = node.xpath(".//tr").map do |tr|
          cells = tr.xpath("./th | ./td").map { |cell| inline(cell).gsub("|", "\\|") }
          next if cells.empty?

          "| #{cells.join(' | ')} |"
        end.compact
        return "" if rows.empty?

        header_cells = node.xpath(".//tr").first&.xpath("./th | ./td")&.size.to_i
        separator = "|#{Array.new([header_cells, 1].max) { ' --- ' }.join('|')}|"
        ([rows.first, separator] + rows[1..].to_a).join("\n")
      end

      def escape_text(text)
        text.to_s.gsub(" ", " ")
      end

      def tidy(markdown)
        markdown.to_s
                .gsub(/[ \t]+\n/, "\n")
                .gsub(/\n{3,}/, "\n\n")
                .gsub(/^[ \t]+$/, "")
                .strip
      end
    end
  end
end
