# frozen_string_literal: true

# Cache quente de RubyLLM::Chat por escopo, com a conversa vivendo no SQLite.
#
# O TTL não encerra mais conversa: ele só despeja o objeto da memória. A
# fronteira entre conversas é o /new. Em cache miss a conversa é reidratada do
# banco, então reiniciar o container não perde nada.
#
# RubyLLM::Chat guarda estado mutável de mensagens e não é thread-safe. No canal
# compartilhado duas pessoas podem falar ao mesmo tempo no MESMO objeto, então
# toda chamada roda dentro do mutex daquele escopo.
#
# Dois mutexes, dois donos: o de ESCOPO (`with_scope_lock`) serializa quem mexe
# num RubyLLM::Chat específico. O GLOBAL (`mutex`) é o único autorizado a tocar
# os Hashes `sessions_cache` e `mutexes`, que hospedam TODOS os escopos — o de
# escopo não protege Hash nenhum. Ordem de aquisição fixa para nunca formar
# ciclo: quem já segura o de escopo pode pedir o global (em blocos curtos, só
# para tocar os Hashes), mas nenhum caminho faz o inverso — segurar o global e
# pedir um de escopo.
class ChatSessionManager
  TTL_MINUTES = 30
  BLANK_RESPONSE_WARNING = "⚠️ O modelo não respondeu dessa vez. Tenta perguntar de novo?"

  # Tudo que faz um elo cair, e NÃO só `RubyLLM::Error`.
  #
  # `ConfigurationError` (chave ausente na config da gem) e `ModelNotFoundError`
  # (id fora do registry) descendem direto de `StandardError`, não de
  # `RubyLLM::Error` — verificado nos `ancestors` da gem 1.14.0. São exatamente
  # os dois erros que provedor novo e modelo novo produzem. `Faraday::Error`
  # cobre timeout, DNS e conexão recusada, que também escapam do `RubyLLM::Error`
  # e que, numa cadeia de três hosts diferentes, são o caso comum.
  #
  # Listar classe-mãe em vez de subclasses é a lição de 2026-08-06 registrada em
  # docs/MEMORY.md: `rescue` por lista de subclasses é lista de permissão, e o
  # caso não previsto é exatamente o que fura a rede de proteção.
  CHAIN_ERRORS = [
    RubyLLM::Error,
    RubyLLM::ConfigurationError,
    RubyLLM::ModelNotFoundError,
    Faraday::Error
  ].freeze

  # Dois limites distintos, e não um. PAGE_SIZE é quantas linhas cabem numa
  # mensagem do Discord (cada linha tem ~80 chars, 20 cabem sem quebrar).
  # SESSIONS_MAX é só guarda de memória para a consulta não crescer sem limite —
  # não é limite de uso.
  DEFAULT_PAGE_SIZE = 20
  MAX_PAGE_SIZE = 100
  DEFAULT_SESSIONS_MAX = 500

  Page = Struct.new(:conversations, :first_index, :number, :total_pages, :total, keyword_init: true)
  Apagada = Struct.new(:title, :message_count, keyword_init: true)

  class << self
    def ask(scope:, content:, user_id:, username:)
      with_scope_lock(scope.key) do
        Thread.current[:cleitin_actor] = { user_id: user_id, username: username }
        Thread.current[:cleitin_turn] = SecureRandom.hex(8)
        inicio = Time.now
        Rails.logger.info "[ChatSessionManager] Iniciando ask — " \
                          "scope=#{scope.key} user=#{user_id} " \
                          "chars=#{content.to_s.length}"
        begin
          conversation = conversation_for(scope)

          chat = prepare_chat(scope, conversation)
          texto = ask_through_chain(chat, outgoing_content(conversation, content, username),
                                    scope: scope, conversation: conversation)

          if texto.blank?
            Rails.logger.info "[ChatSessionManager] ask concluído em #{format("%.1f", (Time.now - inicio))}s chars=#{texto.to_s.length}"
            next handle_blank_response(scope)
          end

          # Título e mensagens só são persistidos DEPOIS da resposta — ver
          # outgoing_content — e em transação. O título antes da resposta gravava
          # uma pergunta que não existe quando a cadeia vinha em branco ou
          # estourava; e três escritas soltas deixavam `user` órfão se a segunda
          # falhasse (ex.: SQLITE_BUSY). O rescue despeja o cache quente: sem o
          # despejo, a próxima reidratação leria do banco a pergunta sem resposta
          # e duplicaria a fala do usuário.
          begin
            ActiveRecord::Base.transaction do
              conversation.assign_title_from(content)
              ChatMessage.create!(conversation: conversation, role: "user", content: content,
                                  discord_user_id: user_id, discord_username: username)
              ChatMessage.create!(conversation: conversation, role: "assistant", content: texto)
              conversation.touch_activity!
            end
          rescue StandardError => e
            Rails.logger.error "[ChatSessionManager] Falha ao persistir o turno " \
                               "(#{e.class.name}: #{e.message}) — despejando cache quente"
            evict(scope.key)
            raise
          end
          Rails.logger.info "[ChatSessionManager] ask concluído em #{format("%.1f", (Time.now - inicio))}s chars=#{texto.to_s.length}"
          texto
        ensure
          Thread.current[:cleitin_actor] = nil
          Thread.current[:cleitin_turn] = nil
        end
      end
    end
    def reset!(scope)
      with_scope_lock(scope.key) do
        Conversation.active_for(scope.key)&.close!
        evict(scope.key)
        nil
      end
    end

    def page_size
      configured = ENV["DISCORD_SESSIONS_PAGE_SIZE"].to_i
      return DEFAULT_PAGE_SIZE unless configured.positive?

      [[configured, 1].max, MAX_PAGE_SIZE].min
    end

    def sessions_max
      configured = ENV["DISCORD_SESSIONS_MAX"].to_i
      configured.positive? ? configured : DEFAULT_SESSIONS_MAX
    end

    # Lista ordenada INTEIRA (até o teto de memória). Quem fatia é `page`. Isso é
    # o que permite numeração contínua: o índice 25 é o índice 25 da lista toda,
    # independentemente de qual página está na tela.
    #
    # `left_joins` + `group` carregam a contagem de mensagens NA MESMA consulta
    # (msg_count) — antes, cada linha da listagem disparava um COUNT separado
    # (N+1) no renderizador. Bônus da troca por left_joins: conversas sem
    # mensagem aparecem com 0, em vez de sumirem da lista.
    def sessions(scope)
      Conversation.where(scope: scope.key)
                  .left_joins(:chat_messages)
                  .group(:id)
                  .select("conversations.*, COUNT(chat_messages.id) AS msg_count")
                  .recent.limit(sessions_max).to_a
    end

    # Total de conversas visíveis na listagem (respeitando o teto de memória).
    # É um COUNT barato: nos caminhos de erro o bot usa isto em vez de
    # reexecutar `sessions` inteira só para saber o tamanho da lista.
    def sessions_total(scope)
      [Conversation.where(scope: scope.key).count, sessions_max].min
    end

    # nil quando a página pedida não existe. Lista vazia devolve página 1 vazia,
    # não nil — "não há conversas" e "essa página não existe" são erros
    # diferentes e merecem textos diferentes.
    def page(scope, numero = 1)
      todas = sessions(scope)
      total_paginas = [(todas.size / page_size.to_f).ceil, 1].max
      pedida = numero.to_i
      pedida = 1 if pedida < 1
      return nil if pedida > total_paginas

      inicio = (pedida - 1) * page_size
      Page.new(conversations: todas[inicio, page_size] || [], first_index: inicio + 1,
               number: pedida, total_pages: total_paginas, total: todas.size)
    end

    # Devolve a Conversation retomada, ou :fora_da_faixa. Nunca clampa: quem pede
    # a conversa 99 numa lista de 5 tem que ver "não existe conversa 99", e não a
    # quinta conversa fingindo ser a nonagésima nona.
    #
    # Exceção: lista vazia devolve nil, não :fora_da_faixa. Isso preserva o
    # contrato do teste pré-existente "resume! devolve nil para índice fora da
    # lista" (bloqueador de revisão anterior, intocável) — a lista vazia é o
    # único caso em que os dois comportamentos coexistem sem colidir, porque os
    # testes novos de :fora_da_faixa sempre partem de uma lista não-vazia.
    def resume!(scope, index)
      with_scope_lock(scope.key) do
        lista = sessions(scope)
        alvo = at_index(lista, index)
        next (lista.empty? ? nil : :fora_da_faixa) if alvo.nil?

        Conversation.where(scope: scope.key, active: true).where.not(id: alvo.id)
                    .find_each(&:close!)
        alvo.update!(active: true, last_active_at: Time.current)
        evict(scope.key)
        alvo
      end
    end

    # Apaga de verdade: a conversa e as mensagens saem do banco (dependent: :destroy,
    # em transação). Sem lixeira e sem desfazer — o motivo de existir o comando é
    # não deixar registro. Recusa a conversa em andamento: apagá-la exigiria
    # despejar o cache quente e reabrir conversa, e o dono preferiu obrigar o /new
    # antes, que é um gesto que ele já conhece.
    def destroy!(scope, index)
      with_scope_lock(scope.key) do
        lista = sessions(scope)
        next :lista_vazia if lista.empty?

        alvo = at_index(lista, index)
        next :fora_da_faixa if alvo.nil?
        next :em_andamento if alvo.active

        resultado = Apagada.new(title: alvo.title, message_count: alvo.msg_count)
        alvo.destroy!
        resultado
      end
    end

    # TODA leitura/escrita de sessions_cache (e de mutexes) passa pelo mutex
    # GLOBAL — nunca pelo de escopo, que protege outra coisa (o objeto Chat).
    def cleanup_expired
      mutex.synchronize do
        sessions_cache.delete_if { |_key, session| session[:expires_at] < Time.current }
      end
      Rails.logger.info "[ChatSessionManager] Cleanup concluído. Sessões ativas: #{sessions_cache.size}"
    end

    def evict(scope_key)
      mutex.synchronize { sessions_cache.delete(scope_key) }
    end

    # Um chat novo amarrado a UM elo. O ajuste de raciocínio entra aqui e é
    # grudento no objeto: por isso um chat construído para um elo nunca é
    # reaproveitado em outro.
    #
    # `link:` é obrigatório de propósito: os dois chamadores de produção já
    # passam um `Link` explícito, e o valor-padrão antigo (`Llm::ModelChain.primary`)
    # é `nil` sem chave nenhuma configurada — `link.model` nesse caso levanta
    # `NoMethodError`, que NÃO está em `CHAIN_ERRORS` e derrubaria o turno em
    # vez de cair para o elo seguinte (ou, sem elo nenhum, mostrar o aviso).
    def build_chat(link:)
      chat = RubyLLM.chat(model: link.model, provider: link.provider)
      chat.with_thinking(effort: link.effort) if link.effort.present?
      chat.with_params(**link.params) if link.params.present?
      all_tool_classes.each { |tool_class| chat.with_tool(tool_class) }
      prompt = Llm::PromptLoader.load("chatbot", user_message: "")
      chat.with_instructions("#{prompt[:system]}\n\n#{model_identity(link)}")
      chat
    end

    # O modelo não sabe qual modelo ele é, e quando perguntado ele INVENTA com
    # confiança: em 08/08/2026, atendido pelo `poolside/laguna-s-2.1`, o bot
    # respondeu que estava usando "openrouter/mistral-small-3.1-8x22b" — um id
    # que nem existe (`mistral-small` e `8x22B` são modelos diferentes) — e ainda
    # elogiou o Mistral.
    #
    # Não dá para cravar no YAML do prompt: o elo em uso muda em tempo de
    # execução (queda do primário, chave ausente), então a única fonte de verdade
    # é o `link` que está montando ESTE chat. Chega aqui pelo mesmo caminho que o
    # timestamp — injetado no prompt, não deduzido pelo modelo.
    def model_identity(link)
      "<modelo_em_uso: #{link.model}>\n<rota_em_uso: #{link.label}>\n" \
        "Se perguntarem qual modelo ou qual IA você usa, responda exatamente o que está acima. " \
        "NUNCA adivinhe nem invente nome de modelo, e não diga que é de outro fornecedor."
    end

    private

    # Índice de 1 em diante, sem clamp. Fora da faixa devolve nil, e cada chamador
    # transforma isso na mensagem certa com o tamanho real da lista na tela.
    def at_index(lista, index)
      posicao = index.to_i
      # O teto contra `lista.size` não é otimização: sem o clamp, o índice chega
      # cru e sem limite de dígitos, e `lista[bignum]` levanta RangeError ("bignum
      # too big to convert into 'long'). Isso virava "⚠️ Erro ao processar" em vez
      # da resposta educada com o intervalo real — o buraco que tirar o clamp abriu.
      return nil unless posicao.positive? && posicao <= lista.size

      lista[posicao - 1]
    end

    def conversation_for(scope)
      Conversation.active_for(scope.key) || open_conversation(scope)
    end

    def open_conversation(scope)
      Conversation.open_for(scope: scope.key, channel_id: scope.channel_id,
                            user_id: scope.user_id, shared: scope.shared)
    end

    # Compacta se precisar e devolve o chat quente do escopo, ou nil em cache
    # miss. NÃO constrói o chat: quem constrói é a cadeia, dentro do `rescue`,
    # porque `RubyLLM.chat` pode levantar `ConfigurationError` ou
    # `ModelNotFoundError` e essas quedas têm de cair para o elo seguinte em vez
    # de derrubar o turno.
    def prepare_chat(scope, conversation)
      link = Llm::ModelChain.primary
      if link && ConversationCompactor.needs_compaction?(conversation, model_id: link.model,
                                                                       provider: link.provider)
        compactou = ConversationCompactor.compact!(conversation, model_id: link.model,
                                                                 provider: link.provider)
        evict(scope.key) if compactou
      end

      cached = cache_read(scope.key)
      return nil unless cached && cached[:expires_at] > Time.current

      cached[:chat]
    end

    def touch_session(scope_key, chat)
      mutex.synchronize do
        sessions_cache[scope_key] = { chat: chat, expires_at: Time.current + TTL_MINUTES.minutes }
      end
      chat
    end

    def cache_read(scope_key)
      mutex.synchronize { sessions_cache[scope_key] }
    end

    # A fala deste turno só é persistida DEPOIS que a resposta chega (ver #ask):
    # persistir antes duplicava a pergunta no modelo — em cache miss a
    # reidratação lê `live_messages` do banco e a injeta via add_message, e o
    # chat.ask logo em seguida mandava a MESMA fala de novo. Aqui só formata o
    # texto deste turno para o chat quente, que ainda não o tem — carimbo de
    # autor quando a sala é compartilhada, com o nome saneado contra
    # personificação do papel `<autor>:` (reusa o sanitizador do ChatMessage,
    # que é quem já resolve esse problema para as falas persistidas).
    def outgoing_content(conversation, content, username)
      return content unless conversation.shared && username.present?

      "#{sanitized_username(username)}: #{content}"
    end

    # Reusa o reader público de ChatMessage — que já sabe neutralizar controle,
    # `:`, tamanho e nomes reservados (assistente, system...) — em vez de copiar
    # a lista de nomes reservados aqui. A instância não é salva; existe só para
    # emprestar o método.
    def sanitized_username(raw_username)
      ChatMessage.new(discord_username: raw_username).discord_username
    end

    # Percorre a cadeia inteira, em ordem, até alguém responder.
    #
    # O primeiro elo reaproveita o chat quente quando existe. Todo elo seguinte
    # reconstrói do banco — nunca do objeto que acabou de falhar, que já está
    # sujo (a gem chamou `add_message role: :user` antes de estourar e, no meio
    # de tool calls, pode ter deixado um assistant(tool_calls) sem resultado
    # casado).
    #
    # Resposta em branco NÃO é "cadeia esgotada": é rotina em modelo free (ver
    # `handle_blank_response`) e é tratada como falha DAQUELE elo, igual a uma
    # exceção — segue para o próximo. Só devolve nil (branco) quando TODOS os
    # elos vierem em branco, e quem chama (`ask`) já sabe transformar nil em
    # `BLANK_RESPONSE_WARNING`.
    def ask_through_chain(quente, content, scope:, conversation:)
      links = Llm::ModelChain.links
      if links.empty?
        Rails.logger.error "[ChatSessionManager] Nenhum elo de LLM disponível — " \
                           "nenhuma chave configurada (POOLSIDE_API_KEY, NOUS_API_KEY, OPENROUTER_API_KEY)"
        return nil
      end

      ultimo = links.size - 1

      links.each_with_index do |link, indice|
        # A construção mora DENTRO do rescue de propósito: `RubyLLM.chat` resolve
        # provedor e modelo, e é aí que nascem ConfigurationError e
        # ModelNotFoundError.
        atual = if indice.zero? && quente
                  quente
                else
                  ConversationRehydrator.apply!(build_chat(link: link), conversation.reload)
                end

        texto = extract(atual.ask(content))

        if texto.blank?
          proximo = indice < ultimo ? ", tentando #{links[indice + 1].label}..." : " — cadeia esgotada"
          Rails.logger.warn "[ChatSessionManager] Elo #{link.label} devolveu resposta em branco#{proximo}"
          evict(scope.key)
          next
        end

        Rails.logger.info "[ChatSessionManager] Respondido por #{link.label}"
        # Só o elo primário volta para o cache. O objeto de um elo secundário
        # carrega o esforço daquele elo, e `with_model` não desfaz
        # `with_thinking`/`with_params` — guardá-lo levaria a configuração errada
        # para o turno seguinte, em silêncio. O preço é uma reidratação a mais.
        touch_session(scope.key, atual) if indice.zero?
        return texto
      rescue *CHAIN_ERRORS => e
        proximo = indice < ultimo ? ", tentando #{links[indice + 1].label}..." : " — cadeia esgotada"
        Rails.logger.warn "[ChatSessionManager] Elo #{link.label} falhou " \
                          "(#{e.class.name}: #{e.message})#{proximo}"
        evict(scope.key)
        raise if indice == ultimo
      rescue StandardError => e
        # Erro que NÃO é falha de rota (ex.: exceção de tool subindo por dentro
        # de `atual.ask` — ActiveRecord::StatementInvalid, timeout de banco...)
        # não é motivo para tentar o elo seguinte: é motivo para abortar o
        # turno JÁ. Sem este rescue, o objeto que acabou de falhar (com uma
        # fala `user` pendurada, e possivelmente um `assistant(tool_calls)` sem
        # resultado casado) escapava do `rescue *CHAIN_ERRORS` — que só cobre a
        # lista de falha de ROTA — e sobrevivia os 30 min de TTL no cache
        # quente, fazendo todo turno seguinte reenviar a pergunta órfã ao
        # modelo.
        Rails.logger.error "[ChatSessionManager] Elo #{link.label} levantou erro fora de CHAIN_ERRORS " \
                           "(#{e.class.name}: #{e.message}) — abortando o turno e limpando o cache"
        evict(scope.key)
        raise
      end

      nil
    end

    # Resposta vazia é rotina em modelo free, não exceção. ChatMessage exige
    # content presente, então isto nunca vira registro — e o chat quente já tem a
    # troca (o gem faz add_message da resposta em branco por dentro), então
    # despeja para não divergir do banco: a próxima leitura reidrata sem este
    # turno, em vez de arriscar dois `user` consecutivos numa reidratação futura.
    def handle_blank_response(scope)
      evict(scope.key)
      BLANK_RESPONSE_WARNING
    end

    def extract(response)
      response.respond_to?(:content) ? response.content.to_s : response.to_s
    end

    # `mutexes` nunca é podado: mutexes de escopo nascem e ficam. O vazamento é
    # limitado ao número de escopos (canais/usuários), e o custo de mantê-los é
    # menor que a janela de corrida que a poda abria — removê-los sob o global
    # deixava um buraco entre a revalidação abaixo e o `synchronize`, quando
    # outra thread podia deletar o mutex e criar um novo, e duas threads
    # sincronizariam em mutexes DIFERENTES para o MESMO escopo, mutando o mesmo
    # RubyLLM::Chat em paralelo. A revalidação de identidade sob o global ANTES
    # de travar permanece como rede de segurança: se o mutex registrado já não
    # é o que pegamos, recomeça com o atual.
    def with_scope_lock(scope_key, &block)
      loop do
        m = scope_mutex(scope_key)
        return m.synchronize(&block) if mutex.synchronize { mutexes[scope_key].equal?(m) }
      end
    end

    def scope_mutex(scope_key)
      mutex.synchronize { mutexes[scope_key] ||= Mutex.new }
    end

    def sessions_cache
      @sessions ||= {}
    end

    def mutexes
      @mutexes ||= {}
    end

    def mutex
      @mutex ||= Mutex.new
    end

    def all_tool_classes
      tools = [
        ProfileLookupTool, ProfileListTool, ProfileSearchTool, ProfileCompareTool,
        AddProfileTool, SetProfileMonitoringTool, RemoveProfileTool, PromoteProspectTool,
        RecentPostsTool, TopPostsTool, PostsByTypeTool, PostEngagementTool,
        EngagementRateTool, SnapshotTrendTool, ProfileRankingTool,
        ProspectsTool, UnclassifiedProfilesTool,
        UpcomingCatalogTool, PopularCatalogTool,
        UpcomingEventsTool, RecentArticlesTool,
        WebSearchTool, PlatformSearchTool,
        TopicAddTool, TopicListTool, TopicRemoveTool,
        CreateSentimentTargetTool, RunSentimentAnalysisTool, SentimentStatusTool
      ]
      tools << PageFetchTool if ENV["ENABLE_PAGE_FETCH"].to_s.downcase == "true"
      tools
    end
  end
end
