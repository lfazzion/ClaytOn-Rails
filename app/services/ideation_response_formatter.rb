# frozen_string_literal: true

require "json"

module IdeationResponseFormatter
  class << self
    def format(raw_response)
      return "" if raw_response.nil?

      text = raw_response.to_s.strip
      return "" if text.empty?

      parsed = try_parse_json(text)
      return text unless parsed

      format_json(parsed)
    end

    private

    def try_parse_json(text)
      # 1. Parse direto se já for string JSON
      if (text.start_with?("{") && text.end_with?("}")) ||
         (text.start_with?("[") && text.end_with?("]"))
        begin
          return JSON.parse(text)
        rescue JSON::ParserError
          # prossegue para outras tentativas
        end
      end

      # 2. Extração de bloco markdown ```json ... ``` ou ``` ... ```
      if text =~ /```(?:json)?\s*([\s\S]*?)\s*```/i
        candidate = $1.strip
        if (candidate.start_with?("{") && candidate.end_with?("}")) ||
           (candidate.start_with?("[") && candidate.end_with?("]"))
          begin
            return JSON.parse(candidate)
          rescue JSON::ParserError
            # prossegue para fallback
          end
        end
      end

      # 3. Remoção de fences no início e fim
      stripped = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "").strip
      if (stripped.start_with?("{") && stripped.end_with?("}")) ||
         (stripped.start_with?("[") && stripped.end_with?("]"))
        begin
          return JSON.parse(stripped)
        rescue JSON::ParserError
          # ignora
        end
      end

      nil
    end

    def format_json(data)
      items = extract_items(data)
      return "" if items.empty?

      formatted_items = items.each_with_index.map do |item, index|
        format_item(item, index + 1)
      end

      formatted_items.join("\n")
    end

    def extract_items(data)
      if data.is_a?(Array)
        data
      elsif data.is_a?(Hash)
        known_keys = %w[
          sugestoes_de_conteudo
          sugestoes_conteudo
          sugestoes
          ideias_de_conteudo
          ideias_conteudo
          ideias
          content_suggestions
          suggestions
          ideas
        ]
        key = known_keys.find { |k| data.key?(k) && data[k].is_a?(Array) }
        if key
          data[key]
        else
          data.values.find { |v| v.is_a?(Array) } || []
        end
      else
        []
      end
    end

    def format_item(item, index)
      return "#{index}. #{item}" unless item.is_a?(Hash)

      hash = item.transform_keys(&:to_s)

      title = hash["titulo"] || hash["title"] || hash["tema"] || hash["ideia"] || hash["idea"]
      description = hash["descricao"] || hash["description"] || hash["detalhes"] || hash["summary"] || hash["conteudo"]
      formats = hash["formatos_sugeridos"] || hash["formatos"] || hash["formato"] || hash["formats"] || hash["format"]

      title_clean = title.to_s.strip
      desc_clean = description.to_s.strip

      parts = []
      if !title_clean.empty? && !desc_clean.empty?
        parts << "**#{title_clean}** — #{desc_clean}"
      elsif !title_clean.empty?
        parts << "**#{title_clean}**"
      elsif !desc_clean.empty?
        parts << desc_clean
      end

      formats_str = case formats
                    when Array
                      formats.map(&:to_s).map(&:strip).reject(&:empty?).join(", ")
                    when String
                      formats.strip
                    else
                      nil
                    end

      if formats_str && !formats_str.empty?
        if parts.any?
          last = parts.last
          if last.end_with?(".", "!", "?")
            parts[-1] = "#{last} Formatos: #{formats_str}"
          else
            parts[-1] = "#{last}. Formatos: #{formats_str}"
          end
        else
          parts << "Formatos: #{formats_str}"
        end
      end

      if parts.empty?
        "#{index}. #{item.inspect}"
      else
        "#{index}. #{parts.join(' ')}"
      end
    end
  end
end
