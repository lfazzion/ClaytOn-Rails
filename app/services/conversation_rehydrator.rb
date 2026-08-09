# frozen_string_literal: true

# Reconstrói o RubyLLM::Chat de uma conversa: resumo (quando existe) como
# instrução anexa, e a cauda viva como mensagens de verdade.
#
# Tool calls não voltam. Reidratar `tool_calls` sem os resultados originais
# quebra o protocolo do provedor — por isso só user/assistant são persistidos.
class ConversationRehydrator
  DEFAULT_REHYDRATE = 30
  MAX_REHYDRATE = 100

  class << self
    def rehydrate_limit
      configured = ENV["DISCORD_REHYDRATE_MESSAGES"].to_i
      return DEFAULT_REHYDRATE unless configured.positive?

      [[configured, 1].max, MAX_REHYDRATE].min
    end

    def messages_for(conversation)
      ConversationCompactor.live_messages(conversation).last(rehydrate_limit)
    end

    def context_block(conversation)
      partes = []
      partes << Llm::PromptLoader.partial("multi_user") if conversation.shared
      if conversation.summary.present?
        partes << Llm::PromptLoader.partial("compaction_notice")
        partes << conversation.summary
      end
      return nil if partes.empty?

      partes.join("\n\n")
    end

    def apply!(chat, conversation)
      bloco = context_block(conversation)
      chat.with_instructions(bloco, append: true) if bloco.present?

      messages_for(conversation).each do |message|
        chat.add_message(role: message.role.to_sym, content: message.llm_content)
      end

      chat
    end
  end
end
