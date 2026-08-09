# frozen_string_literal: true

module Discord
  # Texto do /help. Muda conforme o canal, porque a regra de menção e a de
  # sessão compartilhada mudam com ele — e um /help que mente sobre isso é pior
  # que nenhum.
  class HelpText
    class << self
      def render(open_channel:)
        [cabecalho(open_channel), comandos, rodape(open_channel)].join("\n")
      end

      private

      def cabecalho(open_channel)
        if open_channel
          "**Como funciona aqui**\n" \
            "Neste canal eu respondo **sem precisar mencionar** — é só escrever.\n" \
            "A conversa é **uma só para todo mundo**: eu lembro do que qualquer pessoa " \
            "da sala disse.\n"
        else
          "**Como funciona aqui**\n" \
            "Neste canal, **me mencione** para eu responder a uma pergunta. Em mensagem " \
            "direta não precisa.\n" \
            "Os comandos abaixo são a exceção: eles não precisam que você me mencione, " \
            "em nenhum canal.\n" \
            "Sua conversa é **sua**: cada pessoa tem a própria.\n"
        end
      end

      # "em qualquer canal — não precisam que você me mencione" só virou verdade depois
      # de should_handle? deixar passar mensagem começando com "!" mesmo fora de DM e
      # canal aberto (DiscordBotService).
      #
      # /sessions e /resume já foram sinônimos. Deixaram de ser quando entrou a
      # paginação: o número passaria a significar página num e conversa no outro.
      def comandos
        "\n**Comandos** (funcionam com `/` ou com `!`, em qualquer canal — não precisam " \
          "que você me mencione)\n" \
          "`/new` ou `/clear` — começa uma conversa nova. A anterior fica guardada.\n" \
          "`/sessions` — lista as conversas anteriores, em páginas. " \
          "`/sessions 2` mostra a página seguinte.\n" \
          "`/resume <número>` — volta para uma conversa da lista. O número é o mesmo " \
          "que aparece nela, mesmo que esteja em outra página.\n" \
          "`/delete <número>` — apaga uma conversa. Mostra o que vai apagar e pede " \
          "confirmação; não alcança a conversa em andamento (dê `/new` antes).\n" \
          "`/help` — mostra esta ajuda.\n" \
          "`!new`, `!clear`, `!sessions`, `!resume`, `!delete` e `!help` fazem o mesmo. " \
          "A única diferença é como se confirma o apagar: por texto é " \
          "`!delete <número> sim`; pelo menu `/` é a opção **confirmar**.\n"
      end

      # Antes esta frase dizia que o que "você" escreveu era guardado "com as suas
      # palavras" — mas isso é só um pedido no prompt do resumidor, não uma garantia
      # mecânica do código. Removida para não prometer o que não é garantido.
      def rodape(open_channel)
        base = "\nEu lembro da conversa mesmo depois de reiniciar. Quando ela fica muito " \
               "longa, resumo as partes mais antigas para não perder o fio."

        return base unless open_channel

        "#{base}\n" \
          "Comece a mensagem com `#{SessionScope.mute_prefix}` para eu ignorar completamente " \
          "(nem entra no histórico).\n" \
          "Atenção: aqui `/new` e `/resume` valem para **todo mundo**, porque a conversa é da sala."
      end
    end
  end
end
