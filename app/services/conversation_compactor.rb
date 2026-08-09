# frozen_string_literal: true

# Compacta uma conversa para caber na janela do modelo.
#
# Mecanismos portados do compactador do hermes
# (/home/hermes/.hermes/hermes-agent/agent/context_compressor.py):
#   * a fala do usuário é preservada literalmente — lá, medido: 11 compactações
#     transformaram 16 perguntas humanas em 92 entradas de "usuário";
#   * o resumo tem orçamento fixo (razão/piso/teto) e é sempre regerado das
#     mensagens originais, nunca do resumo anterior — lá o resumo cresceu de
#     7.057 para 20.612 caracteres se realimentando;
#   * a cauda protegida é contada por QUANTIDADE, nunca por orçamento de token:
#     por token, numa janela grande, protege tudo e não compacta nada;
#   * falha de resumo cai num plano B sem LLM, com cooldown, em vez de insistir.
class ConversationCompactor
  CHARS_PER_TOKEN = 4          # proxy declarado; não é tokenizador
  SUMMARY_RATIO = 0.20
  MIN_SUMMARY_TOKENS = 2_000
  MAX_SUMMARY_TOKENS = 10_000
  DEFAULT_THRESHOLD = 0.75
  DEFAULT_PROTECTED_TAIL = 8
  MAX_PROTECTED_TAIL = 50
  DEFAULT_WINDOW = 32_000
  FAILURE_COOLDOWN = 10.minutes
  FALLBACK_MAX_CHARS = 8_000

  # Usado SÓ quando a cadeia está vazia (nenhuma chave de LLM configurada).
  # Não é o resumidor "normal" — ver `summary_link`. Constante pública, e não
  # string inline, porque `summary_model_id` a usa como fallback REAL de
  # produção quando `summary_link` é nil — não é referência só de teste.
  FALLBACK_SUMMARY_MODEL = "openrouter/free"

  # Fração segura da janela do PRÓPRIO resumidor para o transcript de entrada.
  # A janela do resumidor (`summary_link`, o elo PRIMÁRIO da cadeia) pode não ser
  # a mesma janela do modelo usado no `model_id:` recebido por `compact!`: mandar
  # o histórico inteiro sem respeitar o teto do resumidor estoura a chamada de
  # resumo antes mesmo dela terminar.
  TRANSCRIPT_SAFETY_RATIO = 0.7
  TRUNCATION_MARKER = "[...truncado...]"

  # Padrões óbvios de credencial. É defesa em profundidade: o prompt já manda
  # redigir, mas prompt é pedido e isto é garantia.
  SECRET_PATTERNS = [
    /\bsk-[A-Za-z0-9_-]{16,}/,
    /\bBearer\s+[A-Za-z0-9._-]{16,}/i,
    /\bghp_[A-Za-z0-9]{16,}/,
    /\bgithub_pat_[A-Za-z0-9_]{16,}/,
    /\bgho_[A-Za-z0-9]{16,}/,
    /\bghs_[A-Za-z0-9]{16,}/,
    /\bxox[baprs]-[A-Za-z0-9-]{10,}/,
    /\bAKIA[A-Z0-9]{16}\b/,
    /\bAIza[A-Za-z0-9_-]{35}\b/,
    /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
    /-----BEGIN\s[A-Z ]*PRIVATE KEY-----.*?-----END\s[A-Z ]*PRIVATE KEY-----/m
  ].freeze

  class << self
    def threshold
      configured = ENV["DISCORD_COMPACTION_THRESHOLD"].to_f
      return DEFAULT_THRESHOLD unless configured.positive?

      [[configured, 0.10].max, 0.95].min
    end

    def protected_tail
      configured = ENV["DISCORD_PROTECTED_TAIL"].to_i
      return DEFAULT_PROTECTED_TAIL unless configured.positive?

      [[configured, 1].max, MAX_PROTECTED_TAIL].min
    end

    # `provider` opcional, mas quem tem a informação deve passar: com três rotas
    # servindo ids parecidos, `find` sem provedor decide por uma lista fixa de
    # preferência da gem e pode devolver o modelo de outra rota — com outra
    # janela. Erro de janela aqui não estoura: vira compactação na hora errada.
    def window_for(model_id, provider: nil)
      window = RubyLLM.models.find(model_id, provider)&.context_window
      window.to_i.positive? ? window.to_i : DEFAULT_WINDOW
    rescue StandardError => e
      Rails.logger.debug "[ConversationCompactor] Janela desconhecida para #{model_id} " \
                         "(provedor #{provider.inspect}): #{e.message}"
      DEFAULT_WINDOW
    end

    def estimated_tokens(value)
      text = value.is_a?(String) ? value : Array(value).map(&:to_s).join
      (text.length / CHARS_PER_TOKEN.to_f).ceil
    end

    def budget_tokens(window)
      ratio = (window * SUMMARY_RATIO).to_i
      [[ratio, MIN_SUMMARY_TOKENS].max, MAX_SUMMARY_TOKENS].min
    end

    # Ocupação viva = resumo atual + mensagens ainda não cobertas por ele.
    def live_tokens(conversation)
      estimated_tokens(conversation.summary.to_s) +
        estimated_tokens(live_messages(conversation).map(&:llm_content))
    end

    # Dois gatilhos independentes, o que vier primeiro dispara:
    #   * ocupação de token cruzando o limiar da janela do modelo;
    #   * quantidade de mensagens vivas passando do limite que o
    #     ConversationRehydrator reidrata (`rehydrate_limit`) — sem este
    #     gatilho, a reidratação corta em `rehydrate_limit` e descarta o resto
    #     sem nunca ter passado por aqui, e a compactação nunca dispara em
    #     conversas normais de Discord (a janela do modelo primário é grande
    #     demais para o proxy chars/4 alcançar em uso real).
    def needs_compaction?(conversation, model_id:, provider: nil)
      window = window_for(model_id, provider: provider)
      limite_tokens = (window * threshold).to_i
      ocupacao = live_tokens(conversation)
      contagem = live_messages(conversation).size
      limite_mensagens = ConversationRehydrator.rehydrate_limit

      gatilho_tokens = ocupacao > limite_tokens
      gatilho_mensagens = contagem > limite_mensagens
      return false unless gatilho_tokens || gatilho_mensagens

      motivo = if gatilho_tokens && gatilho_mensagens
                 "tokens e mensagens"
               elsif gatilho_tokens
                 "tokens"
               else
                 "mensagens (reidratação corta em #{limite_mensagens} e descartaria o resto sem resumir)"
               end

      Rails.logger.info "[ConversationCompactor] Gatilho cruzado (#{motivo}) na conversa #{conversation.id}: " \
                        "#{ocupacao} tokens (proxy chars/#{CHARS_PER_TOKEN}) > #{limite_tokens} " \
                        "(janela #{window}, limiar configurado #{ENV.fetch('DISCORD_COMPACTION_THRESHOLD', 'ausente')}, " \
                        "limiar efetivo #{threshold}); #{contagem} mensagens vivas > limite de #{limite_mensagens}"
      true
    end

    # Regenera o resumo a partir das mensagens originais e marca até onde cobriu.
    # Devolve false quando não havia o que compactar. `summary_covers_upto_id`
    # nunca avança além da última mensagem que de fato entrou no texto gravado
    # — quando o transcript é truncado (ver `build_transcript`), pode ficar
    # aquém de `alvo.last.id`, e a mensagem que ficou de fora permanece viva
    # para ser tentada de novo na próxima compactação.
    def compact!(conversation, model_id:, provider: nil)
      alvo = messages_to_compact(conversation)
      return false if alvo.empty?

      window = window_for(model_id, provider: provider)
      resumo, covered_id = build_summary(conversation, alvo, window)
      return false if resumo.blank?

      conversation.update!(
        summary: resumo,
        summary_covers_upto_id: covered_id
      )
      true
    end

    def messages_to_compact(conversation)
      todas = conversation.chat_messages.for_llm.to_a
      corte = todas.size - protected_tail
      return [] if corte <= 0

      todas[0...corte]
    end

    def live_messages(conversation)
      relation = conversation.chat_messages.for_llm
      return relation.to_a if conversation.summary_covers_upto_id.blank?

      relation.where("id > ?", conversation.summary_covers_upto_id).to_a
    end

    private

    # Devolve [resumo_final, covered_id]. Todo caminho — LLM, plano B por
    # cooldown, plano B por exceção e plano B por resumo em branco — passa
    # pelo mesmo `finalize` (redact + clamp). Não existe caminho que saia cru:
    # é o único ponto de saída, de propósito.
    def build_summary(conversation, messages, window)
      return [finalize(fallback_summary(conversation, messages), window), messages.last.id] if cooling_down?(conversation)

      transcript_text, covered_id = build_transcript(messages)
      resumo = summarize_with_llm(conversation, transcript_text, window)

      if resumo.blank?
        Rails.logger.warn "[ConversationCompactor] Resumo do LLM veio em branco (comum quando o roteador " \
                          "free só responde com tool call ou recusa); tratando como falha, usando plano B " \
                          "e esperando #{FAILURE_COOLDOWN.inspect}"
        conversation.update!(summary_failed_at: Time.current)
        return [finalize(fallback_summary(conversation, messages), window), messages.last.id]
      end

      conversation.update!(summary_failed_at: nil) if conversation.summary_failed_at.present?
      [finalize(resumo, window), covered_id]
    rescue StandardError => e
      Rails.logger.warn "[ConversationCompactor] Resumo por LLM falhou (#{e.class.name}: " \
                        "#{e.message}); usando plano B e esperando #{FAILURE_COOLDOWN.inspect}"
      conversation.update!(summary_failed_at: Time.current)
      [finalize(fallback_summary(conversation, messages), window), messages.last.id]
    end

    def cooling_down?(conversation)
      conversation.summary_failed_at.present? &&
        conversation.summary_failed_at > FAILURE_COOLDOWN.ago
    end

    def summarize_with_llm(conversation, transcript_text, window)
      prompt = Llm::PromptLoader.load(
        "conversation_summary",
        transcript: transcript_text,
        shared: conversation.shared,
        budget_tokens: budget_tokens(window)
      )
      elo = summary_link
      chat = RubyLLM.chat(model: summary_model_id, provider: summary_provider)
      # O ajuste de raciocínio do elo tem de vir junto, do mesmo jeito que
      # `ChatSessionManager#build_chat` já faz para o chat ao vivo — sem isto o
      # resumidor rodava com o raciocínio LIGADO mesmo num elo que o desliga por
      # padrão (Poolside: `params` já vem com `chat_template_kwargs.enable_thinking:
      # false`, mas só tem efeito se for aplicado ao objeto `chat`).
      #
      # Medido antes de aplicar (ver `summary_link`): com o mesmo transcript de 31
      # mensagens e o mesmo prompt de produção, raciocínio LIGADO (nada aplicado)
      # rodou em 8.287/4.465/16.779 ms produzindo 1.698/1.483/1.486 chars;
      # DESLIGADO (esta linha aplicada) rodou em 8.776/3.436/3.089 ms produzindo
      # 1.399/1.393/1.375 chars — mais rápido em média (~5,1 s contra ~9,8 s) e sem
      # perder nenhum dos fatos decididos na conversa (números de seguidores,
      # engajamento, top posts, concorrente, preferências de formatação) nem o
      # "Pedido em aberto" literal nas duas condições. Desligar aqui não empobrece
      # o resumo — ao contrário do que se poderia temer por resumir ser a tarefa
      # onde uma resposta curta demais seria ruim.
      chat.with_thinking(effort: elo.effort) if elo&.effort.present?
      chat.with_params(**elo.params) if elo&.params.present?
      chat.with_instructions(prompt[:system])
      resposta = chat.ask(prompt[:user])
      resposta.respond_to?(:content) ? resposta.content.to_s : resposta.to_s
    end

    # Elo escolhido para resumir. Deriva da cadeia em vez de cravar um
    # provedor: a promessa central da entrega é "chave ausente encurta a
    # cadeia, não quebra", e cravar aqui um provedor específico (a OpenRouter
    # de antes) quebra essa promessa assim que o dono roda só com Poolside
    # e/ou Nous — o resumidor levantava `ConfigurationError` em TODA tentativa,
    # o resumo caía sempre no plano B (perdendo a fala do assistente) e nunca
    # se recuperava, porque a causa (chave ausente) nunca muda sozinha.
    #
    # **O critério aqui é LATÊNCIA, não capacidade** — e o motivo é onde isto roda.
    # Uma versão anterior deste comentário afirmava que "o resumo roda em
    # background, fora do caminho quente de qualquer turno". **Era falso**, e a
    # revisão de 2026-08-07 provou pelo call stack: o único chamador de `compact!`
    # em toda a árvore é `ChatSessionManager#prepare_chat`, dentro de `ask`, dentro
    # de `with_scope_lock` — DENTRO do turno do usuário, segurando o mutex daquele
    # escopo, antes mesmo de o bot perguntar ao modelo. Num canal compartilhado,
    # todo mundo espera junto.
    #
    # Duas escolhas erradas já foram feitas aqui, as duas por não medir:
    #   1. `openrouter/free` cravado: 28.883 / 54.082 / 71.802 ms num transcript
    #      PEQUENO. Com `config.request_timeout = 120`, transcript grande estoura o
    #      teto, cai no `rescue StandardError` de `build_summary`, vira plano B
    #      (perde a fala do assistente) e entra em cooldown de 10 min — as
    #      conversas maiores eram as que mais tinham a perder.
    #   2. `Llm::ModelChain.links.first`: amarra o resumidor ao modelo de CHAT, que
    #      é escolhido por outros critérios (acurácia de ferramenta, prosa). Quando
    #      o elo 1 virou o `laguna-s`, o resumo saltou de 3.180 ms para 9.849 ms
    #      sem que ninguém tivesse decidido isso.
    #
    # Hoje o resumidor é escolhido explicitamente, por medição, em
    # `Llm::ModelChain.summarizer` — que carrega os números. Aqui só fica o
    # fallback para a cadeia, para não quebrar a promessa de que chave ausente
    # encurta em vez de parar.
    #
    # Nota de processo: é a terceira vez neste projeto que um comentário afirma
    # como fato algo que a medição contradiz — ver `docs/MEMORY.md` (2026-08-06),
    # o `docker/CONTEXT.md` que descrevia vulnerabilidade inexistente, e o
    # comentário em `platform_search_tools.rb` que registrou "site:reddit.com
    # devolve ZERO" como propriedade do índice quando era o clima do instante.
    def summary_link
      Llm::ModelChain.summarizer || Llm::ModelChain.links.first
    end

    # Sem elo nenhum (nenhuma chave de LLM configurada), cai num id de
    # referência sem provider — RubyLLM.chat vai estourar ConfigurationError/
    # ModelNotFoundError na hora, capturado pelo `rescue StandardError` de
    # `build_summary`, que cai no plano B. Não há resumidor "sem chave" que
    # funcione; o objetivo aqui é só não morrer com NoMethodError antes disso.
    def summary_model_id
      summary_link&.model || FALLBACK_SUMMARY_MODEL
    end

    def summary_provider
      summary_link&.provider
    end

    def transcript_line(message)
      rotulo = message.user? ? (message.discord_username.presence || "usuario") : "assistente"
      "#{rotulo}: #{message.content}"
    end

    # Monta o transcript mandado ao resumidor, truncado a uma fração segura da
    # JANELA DO PRÓPRIO RESUMIDOR (`summary_link`) — não a do modelo primário.
    # Sem isso, a primeira compactação de uma conversa grande já não cabe no
    # prompt de resumo e cai sempre no plano B.
    #
    # Devolve [texto, covered_id] — `covered_id` é o maior id que realmente
    # entrou no texto. Falas de assistente descartadas por orçamento não
    # avançam o covered_id além do que sobrevive; falas de usuário nunca são
    # descartadas (só truncadas individualmente, como último recurso).
    def build_transcript(messages)
      max_chars = (window_for(summary_model_id, provider: summary_provider) * CHARS_PER_TOKEN *
                   TRANSCRIPT_SAFETY_RATIO).to_i
      pares = messages.map { |message| [message, transcript_line(message)] }
      total = pares.sum { |_, linha| linha.length + 1 }
      return [pares.map(&:last).join("\n"), messages.last.id] if total <= max_chars

      incluidas = select_prioritizing_user(pares, max_chars)
      covered_id = incluidas.map { |message, _| message.id }.max
      texto = incluidas.sort_by { |message, _| message.id }.map(&:last).join("\n")
      [texto, covered_id]
    end

    # A fala do usuário é a invariante; a do assistente é descartável (D8 /
    # spec §4). Sob pressão de orçamento: falas de assistente são as primeiras
    # a cair, inteiras — nunca falas de usuário. Se mesmo só com o usuário não
    # coubesse, cada fala de usuário é truncada individualmente (nunca
    # descartada por completo).
    def select_prioritizing_user(pares, max_chars)
      usuario, assistente = pares.partition { |message, _| message.user? }
      total_usuario = usuario.sum { |_, linha| linha.length + 1 }
      return truncate_lines_evenly(usuario, max_chars) if total_usuario > max_chars

      incluidas = usuario.dup
      restante = max_chars - total_usuario
      assistente.each do |par|
        custo = par.last.length + 1
        next if custo > restante

        incluidas << par
        restante -= custo
      end
      incluidas
    end

    # Distribui o orçamento em partes iguais entre as falas, truncando
    # individualmente as que não couberem — com marcador visível — em vez de
    # descartar alguma por completo ou fatiar o conjunto inteiro de texto
    # (que corta uma fala ao meio e apaga o miolo).
    def truncate_lines_evenly(pares, max_chars)
      return [] if pares.empty? || max_chars <= 0

      cota = [max_chars / pares.size, TRUNCATION_MARKER.length + 10].max
      pares.map do |message, linha|
        next [message, linha] if linha.length <= cota

        corte = [cota - TRUNCATION_MARKER.length, 0].max
        [message, "#{linha[0, corte]}#{TRUNCATION_MARKER}"]
      end
    end

    # Plano B determinístico, sem LLM: guarda só as falas do usuário, cada uma
    # literal (ou truncada individualmente, com marcador, quando não couber).
    # Nenhuma fala desaparece e nenhuma é cortada sem indicação visível — o
    # bug antigo fatiava o texto inteiro em head/tail e apagava o miolo,
    # levando falas inteiras junto e cortando a fala da fronteira ao meio.
    def fallback_summary(_conversation, messages)
      cabecalho = "## Pedido em aberto\n(resumo automático indisponível; falas do usuário preservadas)\n"
      falas = messages.select(&:user?)
      return cabecalho.chomp if falas.empty?

      pares = falas.map { |message| [message, "- #{message.discord_username.presence || 'usuario'}: #{message.content}"] }
      total = pares.sum { |_, linha| linha.length + 1 }
      orcamento = FALLBACK_MAX_CHARS - cabecalho.length
      linhas = total <= orcamento ? pares : truncate_lines_evenly(pares, orcamento)

      "#{cabecalho}#{linhas.map(&:last).join("\n")}"
    end

    def redact(text)
      SECRET_PATTERNS.reduce(text.to_s) { |acc, pattern| acc.gsub(pattern, "[REDACTED]") }
    end

    def clamp(text, window)
      limite = budget_tokens(window) * CHARS_PER_TOKEN
      return text if text.length <= limite

      Rails.logger.info "[ConversationCompactor] Resumo cortado de #{text.length} para #{limite} chars"
      text[0, limite]
    end

    # Único ponto de saída do resumo: redação de segredo e orçamento aplicados
    # sempre, nos três caminhos (LLM, plano B por cooldown/exceção/branco).
    def finalize(text, window)
      clamp(redact(text), window)
    end
  end
end
