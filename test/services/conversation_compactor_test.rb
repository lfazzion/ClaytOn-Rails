# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/conversation_compactor"
require_relative "../../lib/llm/model_chain"

class ConversationCompactorTest < ActiveSupport::TestCase
  setup do
    @conversation = Conversation.open_for(scope: "u:1:c:2", channel_id: "2", user_id: "1")
    # A cadeia é fixada aqui porque `Llm::ModelChain.links` lê ENV de verdade e o
    # serviço `test` carrega o `.env` da raiz: sem o estube, o resumidor que estes
    # testes exercitam muda conforme quais chaves de API a máquina por acaso tem, e
    # a suíte deixa de ser determinística. O elo escolhido espelha o primário de
    # produção — com `params`, sem `effort` —, para o caminho padrão dos testes ser
    # o caminho real. Quem precisa de outra cadeia sobrescreve com um `stubs` próprio.
    Llm::ModelChain.stubs(:links).returns([ELO_POOLSIDE])
  end

  teardown do
    ENV.delete("DISCORD_COMPACTION_THRESHOLD")
    ENV.delete("DISCORD_PROTECTED_TAIL")
  end

  def add_message(role, content, username: "joao")
    ChatMessage.create!(
      conversation: @conversation, role: role, content: content,
      discord_user_id: (role == "user" ? "1" : nil),
      discord_username: (role == "user" ? username : nil)
    )
  end

  def stub_summary(text)
    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).returns(stub(content: text))
    RubyLLM.stubs(:chat).returns(chat)
  end

  test "threshold tem padrão 0.75" do
    assert_in_delta 0.75, ConversationCompactor.threshold, 0.001
  end

  test "threshold é lido da ENV e clampado" do
    ENV["DISCORD_COMPACTION_THRESHOLD"] = "0.5"
    assert_in_delta 0.5, ConversationCompactor.threshold, 0.001

    ENV["DISCORD_COMPACTION_THRESHOLD"] = "9"
    assert_in_delta 0.95, ConversationCompactor.threshold, 0.001

    ENV["DISCORD_COMPACTION_THRESHOLD"] = "0"
    assert_in_delta 0.75, ConversationCompactor.threshold, 0.001
  end

  test "protected_tail tem padrão 8 e é clampado" do
    assert_equal 8, ConversationCompactor.protected_tail

    ENV["DISCORD_PROTECTED_TAIL"] = "3"
    assert_equal 3, ConversationCompactor.protected_tail

    ENV["DISCORD_PROTECTED_TAIL"] = "9999"
    assert_equal 50, ConversationCompactor.protected_tail
  end

  test "estimated_tokens usa chars/4" do
    assert_equal 25, ConversationCompactor.estimated_tokens("a" * 100)
  end

  test "window_for cai no padrão quando o modelo é desconhecido" do
    RubyLLM.stubs(:models).raises(StandardError, "sem registry")

    assert_equal ConversationCompactor::DEFAULT_WINDOW, ConversationCompactor.window_for("x")
  end

  test "window_for usa o context_window do registry" do
    RubyLLM.stubs(:models).returns(stub(find: stub(context_window: 128_000)))

    assert_equal 128_000, ConversationCompactor.window_for("modelo")
  end

  test "needs_compaction? é falso em conversa curta" do
    RubyLLM.stubs(:models).returns(stub(find: stub(context_window: 100_000)))
    add_message("user", "oi")

    assert_not ConversationCompactor.needs_compaction?(@conversation, model_id: "m")
  end

  test "needs_compaction? é verdadeiro quando a ocupação cruza o limiar" do
    RubyLLM.stubs(:models).returns(stub(find: stub(context_window: 1_000)))
    12.times { |i| add_message(i.even? ? "user" : "assistant", "x" * 500) }

    assert ConversationCompactor.needs_compaction?(@conversation, model_id: "m")
  end

  test "compact! grava resumo e marca até onde cobriu" do
    ENV["DISCORD_PROTECTED_TAIL"] = "2"
    stub_summary("## Pedido em aberto\n\"me diz o preco\"")
    5.times { |i| add_message(i.even? ? "user" : "assistant", "mensagem #{i}") }
    terceira = @conversation.chat_messages.for_llm.to_a[2]

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    @conversation.reload

    assert_includes @conversation.summary, "Pedido em aberto"
    assert_equal terceira.id, @conversation.summary_covers_upto_id
  end

  test "compact! não roda quando não há mensagem além da cauda protegida" do
    ENV["DISCORD_PROTECTED_TAIL"] = "8"
    3.times { add_message("user", "oi") }

    assert_not ConversationCompactor.compact!(@conversation, model_id: "m")
    assert_nil @conversation.reload.summary
  end

  test "o transcript enviado ao modelo carrega a fala do usuário literalmente" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "quero o relatório do João até sexta")
    add_message("assistant", "ok")
    add_message("user", "ultima")

    capturado = nil
    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).with { |texto| capturado = texto }.returns(stub(content: "resumo"))
    RubyLLM.stubs(:chat).returns(chat)

    ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_includes capturado, "quero o relatório do João até sexta"
  end

  test "o resumo é regerado das mensagens, nunca do resumo anterior" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    @conversation.update!(summary: "RESUMO_ANTIGO_NAO_PODE_ENTRAR")
    add_message("user", "primeira")
    add_message("assistant", "resposta")
    add_message("user", "ultima")

    capturado = nil
    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).with { |texto| capturado = texto }.returns(stub(content: "resumo novo"))
    RubyLLM.stubs(:chat).returns(chat)

    ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_not_includes capturado, "RESUMO_ANTIGO_NAO_PODE_ENTRAR"
  end

  test "falha de LLM cai no plano B com as falas do usuário literais" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "frase exata do dono")
    add_message("assistant", "resposta longa do bot que nao precisa sobreviver")
    add_message("user", "ultima")
    RubyLLM.stubs(:chat).raises(StandardError, "rate limit")

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    @conversation.reload

    assert_includes @conversation.summary, "frase exata do dono"
    assert_not_nil @conversation.summary_failed_at
  end

  # --- Os três elos da cadeia de produção, para os testes do resumidor. ---
  ELO_POOLSIDE = Llm::ModelChain::Link.new(
    label: "poolside-direta", provider: :poolside, model: "poolside/laguna-s-2.1",
    effort: nil, params: { chat_template_kwargs: { enable_thinking: false } }
  )
  ELO_NOUS = Llm::ModelChain::Link.new(
    label: "nous", provider: :nous, model: "tencent/hy3:free",
    effort: "none", params: nil
  )
  ELO_OPENROUTER = Llm::ModelChain::Link.new(
    label: "openrouter", provider: :openrouter, model: "openrouter/free",
    effort: nil, params: nil
  )

  def prepara_compactacao
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "fala que precisa sobreviver na conversa")
    add_message("assistant", "resposta do bot que não pode ser jogada fora todo turno")
    add_message("user", "cauda")
  end

  # DEFEITO B da primeira revisão: o resumidor não pode ficar cravado num provedor
  # específico. A promessa central da entrega é "chave ausente encurta a cadeia, não
  # quebra" — cravar o resumidor na OpenRouter quebra essa promessa assim que o dono
  # roda só com Poolside e/ou Nous: `RubyLLM::ConfigurationError` em toda tentativa de
  # resumo, plano B (perde a fala do assistente) toda vez, para sempre, sem nunca se
  # recuperar, porque a causa (chave ausente) não muda sozinha.
  test "DEFEITO B: sem OpenRouter configurado, o resumidor sai da cadeia em vez de um provedor cravado" do
    prepara_compactacao
    Llm::ModelChain.stubs(:links).returns([ELO_NOUS]) # só Poolside+Nous: OpenRouter fora da cadeia
    Llm::ModelChain.stubs(:summarizer).returns(nil)   # sem resumidor dedicado: tem de cair na cadeia

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).returns(stub(content: "resumo via nous"))
    RubyLLM.expects(:chat).with(model: ELO_NOUS.model, provider: ELO_NOUS.provider).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_includes @conversation.reload.summary, "resumo via nous"
    assert_nil @conversation.summary_failed_at, "não pode cair no plano B quando o LLM respondeu"
  end

  # F2 da revisão final. Sem isto o resumidor roda com o raciocínio LIGADO na
  # mesma rota em que o chat ao vivo o desliga. Medido em 2026-08-07 contra o
  # resumidor real (mesmo prompt de produção), elo primário, transcript
  # realista de 31 mensagens, 3 amostras de cada: LIGADO (nada aplicado)
  # 8.287/4.465/16.779 ms, 1.698/1.483/1.486 chars; DESLIGADO (esta aplicação)
  # 8.776/3.436/3.089 ms, 1.399/1.393/1.375 chars — mais rápido em média e sem
  # perder nenhum fato da conversa nem o "Pedido em aberto" literal nas duas
  # condições, então desligar aqui não empobrece o resumo.
  test "F2: o resumidor aplica o desligamento de raciocínio DO ELO, com o mecanismo daquela rota" do
    prepara_compactacao
    Llm::ModelChain.stubs(:summarizer).returns(ELO_POOLSIDE)

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:ask).returns(stub(content: "resumo"))
    # A rota direta da Poolside IGNORA reasoning_effort e recusa `none` com HTTP 400:
    # o mecanismo dela é chat_template_kwargs. Trocar um pelo outro não degrada, quebra.
    chat.expects(:with_params).with(chat_template_kwargs: { enable_thinking: false }).once.returns(chat)
    chat.expects(:with_thinking).never
    RubyLLM.stubs(:chat).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
  end

  test "F2: no elo do Nous o resumidor manda reasoning_effort, e nunca chat_template_kwargs" do
    prepara_compactacao
    Llm::ModelChain.stubs(:summarizer).returns(ELO_NOUS)

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:ask).returns(stub(content: "resumo"))
    chat.expects(:with_thinking).with(effort: "none").once.returns(chat)
    chat.expects(:with_params).never
    RubyLLM.stubs(:chat).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
  end

  test "cooldown impede nova chamada de LLM por 10 minutos" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    @conversation.update!(summary_failed_at: 1.minute.ago)
    add_message("user", "frase do dono")
    add_message("assistant", "resposta")
    add_message("user", "ultima")
    RubyLLM.expects(:chat).never

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    assert_includes @conversation.reload.summary, "frase do dono"
  end

  test "cooldown expirado permite nova tentativa de LLM" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    @conversation.update!(summary_failed_at: 30.minutes.ago)
    stub_summary("resumo do modelo")
    add_message("user", "a")
    add_message("assistant", "b")
    add_message("user", "c")

    ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_includes @conversation.reload.summary, "resumo do modelo"
    assert_nil @conversation.reload.summary_failed_at
  end

  test "segredo no resumo do modelo vira [REDACTED]" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    stub_summary("a chave e sk-abcdef0123456789abcdef0123456789 pronto")
    add_message("user", "a")
    add_message("assistant", "b")
    add_message("user", "c")

    ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_includes @conversation.reload.summary, "[REDACTED]"
    assert_not_includes @conversation.reload.summary, "sk-abcdef0123456789abcdef0123456789"
  end

  test "resumo maior que o orçamento é cortado" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    RubyLLM.stubs(:models).returns(stub(find: stub(context_window: 10_000)))
    stub_summary("x" * 500_000)
    add_message("user", "a")
    add_message("assistant", "b")
    add_message("user", "c")

    ConversationCompactor.compact!(@conversation, model_id: "m")
    orcamento_chars = ConversationCompactor.budget_tokens(10_000) * ConversationCompactor::CHARS_PER_TOKEN

    assert_operator @conversation.reload.summary.length, :<=, orcamento_chars
  end

  test "budget_tokens respeita piso, razão e teto" do
    assert_equal ConversationCompactor::MIN_SUMMARY_TOKENS, ConversationCompactor.budget_tokens(1_000)
    assert_equal 6_000, ConversationCompactor.budget_tokens(30_000)
    assert_equal ConversationCompactor::MAX_SUMMARY_TOKENS, ConversationCompactor.budget_tokens(1_000_000)
  end

  test "needs_compaction? loga limiar configurado, efetivo e proxy chars/4" do
    ENV["DISCORD_COMPACTION_THRESHOLD"] = "9"
    RubyLLM.stubs(:models).returns(stub(find: stub(context_window: 1_000)))
    12.times { |i| add_message(i.even? ? "user" : "assistant", "x" * 500) }

    Rails.logger.expects(:info).with { |msg|
      msg.include?("proxy chars/4") &&
      msg.include?("limiar configurado 9") &&
      msg.include?("limiar efetivo 0.95")
    }

    assert ConversationCompactor.needs_compaction?(@conversation, model_id: "m")
  end

  # --- A1: gatilho por contagem de mensagens, com a janela REAL (sem stub) ---
  # Antes do fix, needs_compaction? só olhava ocupação de token, e a janela real
  # do modelo primário (262.144 tokens) é grande demais para o proxy chars/4
  # alcançar num chat de Discord normal. Este teste não estuba RubyLLM.models:
  # usa o modelo primário de verdade, registrado em config/initializers/ruby_llm.rb.
  #
  # O id mudou junto com o elo primário (era `poolside/laguna-s-2.1:free` pela
  # OpenRouter, virou `poolside/laguna-xs-2.1` pela rota direta). A troca NÃO é
  # cosmética: o id antigo saiu do registry, `window_for` caía no DEFAULT_WINDOW
  # de 32.000 e este teste passava a exercitar o padrão em vez da janela grande
  # que ele existe para cobrir — verde, e sem guardar nada. A asserção abaixo
  # trava isso: se a janela voltar a ser a padrão, o teste reprova.
  # Amarrado ao elo primário REAL (lido da ENV do processo, sem stub) em vez de
  # cravado, para que trocar o elo 1 (troca de modelo, de provedor, ou uma
  # chave que suma) faça este teste reclamar sozinho — e não fique verde
  # exercitando um par modelo/provider que já não é o primário de ninguém.
  MODELO_PRIMARIO = Llm::ModelChain.primary&.model || "poolside/laguna-xs-2.1"
  PROVEDOR_PRIMARIO = Llm::ModelChain.primary&.provider || :poolside

  def janela_real_do_primario
    info = RubyLLM.models.find(MODELO_PRIMARIO, PROVEDOR_PRIMARIO)
    flunk("Modelo primário '#{MODELO_PRIMARIO}' (provedor #{PROVEDOR_PRIMARIO.inspect}) não foi encontrado no RubyLLM.models registry") if info.nil?

    janela = info.context_window
    flunk("context_window de '#{MODELO_PRIMARIO}' no registry é inválida: #{janela.inspect}") unless janela.to_i.positive?
    janela
  rescue StandardError => e
    flunk("Erro ao buscar context_window no RubyLLM.models para '#{MODELO_PRIMARIO}' (#{PROVEDOR_PRIMARIO.inspect}): #{e.class.name} - #{e.message}")
  end

  test "needs_compaction? dispara por CONTAGEM de mensagens vivas, mesmo com a janela real do modelo primário" do
    janela_esperada = janela_real_do_primario
    limite_mensagens = ConversationRehydrator.rehydrate_limit
    (limite_mensagens + 5).times { |i| add_message(i.even? ? "user" : "assistant", "oi") }

    assert ConversationCompactor.needs_compaction?(@conversation, model_id: MODELO_PRIMARIO,
                                                                  provider: PROVEDOR_PRIMARIO)

    # Prova de que quem disparou foi a contagem, não o token: a ocupação real
    # está bem abaixo do limiar real (isso é exatamente o que A1 não pegava).
    window = ConversationCompactor.window_for(MODELO_PRIMARIO, provider: PROVEDOR_PRIMARIO)

    assert_equal janela_esperada, window,
                 "a janela veio do registry, não do DEFAULT_WINDOW — senão este teste não cobre nada"

    limite_tokens = (window * ConversationCompactor.threshold).to_i
    ocupacao = ConversationCompactor.live_tokens(@conversation)

    assert_operator ocupacao, :<, limite_tokens
  end

  test "needs_compaction? continua falso com poucas mensagens e janela real, quando nada cruza limiar" do
    janela_esperada = janela_real_do_primario
    limite_mensagens = ConversationRehydrator.rehydrate_limit
    (limite_mensagens - 1).times { |i| add_message(i.even? ? "user" : "assistant", "oi") }

    assert_equal janela_esperada,
                 ConversationCompactor.window_for(MODELO_PRIMARIO, provider: PROVEDOR_PRIMARIO),
                 "a janela veio do registry, não do DEFAULT_WINDOW"
    assert_not ConversationCompactor.needs_compaction?(@conversation, model_id: MODELO_PRIMARIO,
                                                                      provider: PROVEDOR_PRIMARIO)
  end

  # --- A2: transcript mandado ao resumidor é truncado pela janela DELE ---
  test "transcript mandado ao resumidor é truncado quando excede a janela dele, e summary_covers_upto_id " \
       "para na última mensagem que de fato entrou" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    # O modelo do resumidor vem de `Llm::ModelChain.summarizer` (escolhido por
    # latência, não é o elo 1). Fixa aqui para o teste não depender de quais
    # chaves reais estão no ambiente.
    elo_resumo = Llm::ModelChain::Link.new(label: "resumo-teste", provider: :openrouter,
                                           model: "openrouter/free", effort: nil, params: nil)
    Llm::ModelChain.stubs(:summarizer).returns(elo_resumo)

    # `window_for` sempre chama `find(model_id, provider)`, com `provider`
    # explícito — por isso o stub tem que casar os DOIS argumentos, não só o
    # model_id.
    registry = mock("registry")
    registry.stubs(:find).with(elo_resumo.model, elo_resumo.provider).returns(stub(context_window: 100))
    registry.stubs(:find).with("m", nil).returns(stub(context_window: 100_000))
    RubyLLM.stubs(:models).returns(registry)

    curta = add_message("user", "pergunta curta")
    add_message("assistant", "x" * 2_000)
    add_message("user", "fala da cauda protegida")

    capturado = nil
    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).with { |texto| capturado = texto }.returns(stub(content: "resumo truncado"))
    RubyLLM.stubs(:chat).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    @conversation.reload

    assert_includes capturado, "pergunta curta"
    assert_not_includes capturado, "x" * 2_000
    assert_equal curta.id, @conversation.summary_covers_upto_id
  end

  test "quando o transcript cabe inteiro na janela do resumidor, summary_covers_upto_id cobre toda a alvo" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    stub_summary("resumo cabe tudo")
    add_message("user", "a")
    ultima_do_alvo = add_message("assistant", "b")
    add_message("user", "c") # cauda protegida, fora do alvo

    ConversationCompactor.compact!(@conversation, model_id: "m")

    assert_equal ultima_do_alvo.id, @conversation.reload.summary_covers_upto_id
  end

  # --- A3: plano B com muitas mensagens não perde nem corta falas de usuário no meio ---
  test "plano B com 100+ mensagens preserva TODA fala de usuário, cada uma truncada individualmente " \
       "com marcador visível quando necessário, nunca cortada sem indicação" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    total = 120
    conteudo_base = "conteudo " * 20
    total.times do |i|
      add_message("user", "FALA_#{format('%03d', i)}: #{conteudo_base}")
      add_message("assistant", "resposta #{i} " * 20)
    end
    add_message("user", "fala da cauda protegida")

    RubyLLM.stubs(:chat).raises(StandardError, "sem cota")

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    resumo = @conversation.reload.summary
    linhas = resumo.split("\n")[2..] # pula as duas linhas do cabeçalho fixo

    assert_equal total, linhas.size, "alguma fala de usuário desapareceu do plano B"

    (0...total).each do |i|
      marcador = "FALA_#{format('%03d', i)}"
      linha = linhas.find { |l| l.include?(marcador) }
      assert linha, "fala #{marcador} desapareceu do plano B"
      assert linha.end_with?(ConversationCompactor::TRUNCATION_MARKER),
             "fala #{marcador} foi cortada sem marcador visível de truncagem: #{linha.inspect}"
    end

    assert_not_includes resumo, "resposta 0 " # assistente não entra no plano B, como já era o contrato
  end

  test "plano B não corta uma fala curta ao meio quando ela cabe inteira no orçamento" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "frase curta e completa")
    add_message("assistant", "resposta")
    add_message("user", "cauda")
    RubyLLM.stubs(:chat).raises(StandardError, "sem cota")

    ConversationCompactor.compact!(@conversation, model_id: "m")
    resumo = @conversation.reload.summary

    assert_includes resumo, "- joao: frase curta e completa"
    assert_not_includes resumo, ConversationCompactor::TRUNCATION_MARKER
  end

  # --- A4: resumo em branco é tratado como falha, não como sucesso vazio ---
  test "resumo em branco do LLM é tratado como falha: grava summary_failed_at e usa o plano B" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "fala que precisa sobreviver")
    add_message("assistant", "resposta qualquer")
    add_message("user", "cauda")

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).returns(stub(content: ""))
    RubyLLM.stubs(:chat).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    @conversation.reload

    assert_not_nil @conversation.summary_failed_at
    assert_includes @conversation.summary, "fala que precisa sobreviver"
  end

  # --- A5: um único ponto de saída aplica redact + clamp nos três caminhos ---
  test "segredo no plano B (falha de LLM) vira [REDACTED], e o plano B respeita o orçamento" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    add_message("user", "minha chave e sk-abcdef0123456789abcdef0123456789")
    add_message("assistant", "ok")
    add_message("user", "cauda")
    RubyLLM.stubs(:chat).raises(StandardError, "sem cota")

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    resumo = @conversation.reload.summary

    assert_includes resumo, "[REDACTED]"
    assert_not_includes resumo, "sk-abcdef0123456789abcdef0123456789"
    orcamento_chars = ConversationCompactor.budget_tokens(ConversationCompactor.window_for("m")) *
                       ConversationCompactor::CHARS_PER_TOKEN
    assert_operator resumo.length, :<=, orcamento_chars
  end

  test "segredo no plano B por cooldown também vira [REDACTED]" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    @conversation.update!(summary_failed_at: 1.minute.ago)
    add_message("user", "chave: sk-abcdef0123456789abcdef0123456789")
    add_message("assistant", "ok")
    add_message("user", "cauda")
    RubyLLM.expects(:chat).never

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    resumo = @conversation.reload.summary

    assert_includes resumo, "[REDACTED]"
    assert_not_includes resumo, "sk-abcdef0123456789abcdef0123456789"
  end

  test "SECRET_PATTERNS agora cobre AWS, Google, GitHub (fine-grained e oauth), JWT e chave privada" do
    ENV["DISCORD_PROTECTED_TAIL"] = "1"
    segredos = [
      "AKIAABCDEFGHIJKLMNOP",
      "AIza#{'x' * 35}",
      "github_pat_#{'a' * 30}",
      "gho_#{'b' * 20}",
      "ghs_#{'c' * 20}",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
      "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAK9example\n-----END RSA PRIVATE KEY-----"
    ]
    add_message("user", "segredos: #{segredos.join(' | ')}")
    add_message("assistant", "ok")
    add_message("user", "cauda")
    RubyLLM.stubs(:chat).raises(StandardError, "sem cota")

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    resumo = @conversation.reload.summary

    segredos.each { |segredo| assert_not_includes resumo, segredo }
    assert_includes resumo, "[REDACTED]"
  end

  # D9: com três rotas na cadeia, medir sempre contra a janela de um modelo fixo
  # mente quando o elo em uso tem janela diferente. E `find` sem provedor pode
  # casar o modelo errado quando dois provedores servem ids parecidos.
  test "window_for aceita provedor e resolve o modelo daquela rota" do
    modelo = Struct.new(:context_window).new(262_144)
    RubyLLM.stubs(:models).returns(mock("models").tap do |m|
      m.expects(:find).with("poolside/laguna-xs-2.1", :poolside).returns(modelo)
    end)

    assert_equal 262_144, ConversationCompactor.window_for("poolside/laguna-xs-2.1", provider: :poolside)
  end

  test "needs_compaction? repassa o provedor para a busca da janela" do
    conversation = Conversation.create!(scope: "u:9:c:9", discord_channel_id: "9",
                                        last_active_at: Time.current)
    ConversationCompactor.expects(:window_for).with("m", provider: :nous).returns(32_000)

    ConversationCompactor.needs_compaction?(conversation, model_id: "m", provider: :nous)
  end
  # Guarda a separação: o resumidor é o `laguna-xs` por latência, mesmo com um elo
  # 1 completamente diferente na cadeia. Sem este teste, uma troca de modelo do
  # chat arrasta o resumo junto sem ninguém perceber.
  test "F1: o resumidor é o de ModelChain.summarizer, não o elo 1 da cadeia" do
    prepara_compactacao
    Llm::ModelChain.stubs(:links).returns([ELO_POOLSIDE, ELO_NOUS, ELO_OPENROUTER])
    # Fixado, e não lido do ambiente: `ModelChain.summarizer` consulta ENV de
    # verdade, então sem este estube o teste passa na máquina do dono (que tem a
    # chave da Poolside) e reprova em qualquer outra — a mesma armadilha de
    # determinismo que a revisão de 2026-08-07 pegou em 12 testes.
    Llm::ModelChain.stubs(:summarizer).returns(
      Llm::ModelChain::Link.new(label: "resumidor", provider: :poolside,
                                model: Llm::ModelChain::SUMMARIZER_MODEL, effort: nil,
                                params: { chat_template_kwargs: { enable_thinking: false } })
    )

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).returns(stub(content: "resumo pelo resumidor dedicado"))
    RubyLLM.expects(:chat).with(model: Llm::ModelChain::SUMMARIZER_MODEL, provider: :poolside).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
    assert_includes @conversation.reload.summary, "resumo pelo resumidor dedicado"
  end

  test "F1: sem a chave da Poolside o resumidor cai no primeiro elo disponível" do
    prepara_compactacao
    Llm::ModelChain.stubs(:summarizer).returns(nil)
    Llm::ModelChain.stubs(:links).returns([ELO_NOUS, ELO_OPENROUTER])

    chat = mock("chat")
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:ask).returns(stub(content: "resumo pelo nous"))
    RubyLLM.expects(:chat).with(model: ELO_NOUS.model, provider: :nous).returns(chat)

    assert ConversationCompactor.compact!(@conversation, model_id: "m")
  end

end
