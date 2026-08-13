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
        return text if href.empty? || dangerous_scheme?(href)
        return href if text.empty?

        "[#{text}](#{href})"
      end

      def image(node)
        alt = node["alt"].to_s.strip
        src = node["src"].to_s.strip
        return "" if alt.empty? || src.empty?
        # Allowlist explícita http/https (ACHADO E, revisão do sol, 13/08): a
        # denylist de 3 esquemas deixava passar file:, esquemas desconhecidos e
        # protocol-relative. Caminhos relativos (sem esquema) são seguros.
        return "" unless safe_image_src?(src)
        "![#{alt}](#{src})"
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
        rows = node.xpath("./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr").map do |tr|
          tr.xpath("./th | ./td").map { |cell| inline(cell).gsub("|", "\\|") }
        end
        rows.reject!(&:empty?)
        return "" if rows.empty?

        separator = "| #{(["---"] * rows.first.size).join(" | ")} |"
        ([serialize_row(rows.first), separator] + rows[1..].map { |r| serialize_row(r) }).join("\n")
      end

      def serialize_row(cells)
        "| #{cells.join(" | ")} |"
      end

      def escape_text(text)
        text.to_s.gsub(" ", " ")
      end

      # Bloqueia `javascript:`, `data:` e `vbscript:` independentemente de case,
      # incluindo variantes como `java\u0009script:` ou `java\nscript:` que
      # navegadores costumam aceitar. O case-sensitive `start_with?` original
      # deixava passar `JavaScript:` e `Data:`.
      DANGEROUS_SCHEMES = %w[javascript: data: vbscript:].freeze
      private_constant :DANGEROUS_SCHEMES

      # Allowlist de esquemas para imagens (ACHADO E, 13/08): só http/https
      # explícitos passam. Caminhos relativos (sem "://", ex: "images/x.png",
      # "/img.png") são considerados seguros e preservados. Tudo que tiver um
      # esquema que não seja http/https — file:, ftp:, javascript:, data:,
      # vbscript:, protocol-relative (//host) — é bloqueado.
      def safe_image_src?(src)
        # Protocol-relative (//host) ou esquema desconhecido (javascript:, data:).
        scheme_sep = src.index("://")
        # Protocol-relative: começa com "//" e não tem esquema http/https → rejeita.
        return false if src.start_with?("//")
        # Esquema sem "://" (ex: "javascript:alert(1)", "mailto:x") → não é http/https.
        return false if src.include?(":") && scheme_sep.nil?
        # Sem ":", é caminho relativo (ex: "images/x.png", "/img.png") → seguro.
        return true unless scheme_sep

        scheme = src[0, scheme_sep].gsub(/\s+/, "").downcase
        %w[http https].include?(scheme)
      end

      def dangerous_scheme?(src)
        # Normaliza espaçamento interno do scheme (tabs/newlines) como fazem
        # navegadores, depois compara case-insensitivo.
        scheme_end = src.index(":")
        return false unless scheme_end
        scheme = src[0, scheme_end].gsub(/\s+/, "").downcase
        scheme.empty? || DANGEROUS_SCHEMES.any? { |s| scheme == s.chomp(":") }
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
