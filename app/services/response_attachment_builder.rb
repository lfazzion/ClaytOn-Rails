# frozen_string_literal: true

require "json"
require "set"

class ResponseAttachmentBuilder
  Result = Struct.new(:caption, :caption_resto, :filename, :content, :kind, keyword_init: true)

  DEFAULT_CODE_LINES = 25
  DEFAULT_PROSE_CHARS = 4000
  MAX_CAPTION_LENGTH = 2000
  PROSE_PREVIEW_LIMIT = 200

  LANGUAGE_EXTENSION_MAP = {
    "python" => "py",
    "ruby" => "rb",
    "javascript" => "js",
    "js" => "js",
    "typescript" => "ts",
    "tsx" => "tsx",
    "bash" => "sh",
    "sh" => "sh",
    "shell" => "sh",
    "sql" => "sql",
    "json" => "json",
    "yaml" => "yaml",
    "yml" => "yaml",
    "markdown" => "md",
    "md" => "md",
    "html" => "html",
    "css" => "css",
    "c" => "c",
    "cpp" => "cpp",
    "c++" => "cpp",
    "java" => "java",
    "go" => "go",
    "rust" => "rs",
    "php" => "php",
    "swift" => "swift",
    "kotlin" => "kt",
    "dockerfile" => "txt"
  }.freeze

  class << self
    def build(texto)
      return nil if texto.blank?

      blocks = extract_code_blocks(texto)
      # M1 (revisão Opus): clamp — chave presente e vazia vira 0, e 0 faria
      # QUALQUER bloco/prosa virar arquivo (mesma regra do attachment_processor).
      min_code_lines = [ENV.fetch("DISCORD_OUTPUT_CODE_LINES", DEFAULT_CODE_LINES).to_i, 1].max

      grandes = blocks.select { |b| b[:line_count] > min_code_lines }

      if grandes.any?
        return build_code_attachment(texto, grandes)
      end

      min_prose_chars = [ENV.fetch("DISCORD_OUTPUT_PROSE_CHARS", DEFAULT_PROSE_CHARS).to_i, 1].max

      if texto.length > min_prose_chars
        return build_prose_attachment(texto)
      end

      nil
    end

    private

    def extract_code_blocks(texto)
      lines = texto.split(/\r?\n/, -1)
      blocks = []
      in_fence = false
      current_tick_len = 0
      current_lang = nil
      current_title = nil
      current_body_lines = []
      start_line_idx = nil

      lines.each_with_index do |line, idx|
        if line =~ /^\s*```+/
          if in_fence
            # Ressalva 1 (2ª rodada): fechamento CommonMark — só fecha uma
            # linha com >= crases que a abertura e sem info-string. Sem isso,
            # ```markdown aninhado dentro de ````markdown fecharia o bloco
            # cedo e repartiria o conteúdo errado (a linha interna vira
            # corpo; a próxima linha de crases reabriria).
            ticks = line[/`+/].length
            if ticks >= current_tick_len && line.sub(/`+/, "").strip.empty?
              in_fence = false
              blocks << build_block(current_lang, current_title, current_body_lines, start_line_idx, idx)
            else
              current_body_lines << line
            end
          else
            in_fence = true
            current_tick_len = line[/`+/].length
            current_lang, current_title = parse_info_string(line)
            current_body_lines = []
            start_line_idx = idx
          end
        elsif in_fence
          current_body_lines << line
        end
      end

      # M2 (revisão Opus): fence NÃO fechado (resposta cortada por teto de
      # tokens no meio do bloco) ainda conta como bloco — antes sumia em
      # silêncio e a feature desligava sem aviso.
      if in_fence
        blocks << build_block(current_lang, current_title, current_body_lines, start_line_idx, lines.size - 1)
      end

      blocks
    end

    def build_block(lang, title, body_lines, start_line_idx, end_line_idx)
      {
        lang: lang,
        title: title,
        body_lines: body_lines,
        line_count: body_lines.size,
        start_line_idx: start_line_idx,
        end_line_idx: end_line_idx
      }
    end

    # Info-string folgada: lang = primeiro token ([A-Za-z0-9_+#.-]); title =
    # o valor de title= com aspas simples/duplas (ACEITANDO espaços dentro das
    # aspas) ou token sem aspas. Qualquer outro atributo (filename=, {1,3}) é
    # ignorado sem quebrar a abertura.
    def parse_info_string(line)
      rest = line.sub(/^\s*```+/, "").strip
      lang = rest[/\A[A-Za-z0-9_+#.-]+/].to_s
      rest = rest[lang.length..].to_s.strip
      title = nil
      if (m = rest.match(/title\s*=\s*"([^"]*)"|title\s*=\s*'([^']*)'|title\s*=\s*(\S+)/i))
        title = (m[1] || m[2] || m[3]).presence
      end
      [lang, title]
    end

    def build_code_attachment(texto, grandes)
      lines = texto.split(/\r?\n/, -1)

      # B2 (revisão Opus): o caption é só o texto FORA dos fences — nenhum
      # bloco grande fica de fora. O excedente (>2000) vira caption_resto e é
      # entregue como mensagens após o arquivo (nada se perde, como o
      # split_message de hoje).
      removed_idx = grandes.each_with_object(Set.new) do |b, set|
        (b[:start_line_idx]..b[:end_line_idx]).each { |i| set << i }
      end
      caption_raw = lines.each_with_index.filter_map { |l, i| l unless removed_idx.include?(i) }.join("\n").strip
      # Linhas em branco ao redor dos fences sobrariam como lacunas duplas —
      # colapsa 3+ quebras seguidas em 2 (parágrafo normal).
      caption_raw = caption_raw.gsub(/\n{3,}/, "\n\n")
      caption_raw = "Aqui esta o arquivo." if caption_raw.empty?
      caption, caption_resto = split_caption(caption_raw)

      # B2: TODOS os blocos grandes vão para o arquivo (não só o maior),
      # separados por um marcador neutro com a linguagem.
      parts = []
      grandes.each_with_index do |b, i|
        parts << "--- #{b[:lang].presence || 'bloco'} ---" if i.positive?
        parts << b[:body_lines].join("\n")
      end
      content = parts.join("\n\n")

      primeiro = grandes.first
      # Ressalva 3 (2ª rodada): linguagens DIVERGENTES nos blocos (python+sql)
      # geram codigo.txt — nada se perde, mas o realce/ícone não mente.
      langs = grandes.map { |b| b[:lang].to_s.strip.downcase }.reject(&:empty?).uniq
      ext = if langs.size > 1
              "txt"
            else
              resolve_extension(primeiro[:lang], primeiro[:body_lines].join("\n"))
            end
      titulo = grandes.filter_map { |b| b[:title] }.first
      fallback_fn = "codigo.#{ext}"
      filename = sanitize_filename(titulo, fallback_fn)

      # m6 (revisão Opus): title="notas" sem extensão ganha a extensão real.
      filename = "#{filename}.#{ext}" if File.extname(filename).empty?

      Result.new(caption: caption, caption_resto: caption_resto, filename: filename,
                 content: content, kind: :code)
    end

    def split_caption(raw)
      if raw.length <= MAX_CAPTION_LENGTH
        [raw, nil]
      else
        # Marcador explícito de corte — o usuário sabe que falta texto e o
        # resto é entregue à parte (caption_resto).
        [raw[0, MAX_CAPTION_LENGTH - 1] + "…", raw[(MAX_CAPTION_LENGTH - 1)..].to_s]
      end
    end

    def build_prose_attachment(texto)
      caption = if texto.length <= PROSE_PREVIEW_LIMIT
                  "📄 #{texto}"
                else
                  slice = texto[0, PROSE_PREVIEW_LIMIT]
                  last_space = slice.rindex(/\s/)
                  cut = last_space ? slice[0...last_space] : slice
                  "📄 #{cut.strip}..."
                end

      caption = caption[0, MAX_CAPTION_LENGTH]

      Result.new(
        caption: caption,
        filename: "resposta.md",
        content: texto,
        kind: :prose
      )
    end

    def resolve_extension(lang, content)
      normalized_lang = lang.to_s.strip.downcase
      return LANGUAGE_EXTENSION_MAP[normalized_lang] if LANGUAGE_EXTENSION_MAP.key?(normalized_lang)

      json_content?(content) ? "json" : "txt"
    end

    def json_content?(content)
      return false if content.blank?

      JSON.parse(content)
      true
    rescue JSON::ParserError
      false
    end

    def sanitize_filename(raw_title, fallback)
      return fallback if raw_title.blank?

      cleaned = raw_title.to_s.gsub(/[[:cntrl:]]/, "").delete(":")
      while cleaned.include?("..")
        cleaned.gsub!("..", "")
      end

      cleaned = cleaned.gsub(/[\/\\"'\[\]]/, "").gsub(/\s+/, " ").strip
      cleaned = cleaned[0, 40].strip

      cleaned.presence || fallback
    end
  end
end
