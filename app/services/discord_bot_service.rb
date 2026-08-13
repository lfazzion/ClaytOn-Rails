# frozen_string_literal: true

require "discordrb"
require "concurrent"
require "tempfile"

class DiscordBotService
  MAX_DISCORD_MESSAGE = 2000

  # Filtro do handler de mensagem: VAZIO de propósito, e não é descuido.
  #
  # O `content: /./` que estava aqui nunca funcionou. O discordrb casa `content:`
  # exigindo que o trecho casado seja a mensagem INTEIRA
  # (`events/message.rb:256-262`: `match ? (e == match[0]) : false`), então
  # `/./` — que casa um caractere — só dispara para mensagem de exatamente 1
  # caractere. Na prática o handler estava morto: DM nunca passou por ele, e no
  # canal aberto o silêncio era total, porque a guarda do bot.mention sai cedo
  # justamente quando o bot.message deveria atender.
  #
  # Sem filtro, `matches_all(nil, ...)` devolve true e TODA mensagem chega ao
  # handler — que é o que deve ser: quem filtra é `should_handle?`. Não há risco
  # de laço: `bot.rb:1344` descarta a mensagem do próprio bot antes de levantar
  # o evento (`parse_self` é false por padrão), e `bot_author?` cobre os demais.
  MESSAGE_HANDLER_FILTER = {}.freeze

  class << self
    def start
      $stdout.sync = true
      $stderr.sync = true
      @running = Concurrent::AtomicBoolean.new(true)

      cleanup_mutex = Mutex.new
      cleanup_cv = ConditionVariable.new
      cleanup_thread = nil

      # discordrb 3.7.2 não define :message_content (Discord intent 15 = 1<<15 = 32768)
      # na constant INTENTS. Bitmask: GUILDS=1 | GUILD_MESSAGES=512 | DM=4096 | MSG_CONTENT=32768
      message_content = 1 << 15
      intents_bitmask = 1 | 512 | 4096 | message_content

      bot = Discordrb::Bot.new(
        token: ENV["DISCORD_BOT_TOKEN"],
        intents: intents_bitmask
      )

      bot.message(MESSAGE_HANDLER_FILTER) do |event|
        next unless should_handle?(event)

        handle_message(event)
      end

      bot.ready do |event|
        Rails.logger.info "[DiscordBotService] Gateway pronto — sessão estabelecida " \
                          "(bot: #{event.bot.profile.username rescue '?'})"
      end

      # bot.mention dispara em paralelo ao bot.message sempre que a mensagem também
      # bate em should_handle? (DM, canal aberto, ou comando "!"). Nesses casos
      # handle_message já respondeu — reprocessar aqui duplicaria a resposta. Isso
      # importa especialmente em DM: responder a uma mensagem no Discord menciona o
      # autor por padrão, então sem esta guarda cobrindo DM (e não só canal aberto)
      # toda resposta a uma DM do bot gerava duas respostas.
      bot.mention do |event|
        handle_mention(event)
      end

      register_commands(bot)
      attach_command_handlers(bot)

      cleanup_thread = Thread.new do
        while @running.true?
          cleanup_mutex.synchronize do
            break unless @running.true?
            cleanup_cv.wait(cleanup_mutex, 300)
          end
          break unless @running.true?
          ChatSessionManager.cleanup_expired
        end
      end

      Signal.trap("TERM") do
        Rails.logger.info "[DiscordBotService] Recebido TERM, parando..."
        @running.make_false
        bot.stop
      end

      Signal.trap("INT") do
        Rails.logger.info "[DiscordBotService] Recebido INT, parando..."
        @running.make_false
        bot.stop
      end

      Rails.logger.info "[DiscordBotService] Iniciando bot..."
      bot.run
    ensure
      @running&.make_false
      if cleanup_mutex
        cleanup_mutex.synchronize do
          cleanup_cv&.broadcast
        end
      end
      cleanup_thread&.join(5)
    end

    def should_handle?(event)
      event.channel.private? ||
        Discord::SessionScope.open_channel?(event.channel.id.to_s) ||
        text_command?(event)
    end

    # Ver o comentário acima do bot.mention: a guarda é literalmente "pule o que o
    # bot.message já atende".
    def handle_mention(event)
      return if should_handle?(event)

      handle_message(event)
    end

    # Registro dos slash commands. Falha aqui nunca derruba o bot: o prefixo "!"
    # continua atendendo tudo.
    def register_commands(bot)
      guild_id = ENV["DISCORD_COMMAND_GUILD_ID"].presence
      Discord::CommandRouter::SLASH_COMMANDS.each do |command|
        bot.register_application_command(command[:name], command[:description],
                                         server_id: guild_id) do |options|
          options.integer("numero", command[:index_label], required: false) if command[:takes_index]
          options.boolean("confirmar", "Marque para confirmar a exclusao", required: false) if
            command[:takes_confirm]
        end
      end
      Rails.logger.info "[DiscordBotService] Slash commands registrados " \
                        "(#{guild_id ? "guild #{guild_id}" : 'global'})"
    rescue StandardError => e
      Rails.logger.warn "[DiscordBotService] Registro de slash falhou (#{e.class.name}: " \
                        "#{e.message}); o prefixo ! continua funcionando"
    end

    def attach_command_handlers(bot)
      Discord::CommandRouter::SLASH_COMMANDS.each do |definition|
        bot.application_command(definition[:name].to_sym) do |event|
          handle_slash_command(event, definition)
        end
      end
    end

    # `defer` reconhece a interaction com uma chamada HTTP simples, sem tocar no mutex
    # de escopo — o resto do trabalho (que pode disputar esse mesmo lock com um `ask`
    # em andamento, e por isso passar dos 3s) acontece depois, fora do relógio do
    # Discord. Por isso a resposta final vai por respond_deferred (edit_response +
    # follow-up), não por `event.respond`: depois de deferida a interaction já foi
    # reconhecida e não aceita um segundo "respond" inicial.
    def handle_slash_command(event, definition)
      event.defer(ephemeral: false)
      command = Discord::CommandRouter.build(definition[:name], event.options["numero"],
                                             event.options["confirmar"])
      scope = Discord::SessionScope.for(user_id: event.user.id.to_s,
                                        channel_id: event.channel.id.to_s)
      respond_deferred(event, run_command(command, scope))
    rescue StandardError => e
      Rails.logger.error "[DiscordBotService] Slash /#{definition[:name]} falhou: #{e.message}"
      respond_deferred(event, "⚠️ Erro ao processar o comando.")
    end

    def handle_message(event)
      return if bot_author?(event)

      user_id = event.user.id.to_s
      channel_id = event.channel.id.to_s
      username = display_name(event)
      scope = Discord::SessionScope.for(user_id: user_id, channel_id: channel_id)
      content = clean_content(event.message.content)

      if scope.shared && Discord::SessionScope.muted?(content)
        Rails.logger.debug "[DiscordBotService] Mensagem silenciada por prefixo, ignorando"
        return
      end

      attachments = event.message.respond_to?(:attachments) ? Array(event.message.attachments) : []

      # B4 (revisão Opus): o gate é sobre anexos SUPORTADOS, não sobre qualquer
      # anexo. Um print.png + pergunta não pode virar "Formato não suportado"
      # e descartar a pergunta — antes do PR o anexo era ignorado e a pergunta
      # respondida. Anexo não-suportado cai no fluxo de texto normal.
      suportados = attachments.select do |a|
        nome = a.respond_to?(:filename) ? a.filename.to_s : ""
        AttachmentProcessor::ALLOWED_EXTENSIONS.include?(File.extname(nome).downcase)
      end

      if suportados.size > 1
        event.respond("Envie apenas um arquivo por mensagem.")
        return
      end

      truncated = false
      truncated_reason = nil

      if suportados.size == 1
        # N5 (revisão Opus): o caminho de anexo não logava recebimento nenhum.
        anexo = suportados.first
        Rails.logger.info "[DiscordBotService] Anexo recebido (user: #{user_id}, " \
                          "channel: #{channel_id}, filename: " \
                          "#{anexo.respond_to?(:filename) ? anexo.filename : '?'}, " \
                          "size: #{anexo.respond_to?(:size) ? anexo.size : '?'})"

        # #4 (revisão Opus): qualquer falha inesperada do processamento termina
        # em resposta educada (ex.: File.extname com NUL no nome levanta
        # ArgumentError), nunca deixa o usuário no vácuo.
        begin
          res = AttachmentProcessor.process(anexo, content)
        rescue StandardError => e
          Rails.logger.error "[DiscordBotService] Falha inesperada ao processar anexo: " \
                             "#{e.class.name} - #{e.message}"
          event.respond("Não consegui processar o arquivo.")
          return
        end

        unless res.success
          event.respond(res.error_message)
          return
        end

        content = res.content
        truncated = res.truncated
        truncated_reason = res.truncated_reason
      else
        Rails.logger.info "[DiscordBotService] Mensagem recebida (user: #{user_id}, " \
                          "channel: #{channel_id}, #{content.length} chars)"

        if content.empty?
          Rails.logger.info "[DiscordBotService] Content vazio após limpeza, ignorando"
          return
        end

        command = Discord::CommandRouter.parse_text(content)
        return respond_in_chunks(event, run_command(command, scope)) if command
      end

      answer(event, scope, content, user_id, username, truncated: truncated,
             truncated_reason: truncated_reason)
    rescue StandardError => e
      # #4 (2ª rodada de revisão): rede final do handle_message. O filtro de
      # suportados (File.extname acima) roda FORA do begin do process — um
      # filename com NUL ou bytes UTF-8 inválidos levanta ArgumentError antes
      # de qualquer rescue interno. Sem isto, o usuário fica no vácuo.
      Rails.logger.error "[DiscordBotService] Falha inesperada em handle_message: " \
                         "#{e.class.name} - #{e.message}"
      event.respond("⚠️ Erro ao processar. Tente novamente.") rescue nil
    end

    def run_command(command, scope)
      case command.name
      when :new then reset_response(scope)
      when :help then Discord::HelpText.render(open_channel: scope.shared)
      when :sessions then sessions_response(scope, command.arg)
      when :resume then resume_response(scope, command.arg)
      when :delete then delete_response(scope, command.arg, command.confirm)
      end
    rescue StandardError => e
      Rails.logger.error "[DiscordBotService] Comando #{command.name} falhou: #{e.message}"
      "⚠️ Erro ao processar o comando."
    end

    private

    def answer(event, scope, content, user_id, username, truncated: false, truncated_reason: nil)
      typing_running = Concurrent::AtomicBoolean.new(true)
      typing_thread = Thread.new do
        while typing_running.true?
          event.channel.start_typing
          sleep 4
        end
      end

      begin
        texto = ChatSessionManager.ask(scope: scope, content: content, user_id: user_id,
                                       username: username)
        texto = truncation_notice(texto, truncated_reason) if truncated
        attachment = ResponseAttachmentBuilder.build(texto)

        if attachment
          # M3 (revisão Opus): no caminho de prosa o aviso de truncamento
          # ficaria enterrado dentro do .md — vai para o caption, visível.
          if truncated && attachment.kind == :prose
            attachment.caption = "#{truncation_notice('', truncated_reason).strip} — #{attachment.caption}"
          end
          send_attachment_with_fallback(event, texto, attachment)
        else
          respond_in_chunks(event, texto)
        end
      rescue StandardError => e
        Rails.logger.error "[DiscordBotService] Erro: #{e.class.name} - #{e.message}"
        event.respond("⚠️ Erro ao processar. Tente novamente.")
      ensure
        typing_running.make_false
        typing_thread&.join(1)
      end
    end

    def send_attachment_with_fallback(event, texto, attachment)
      tempfile = Tempfile.new(["discord_att", File.extname(attachment.filename)])
      tempfile.binmode
      tempfile.write(attachment.content)
      tempfile.rewind

      begin
        event.channel.send_file(tempfile, caption: attachment.caption, filename: attachment.filename)
      rescue StandardError => e
        Rails.logger.error "[DiscordBotService] Erro ao enviar anexo (#{e.class.name}: #{e.message}), caindo para chunks"
        respond_in_chunks(event, texto)
        return
      end

      # B2 (revisão Opus): o excedente do caption (>2000) nunca se perde — é
      # entregue como mensagens após o arquivo, como o split_message faria.
      respond_in_chunks(event, attachment.caption_resto) if attachment.caption_resto.present?
    ensure
      if tempfile
        tempfile.close
        tempfile.unlink rescue nil
      end
    end

    # B3 (revisão Opus): o aviso de truncamento não pode afirmar um número de
    # caracteres quando o corte foi por PÁGINAS no sidecar — o número estaria
    # errado. Honesto por motivo: chars, páginas, ou genérico.
    def truncation_notice(texto, truncated_reason)
      aviso = case truncated_reason
              when :pages then "⚠️ *(O arquivo é longo demais e foi lido parcialmente.)*"
              when :chars
                max_chars = ENV.fetch("DISCORD_ATTACHMENT_MAX_CHARS", AttachmentProcessor::DEFAULT_MAX_CHARS).to_i
                "⚠️ *(O arquivo foi truncado em #{max_chars} caracteres.)*"
              else
                "⚠️ *(O arquivo foi lido parcialmente.)*"
              end
      "#{texto}\n\n#{aviso}"
    end

    def reset_response(scope)
      ChatSessionManager.reset!(scope)
      escopo = scope.shared ? " Como este canal é compartilhado, ela vale para todo mundo." : ""
      # Esta frase dizia "use /sessions para voltar a ela" e ficou mentirosa no
      # instante em que /sessions e /resume deixaram de ser sinônimos: /sessions 2
      # passou a significar PÁGINA 2. Seguir a instrução antiga reproduzia
      # exatamente a confusão que a separação existe para matar.
      "🆕 Nova conversa iniciada.#{escopo} A anterior ficou guardada — " \
        "`/sessions` mostra a lista e `/resume <número>` volta para ela."
    end

    # O argumento aqui é PÁGINA, nunca conversa. Em /resume e /delete o mesmo
    # número significa conversa — foi por isso que os comandos foram separados.
    def sessions_response(scope, numero)
      pagina = ChatSessionManager.page(scope, numero || 1)
      return pagina_inexistente(scope) if pagina.nil?
      return "Nenhuma conversa por aqui ainda. É só começar a falar." if pagina.total.zero?

      cabecalho = "**Conversas anteriores** (página #{pagina.number} de #{pagina.total_pages}, " \
                  "#{pagina.total} no total)"
      proxima = pagina.number < pagina.total_pages ? ", `/sessions #{pagina.number + 1}` para a próxima página" : ""
      "#{cabecalho}\n#{linhas_da_pagina(pagina)}\n\n" \
        "Use `/resume <número>` para continuar, `/delete <número>` para apagar#{proxima}."
    end

    def pagina_inexistente(scope)
      # `sessions_total` é COUNT barato; não reexecuta a listagem inteira só
      # para saber quantas páginas existem (o erro já veio de uma `page` que
      # rodou `sessions`).
      total_paginas = [(ChatSessionManager.sessions_total(scope).to_f / ChatSessionManager.page_size).ceil, 1].max
      plural = total_paginas == 1 ? "Só existe 1 página." : "Existem #{total_paginas} páginas."
      "Essa página não existe. #{plural}"
    end

    # A marca "(em andamento)" existe para o usuário entender por que o /delete
    # recusa justamente aquela linha.
    def linhas_da_pagina(pagina)
      pagina.conversations.each_with_index.map do |conversation, i|
        titulo = conversation.title.presence || "(sem título)"
        marca = conversation.active ? " *(em andamento)*" : ""
        "**#{pagina.first_index + i}.** #{titulo}#{marca} — " \
          "#{time_ago(conversation.last_active_at)}, #{conversation.msg_count} mensagens"
      end.join("\n")
    end

    # resume! devolve três coisas, não duas: `nil` quando o escopo não tem
    # NENHUMA conversa; `:fora_da_faixa` quando existem conversas mas o índice
    # não resolve; ou a Conversation retomada. Os dois primeiros parecem "não
    # encontrei", mas só o segundo sabe o tamanho real da lista para mostrar.
    def resume_response(scope, index)
      return sessions_response(scope, 1) if index.nil?

      resultado = ChatSessionManager.resume!(scope, index)
      case resultado
      when :fora_da_faixa
        # `sessions_total` é COUNT barato; resume! já rodou a listagem inteira
        # para achar o alvo — não reexecuta `sessions` só para o tamanho.
        total = ChatSessionManager.sessions_total(scope)
        "Não existe conversa #{index}. A lista vai até #{total}."
      when nil
        "Não encontrei nenhuma conversa por aqui ainda. É só começar a falar."
      else
        "▶️ Voltamos para: **#{resultado.title.presence || '(sem título)'}**. Pode continuar de onde parou."
      end
    end

    # Duas etapas de propósito: a primeira chamada só mostra o que será perdido.
    # A checagem aqui é de leitura; destroy! revalida sob o lock do escopo.
    def delete_response(scope, index, confirm)
      return sessions_response(scope, 1) if index.nil?

      lista = ChatSessionManager.sessions(scope)
      return "Nenhuma conversa para apagar por aqui." if lista.empty?

      # Mesmo teto do at_index do ChatSessionManager, e pelo mesmo motivo: sem ele,
      # `lista[bignum]` levanta RangeError e o usuário recebe "⚠️ Erro ao processar"
      # em vez de "não existe conversa N".
      posicao = index.to_i
      alvo = posicao.positive? && posicao <= lista.size ? lista[posicao - 1] : nil
      return "Não existe conversa #{index}. A lista vai até #{lista.size}." if alvo.nil?
      return conversa_em_andamento(index) if alvo.active
      return previa_de_exclusao(scope, alvo, index) unless confirm

      exclusao_concluida(scope, ChatSessionManager.destroy!(scope, index), index)
    end

    def conversa_em_andamento(index)
      "A ##{index} é a conversa em andamento. Dê `/new` primeiro para encerrá-la, " \
        "e então ela pode ser apagada."
    end

    def previa_de_exclusao(scope, alvo, index)
      titulo = alvo.title.presence || "(sem título)"
      sala = scope.shared ? " Esta conversa é da sala inteira." : ""
      "Apagar **#{titulo}**? #{alvo.msg_count} mensagens, última atividade " \
        "#{time_ago(alvo.last_active_at)}.#{sala}\n" \
        "Isso não tem volta. Confirme com `!delete #{index} sim` — ou, pelo menu `/`, " \
        "repita `/delete` com o número #{index} e marque a opção **confirmar**."
    end

    # O resultado nomeia o que foi apagado de propósito: sem memória do que foi
    # oferecido na confirmação (decisão do dono), se a ordem da lista mudou entre
    # ver e confirmar, é aqui que o usuário descobre.
    def exclusao_concluida(scope, resultado, index)
      case resultado
      when :lista_vazia then "Nenhuma conversa para apagar por aqui."
      when :fora_da_faixa then "Não existe conversa #{index}. Use `/sessions` para ver a lista."
      when :em_andamento then conversa_em_andamento(index)
      else
        sala = scope.shared ? " (conversa da sala)" : ""
        "🗑️ Apagada: **#{resultado.title.presence || '(sem título)'}** " \
          "(#{resultado.message_count} mensagens)#{sala}"
      end
    end

    # Formatado à mão em português: o projeto não tem locale pt-BR (sem
    # config/locales/, sem rails-i18n no Gemfile), então time_ago_in_words devolvia
    # inglês cru ("about 3 hours") no meio de uma frase em português.
    def time_ago(timestamp)
      return "há pouco" if timestamp.blank?

      segundos = (Time.current - timestamp).to_i
      minutos = segundos / 60
      horas = minutos / 60
      dias = horas / 24

      return "agora há pouco" if minutos < 1
      return "há #{minutos} #{minutos == 1 ? 'minuto' : 'minutos'}" if minutos < 60
      return "há #{horas} #{horas == 1 ? 'hora' : 'horas'}" if horas < 24

      "há #{dias} #{dias == 1 ? 'dia' : 'dias'}"
    rescue StandardError
      "há pouco"
    end

    def bot_author?(event)
      event.user.respond_to?(:bot_account?) && event.user.bot_account?
    end

    # Precisa ser um comando QUE EXISTE, não só o prefixo. Testar só o `!` fazia
    # o bot atender `!play`, `!skip`, `!ban` de qualquer outro bot do servidor —
    # e `!!!` de ênfase — respondendo com texto de LLM em canal onde ninguém o
    # chamou. parse_text já devolve nil para palavra fora de ALIASES.
    def text_command?(event)
      Discord::CommandRouter.parse_text(event.message.content).present?
    end

    def display_name(event)
      user = event.user
      nome = user.respond_to?(:display_name) ? user.display_name : nil
      nome.presence || (user.respond_to?(:username) ? user.username.to_s : "usuario")
    end

    def clean_content(raw)
      raw.to_s
         .gsub(/<@!?\d+>/, "")   # Remove menções <@123> ou <@!123>
         .gsub(/\s+/, " ")       # Colapsa espaços extras
         .strip
    end

    def respond_in_chunks(event, response)
      chunks_for(response).each { |chunk| event.respond(chunk) }
    end

    # Caminho slash: a interaction já foi deferida em attach_command_handlers, então
    # `event.respond` não serve mais (só aceita um "respond" inicial). O primeiro
    # pedaço vira edição da resposta deferida; o resto vai por follow-up
    # (send_message), que é a forma real do gem de mandar mais de uma mensagem numa
    # interaction — sem isso, /sessions com muita conversa estourava os 2000 chars.
    def respond_deferred(event, response)
      chunks = chunks_for(response)
      event.edit_response(content: chunks.first)
      chunks.drop(1).each { |chunk| event.send_message(content: chunk, ephemeral: false) }
    end

    def chunks_for(response)
      text = response.respond_to?(:content) ? response.content : response.to_s
      text.length > MAX_DISCORD_MESSAGE ? Discordrb.split_message(text) : [text]
    end
  end
end
