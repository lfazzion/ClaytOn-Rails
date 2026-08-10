# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

class AttachmentProcessor
  ALLOWED_EXTENSIONS = %w[.txt .md .pdf].freeze
  DEFAULT_MAX_BYTES = 10_485_760
  DEFAULT_MAX_CHARS = 30_000

  Result = Struct.new(:success, :content, :error_message, :truncated, :truncated_reason, :filename, keyword_init: true)

  class << self
    def process(attachment, user_text = "")
      filename = attachment.respond_to?(:filename) ? attachment.filename.to_s : ""
      ext = File.extname(filename).downcase

      unless ALLOWED_EXTENSIONS.include?(ext)
        return Result.new(
          success: false,
          error_message: "Formato de arquivo não suportado. Envie apenas arquivos .txt, .md ou .pdf."
        )
      end

      max_bytes = ENV.fetch("DISCORD_ATTACHMENT_MAX_BYTES", DEFAULT_MAX_BYTES).to_i
      file_size = attachment.respond_to?(:size) ? attachment.size.to_i : 0

      if file_size > max_bytes
        return Result.new(
          success: false,
          error_message: "Arquivo muito grande. O tamanho máximo permitido é 10MB."
        )
      end

      url = attachment.respond_to?(:url) ? attachment.url.to_s : ""
      temp_file, download_err = download_attachment(url, max_bytes)
      return Result.new(success: false, error_message: download_err) if download_err

      begin
        file_bytes = temp_file.read
        if ext == ".pdf"
          unless file_bytes.start_with?("%PDF-")
            return Result.new(
              success: false,
              error_message: "Arquivo não é um PDF válido."
            )
          end

          pdf_res = ScrapingServices::SidecarClient.extract_pdf(bytes: file_bytes)
          if pdf_res.nil? || pdf_res["error"]
            msg = pdf_error_message(pdf_res)
            return Result.new(success: false, error_message: msg)
          end

          extracted_text = pdf_res["text"].to_s.strip
          if extracted_text.empty?
            return Result.new(
              success: false,
              error_message: "Não consegui extrair texto deste PDF."
            )
          end
        else
          content_str = file_bytes.force_encoding("UTF-8")
          unless content_str.valid_encoding?
            return Result.new(
              success: false,
              error_message: "Arquivo de texto inválido."
            )
          end

          extracted_text = content_str.strip
          if extracted_text.empty?
            return Result.new(
              success: false,
              error_message: "Não consegui extrair texto deste arquivo."
            )
          end
        end

        max_chars = [ENV.fetch("DISCORD_ATTACHMENT_MAX_CHARS", DEFAULT_MAX_CHARS).to_i, 1].max
        sanitized_name = sanitize_filename(filename)

        # B3 (revisão Opus): o corte por páginas acontece no sidecar e é
        # sinalizado em pdf_res["truncated"] — o bot não pode afirmar que leu o
        # documento inteiro quando o sidecar só leu as primeiras páginas.
        truncated_by_pages = (ext == ".pdf" && pdf_res["truncated"] == true)
        truncated_by_chars = extracted_text.length > max_chars
        is_truncated = truncated_by_chars || truncated_by_pages
        truncated_reason = truncated_by_chars ? :chars : (truncated_by_pages ? :pages : nil)

        # B1 (revisão Opus): as tags do frame são emitíveis pelo conteúdo do
        # arquivo — um "[/ARQUIVO]" dentro do texto fecharia o frame cedo e
        # reabriria personificação <autor>: (o vetor que ChatMessage fecha).
        # Neutraliza QUALQUER tentativa de emitir as tags no CORPO do arquivo,
        # em qualquer caixa — antes das notas de truncamento, para não tocá-las.
        safe_body = extracted_text.gsub(/\[\s*\/?\s*ARQUIVO\s*\]?/i) { |m| m.tr("[]", "()") }

        body_text = if truncated_by_chars
                      safe_body[0, max_chars] + "\n[truncado em #{max_chars} chars]"
                    elsif truncated_by_pages
                      safe_body + "\n[arquivo longo demais — o início foi lido]"
                    else
                      safe_body
                    end

        frame = <<~FRAME.strip
          [ARQUIVO nome="#{sanitized_name}"]
          #{body_text}
          [/ARQUIVO]
        FRAME

        user_prompt = user_text.to_s.strip
        full_content = user_prompt.present? ? "#{user_prompt}\n\n#{frame}" : frame

        Result.new(
          success: true,
          content: full_content,
          truncated: is_truncated,
          truncated_reason: truncated_reason,
          filename: sanitized_name
        )
      ensure
        if temp_file
          temp_file.close
          temp_file.unlink rescue nil
        end
      end
    end

    def sanitize_filename(raw_name)
      sanitized = ChatMessage.new(discord_username: raw_name.to_s).discord_username
      sanitized = "arquivo" if sanitized.blank? || sanitized == ChatMessage::DISPLAY_NAME_FALLBACK
      cleaned = sanitized.tr('"', "'").delete("[").delete("]").strip
      cleaned.presence || "arquivo"
    end

    # N2 (revisão Opus): mapear erro por error_kind simbólico vindo do client
    # (que por sua vez vem do sidecar), nunca por substring de mensagem
    # localizada — reescrever uma frase não pode degradar o mapeamento em
    # silêncio. Contrato do /extract-pdf:
    #   unavailable — infra (conexão/timeout/5xx/401) -> transiente, "agora"
    #   limit       — 413 acima do teto -> "arquivo muito grande"
    #   parse       — não conseguiu extrair texto -> "deste PDF"
    #   (fallback sem error_kind)         -> transiente genérico (não vaza)
    def pdf_error_message(pdf_res)
      case pdf_res.is_a?(Hash) ? pdf_res["error_kind"].to_s : nil
      when "limit"
        "Arquivo muito grande. O tamanho máximo permitido é 10MB."
      when "parse"
        "Não consegui extrair texto deste PDF."
      else
        "Não consegui ler o PDF agora."
      end
    end

    private

    def download_attachment(url, max_bytes, redirect_limit = 2)
      return [nil, "Número de redirecionamentos excedido."] if redirect_limit < 0

      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        return [nil, "URL de anexo inválida."]
      end

      allowed_domains = %w[cdn.discordapp.com media.discordapp.com discordapp.net discordapp.com]
      host = uri.host.to_s.downcase
      unless allowed_domains.any? { |d| host == d || host.end_with?(".#{d}") }
        return [nil, "Origem do anexo não permitida."]
      end

      temp_file = Tempfile.new(["discord_att", ".tmp"], binmode: true)
      downloaded_bytes = 0

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 20

      request = Net::HTTP::Get.new(uri.request_uri)

      http.request(request) do |response|
        if response.is_a?(Net::HTTPRedirection)
          temp_file.close
          temp_file.unlink rescue nil
          new_location = response["location"]
          return download_attachment(new_location, max_bytes, redirect_limit - 1)
        end

        unless response.is_a?(Net::HTTPSuccess)
          temp_file.close
          temp_file.unlink rescue nil
          return [nil, "Não consegui baixar o arquivo."]
        end

        response.read_body do |chunk|
          downloaded_bytes += chunk.bytesize
          if downloaded_bytes > max_bytes
            temp_file.close
            temp_file.unlink rescue nil
            return [nil, "Arquivo muito grande. O tamanho máximo permitido é 10MB."]
          end
          temp_file.write(chunk)
        end
      end

      temp_file.rewind
      [temp_file, nil]
    rescue StandardError => e
      temp_file&.close
      temp_file&.unlink rescue nil
      Rails.logger.error "[AttachmentProcessor] Erro ao baixar anexo: #{e.class} - #{e.message}"
      [nil, "Não consegui baixar o arquivo."]
    end
  end
end
