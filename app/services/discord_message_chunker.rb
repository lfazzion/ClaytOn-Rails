# frozen_string_literal: true

# Chunker único de mensagens do Discord (Achado 5, PR #36).
#
# Antes, Last30DaysTopicJob#chunk_text e WeeklyDigestJob#send_digest_message
# resolviam o mesmo problema (limite de 2000 chars do Discord, quebra por
# linha) em duas variantes inconsistentes — e as DUAS tinham o mesmo furo:
# uma linha isolada maior que o limite virava um chunk que ainda estourava
# o limite (URL longa, bloco de código, tabela).
#
# Módulo puro, sem dependência de Rails: recebe a mensagem e o limite e
# devolve um Array<String> pronto para o DiscordApiClient.send_message.
# O Zeitwerk carrega app/services — os jobs usam a constante sem
# require_relative.
module DiscordMessageChunker
  DEFAULT_LIMIT = 1900

  # Quebra `message` em chunks de no máximo `limit` caracteres.
  # Sempre devolve Array<String>; mensagem <= limit → [message].
  def self.chunk(message, limit: DEFAULT_LIMIT)
    return [message] if message.length <= limit

    chunks = []
    current_chunk = []
    current_length = 0

    message.split("\n").each do |line|
      # CORREÇÃO DO FURO: linha isolada maior que o limite (URL longa, bloco
      # de código, tabela) vira múltiplos chunks de `limit` chars cada. A
      # linha não contém "\n" (veio do split), então cortar por caracteres
      # nunca quebra no meio de uma quebra de linha.
      if line.length > limit
        chunks << current_chunk.join("\n") if current_chunk.any?
        current_chunk = []
        current_length = 0

        line.chars.each_slice(limit) do |slice|
          chunks << slice.join
        end
        next
      end

      line_len = line.length + 1
      if current_length + line_len > limit && current_chunk.any?
        chunks << current_chunk.join("\n")
        current_chunk = [line]
        current_length = line_len
      else
        current_chunk << line
        current_length += line_len
      end
    end

    chunks << current_chunk.join("\n") if current_chunk.any?
    chunks
  end
end