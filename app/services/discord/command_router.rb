# frozen_string_literal: true

module Discord
  # Única fonte de verdade dos comandos. O slash nativo e o prefixo "!" entram
  # os dois aqui e saem como o mesmo Command, então não existe caminho onde uma
  # das formas se comporta diferente da outra.
  class CommandRouter
    TEXT_PREFIX = "!"
    CONFIRM_WORD = "sim"

    # `sessions` e `resume` eram o MESMO símbolo, por pedido do dono. A paginação
    # quebrou isso: o número passaria a significar página num e conversa no outro,
    # e número que muda de sentido conforme o comando é armadilha — ainda mais com
    # um /delete irreversível lendo o mesmo número. O dono foi consultado sobre a
    # colisão e escolheu separar.
    ALIASES = {
      "new" => :new,
      "clear" => :new,
      "sessions" => :sessions,
      "resume" => :resume,
      "delete" => :delete,
      "help" => :help,
      "sentiment_target" => :sentiment_target,
      "sentiment_run" => :sentiment_run,
      "sentiment_status" => :sentiment_status,
      "sentiment" => :sentiment_status
    }.freeze

    SLASH_COMMANDS = [
      { name: "new", description: "Comeca uma conversa nova",
        takes_index: false, index_label: nil, takes_confirm: false },
      { name: "clear", description: "Comeca uma conversa nova (igual a /new)",
        takes_index: false, index_label: nil, takes_confirm: false },
      { name: "sessions", description: "Lista as conversas anteriores",
        takes_index: true, index_label: "Numero da pagina", takes_confirm: false },
      { name: "resume", description: "Retoma uma conversa anterior pelo numero",
        takes_index: true, index_label: "Numero da conversa", takes_confirm: false },
      { name: "delete", description: "Apaga uma conversa anterior pelo numero",
        takes_index: true, index_label: "Numero da conversa", takes_confirm: true },
      { name: "help", description: "Explica os comandos e como o chat funciona",
        takes_index: false, index_label: nil, takes_confirm: false },
      { name: "sentiment_target", description: "Cria ou atualiza alvo de analise de sentimento",
        takes_index: false, index_label: nil, takes_confirm: false },
      { name: "sentiment_run", description: "Executa analise de sentimento para um alvo",
        takes_index: true, index_label: "ID do alvo", takes_confirm: false },
      { name: "sentiment_status", description: "Consulta status da analise de sentimento",
        takes_index: true, index_label: "ID do alvo", takes_confirm: false }
    ].freeze

    Command = Struct.new(:name, :arg, :confirm, keyword_init: true)

    class << self
      def parse_text(content)
        text = content.to_s.strip
        return nil unless text.start_with?(TEXT_PREFIX)

        word, rest = text.delete_prefix(TEXT_PREFIX).split(/\s+/, 2)
        build(word, rest)
      end

      # `value` é String no caminho "!" e Integer no caminho slash; `confirm` é
      # nil no caminho "!" (a palavra vem dentro de `value`) e Boolean no slash.
      def build(word, value = nil, confirm = nil)
        name = ALIASES[word.to_s.strip.downcase]
        return nil unless name

        Command.new(name: name, arg: parse_index(value), confirm: parse_confirm(value, confirm))
      end

      # SEM clamp, de propósito, e é a exceção à regra 10 do CLAUDE.md. Clampar
      # aqui fazia "!resume 999" virar 10 e retomar a décima conversa em silêncio
      # — o usuário pedia uma e recebia outra achando que era a certa. Num /delete
      # o mesmo clamp apagaria a conversa errada, sem volta. Quem sabe o tamanho
      # real da lista (ChatSessionManager) é quem recusa, com o intervalo na tela.
      def parse_index(value)
        return value if value.is_a?(Integer)

        digits = value.to_s.strip[/\A\d+/]
        digits&.to_i
      end

      # Uma palavra só, exata, e SOZINHA no resto do texto (depois do índice).
      # Adivinhar sinônimo ("s", "yes", "ok") num comando irreversível é como se
      # apaga a coisa errada — e "sim" seguido de qualquer outra coisa ("sim
      # senhor") também não conta: não é a palavra sozinha, é só mais um jeito de
      # tentar burlar a confirmação exata.
      def parse_confirm(value, explicit)
        return explicit if [true, false].include?(explicit)
        return false unless value.is_a?(String)

        restante = value.strip.split(/\s+/).drop(1)
        restante.size == 1 && restante.first.downcase == CONFIRM_WORD
      end
    end
  end
end
