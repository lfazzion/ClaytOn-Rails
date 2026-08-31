# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/social_profile_tools"
require_relative "../../app/tools/social_post_tools"
require_relative "../../app/tools/metrics_tools"
require_relative "../../app/tools/discovery_tools"
require_relative "../../app/tools/catalog_tools"
require_relative "../../app/tools/event_tools"
require_relative "../../app/tools/news_tools"
require_relative "../../app/services/chat_session_manager"

class ChatSessionManagerTest < ActiveSupport::TestCase
  setup do
    ChatSessionManager.instance_variable_set(:@sessions, {})
    ChatSessionManager.instance_variable_set(:@mutexes, {})
    ChatSessionManager.stubs(:all_tool_classes).returns([])
    @scope = Discord::SessionScope.for(user_id: "101", channel_id: "202")
    @link = Llm::ModelChain::Link.new(label: "openrouter", provider: :openrouter, model: "openrouter/free")
    Llm::ModelChain.stubs(:links).returns([@link])
    Llm::ModelChain.stubs(:primary).returns(@link)
  end

  # D2-F5a-v3 (30/08/2026): teardown limpa `Thread.current[:cleitin_*]`
  # para testes que setam manualmente (ou que rodam antes do `ask` cujo
  # ensure já limpa) não vazarem entre testes. Mesmo padrão já usado em
  # web_search_tools_test.rb e em outros testes do arquivo (cleitin_actor /
  # cleitin_turn / cleitin_origin).
  teardown do
    Thread.current[:cleitin_origin] = nil
    Thread.current[:cleitin_conversation_scope_key] = nil
  end

  def stub_chat(response_text = "resposta da IA")
    chat = mock("chat")
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:with_tool).returns(chat)
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(chat)
    chat.stubs(:ask).returns(stub(content: response_text))
    RubyLLM.stubs(:chat).returns(chat)
    chat
  end

  test "ask cria conversa, chama LLM e persiste mensagens no banco" do
    stub_chat("olá humano")

    resposta = ChatSessionManager.ask(scope: @scope, content: "oi bot", user_id: "101", username: "joao")

    assert_equal "olá humano", resposta
    conv = Conversation.active_for(@scope.key)
    assert_not_nil conv
    assert_equal "oi bot", conv.title
    assert_equal 2, conv.chat_messages.count

    user_msg = conv.chat_messages.first
    assert_equal "user", user_msg.role
    assert_equal "oi bot", user_msg.content
    assert_equal "101", user_msg.discord_user_id
    assert_equal "joao", user_msg.discord_username

    bot_msg = conv.chat_messages.last
    assert_equal "assistant", bot_msg.role
    assert_equal "olá humano", bot_msg.content
  end

  test "ask loga iniciando ask e ask concluido no caminho de sucesso" do
    linhas = []
    Rails.logger.stubs(:info).with { |m| linhas << m.to_s; true }
    stub_chat("resposta ok")

    ChatSessionManager.ask(scope: @scope, content: "oi bot", user_id: "101", username: "joao")

    assert linhas.any? { |l| l =~ /Iniciando ask/ }, "deveria logar 'Iniciando ask' — log foi: #{linhas.inspect}"
    assert linhas.any? { |l| l =~ /ask concluído/ }, "deveria logar 'ask concluído' — log foi: #{linhas.inspect}"
  end

  test "ask loga iniciando ask e ask concluido mesmo em resposta em branco" do
    linhas = []
    Rails.logger.stubs(:info).with { |m| linhas << m.to_s; true }
    stub_chat("")

    ChatSessionManager.ask(scope: @scope, content: "oi bot", user_id: "101", username: "joao")

    assert linhas.any? { |l| l =~ /Iniciando ask/ }, "deveria logar 'Iniciando ask' — log foi: #{linhas.inspect}"
    assert linhas.any? { |l| l =~ /ask concluído/ }, "deveria logar 'ask concluído' — log foi: #{linhas.inspect}"
  end

  test "ask devolve BLANK_RESPONSE_WARNING quando o modelo responde em branco e limpa o cache" do
    stub_chat("")

    resposta = ChatSessionManager.ask(scope: @scope, content: "oi bot", user_id: "101", username: "joao")

    assert_equal ChatSessionManager::BLANK_RESPONSE_WARNING, resposta
    conv = Conversation.active_for(@scope.key)
    assert_not_nil conv
    assert_equal 0, conv.chat_messages.count
    assert_nil conv.title, "titulo so e gravado junto da resposta; em branco nao existe pergunta"
    assert_nil ChatSessionManager.instance_variable_get(:@sessions)[@scope.key]
  end

  test "ask em canal compartilhado formata o nome de usuario na fala de saida" do
    shared_scope = Discord::SessionScope.for(user_id: "101", channel_id: "202")
    shared_scope.stubs(:shared).returns(true)

    chat = stub_chat("resposta")
    chat.expects(:ask).with("joao: mensagem no grupo").returns(stub(content: "resposta"))

    resposta = ChatSessionManager.ask(scope: shared_scope, content: "mensagem no grupo", user_id: "101", username: "joao")
    assert_equal "resposta", resposta
  end

  test "reset! encerra conversa ativa, remove do cache e devolve nil" do
    conv = Conversation.open_for(scope: @scope.key, channel_id: @scope.channel_id, user_id: @scope.user_id)
    sessions = ChatSessionManager.instance_variable_get(:@sessions)
    sessions[@scope.key] = { chat: mock("chat"), expires_at: 30.minutes.from_now }

    assert_nil ChatSessionManager.reset!(@scope)
    assert_not conv.reload.active
    assert_nil sessions[@scope.key]
  end

  test "sessions retorna conversas recentes com mensagens do escopo" do
    conv1 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv1, role: "user", content: "m1", discord_user_id: @scope.user_id, discord_username: "joao")
    conv2 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: conv2, role: "user", content: "m2", discord_user_id: @scope.user_id, discord_username: "joao")

    lista = ChatSessionManager.sessions(@scope)
    assert_equal [conv2, conv1], lista
  end

  test "page fatias as conversas por pagina" do
    conv = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "msg", discord_user_id: @scope.user_id, discord_username: "joao")

    pagina = ChatSessionManager.page(@scope, 1)
    assert_instance_of ChatSessionManager::Page, pagina
    assert_equal 1, pagina.number
    assert_equal 1, pagina.total
    assert_equal 1, pagina.total_pages
    assert_equal [conv], pagina.conversations

    assert_nil ChatSessionManager.page(@scope, 2)
  end

  test "resume! ativa conversa informada por indice ou retorna simbolos de status" do
    assert_nil ChatSessionManager.resume!(@scope, 1)

    c1 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: c1, role: "user", content: "c1", discord_user_id: @scope.user_id, discord_username: "joao")
    c2 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: c2, role: "user", content: "c2", discord_user_id: @scope.user_id, discord_username: "joao")

    # recent order: [c2, c1]. Indice 2 = c1.
    ret = ChatSessionManager.resume!(@scope, 2)
    assert_equal c1, ret
    assert c1.reload.active
    assert_not c2.reload.active

    assert_equal :fora_da_faixa, ChatSessionManager.resume!(@scope, 99)
  end

  test "destroy! remove conversa inativa do banco ou retorna simbolos de status" do
    assert_equal :lista_vazia, ChatSessionManager.destroy!(@scope, 1)

    c1 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, title: "ativa", last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: c1, role: "user", content: "m1", discord_user_id: @scope.user_id, discord_username: "joao")
    c2 = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, title: "antiga", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: c2, role: "user", content: "m2", discord_user_id: @scope.user_id, discord_username: "joao")

    # Indice 1 eh c1 (em andamento)
    assert_equal :em_andamento, ChatSessionManager.destroy!(@scope, 1)
    assert_equal :fora_da_faixa, ChatSessionManager.destroy!(@scope, 99)

    res = ChatSessionManager.destroy!(@scope, 2)
    assert_instance_of ChatSessionManager::Apagada, res
    assert_equal "antiga", res.title
    assert_equal 1, res.message_count
    assert_raise(ActiveRecord::RecordNotFound) { c2.reload }
  end

  # A limpeza de mutexes orfaos foi REMOVIDA de proposito (revisao de 2a rodada):
  # o prune_mutexes abria janela de corrida de identidade no with_scope_lock; o
  # custo de manter mutexes orfaos e limitado ao numero de escopos (canais/usuarios).
  test "cleanup_expired remove sessoes expiradas e preserva as ativas" do
    sessions = ChatSessionManager.instance_variable_get(:@sessions)

    sessions["expired_key"] = { chat: mock("chat"), expires_at: 1.hour.ago }
    sessions["active_key"] = { chat: mock("chat"), expires_at: 30.minutes.from_now }

    ChatSessionManager.cleanup_expired

    assert_nil sessions["expired_key"]
    assert_not_nil sessions["active_key"]
  end

  test "build_chat constroi objeto ruby_llm::chat com instrucoes e ferramentas" do
    ChatSessionManager.stubs(:all_tool_classes).returns([ProfileLookupTool])
    chat = mock("chat")
    chat.expects(:with_thinking).never
    chat.expects(:with_params).never
    chat.expects(:with_tool).at_least_once.returns(chat)
    chat.expects(:with_instructions).once.returns(chat)
    RubyLLM.expects(:chat).with(model: "openrouter/free", provider: :openrouter).returns(chat)

    res = ChatSessionManager.build_chat(link: @link)
    assert_equal chat, res
  end

  test "model_identity formata identificacao do modelo sem adivinhar" do
    texto = ChatSessionManager.model_identity(@link)
    assert_includes texto, "<modelo_em_uso: openrouter/free>"
    assert_includes texto, "<rota_em_uso: openrouter>"
  end

  test "ask despeja o cache e nao deixa user orfao quando a persistencia falha" do
    stub_chat("resposta")
    # Falha na ULTIMA etapa da transacao (touch_activity!) com as duas
    # mensagens ja inseridas: o rollback precisa desfazer o `user` e o
    # `assistant`, e o rescue precisa despejar o cache quente — sem o despejo,
    # a reidratacao leria do banco a pergunta sem resposta e duplicaria a fala.
    Conversation.any_instance.stubs(:touch_activity!).raises(ActiveRecord::StatementInvalid, "SQLITE_BUSY")

    assert_raises(ActiveRecord::StatementInvalid) do
      ChatSessionManager.ask(scope: @scope, content: "oi bot", user_id: "101", username: "joao")
    end

    conv = Conversation.active_for(@scope.key)
    assert_not_nil conv
    assert_equal 0, conv.chat_messages.count, "rollback nao pode deixar user orfao"
    assert_nil conv.reload.title, "titulo (movido para dentro da transacao) tambem volta"
    assert_nil ChatSessionManager.instance_variable_get(:@sessions)[@scope.key], "cache quente despejado"
  end

  test "sessions carrega msg_count na mesma consulta e inclui conversas sem mensagem" do
    com_msg = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: com_msg, role: "user", content: "m1", discord_user_id: @scope.user_id, discord_username: "joao")
    sem_msg = Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)

    lista = ChatSessionManager.sessions(@scope)

    assert_equal [sem_msg, com_msg], lista
    assert_equal 0, lista.first.msg_count
    assert_equal 1, lista.last.msg_count
  end

  test "sessions_total conta as conversas do escopo" do
    Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, last_active_at: 2.hours.ago)
    Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)

    assert_equal 2, ChatSessionManager.sessions_total(@scope)
  end

  test "sessions_total respeita o teto de memoria da listagem" do
    ChatSessionManager.stubs(:sessions_max).returns(1)
    Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: false, last_active_at: 2.hours.ago)
    Conversation.create!(scope: @scope.key, discord_channel_id: @scope.channel_id, active: true, last_active_at: 1.hour.ago)

    assert_equal 1, ChatSessionManager.sessions_total(@scope)
  end

  test "with_scope_lock revalida a identidade do mutex depois de um prune" do
    mutexes = ChatSessionManager.instance_variable_get(:@mutexes)
    atual = Mutex.new
    mutexes["raced_key"] = atual
    removido = Mutex.new

    # Cenario real da corrida: entre scope_mutex devolver o mutex e o
    # synchronize, o prune removeu o mutex e outra thread criou outro. A
    # primeira chamada devolve o removido; o loop precisa perceber (identidade
    # divergente sob o global) e tentar de novo com o registrado — exatamente
    # 2 chamadas: nem 1 (retry nao aconteceu) nem mais (loop cego).
    # (Mocha 3.1.0: `returns` com bloco devolve o Proc literal, por isso os
    # valores consecutivos são passados explicitamente.)
    ChatSessionManager.expects(:scope_mutex).with("raced_key").times(2)
                      .returns(removido, atual)

    resultado = ChatSessionManager.send(:with_scope_lock, "raced_key") { :bloco_executado }

    assert_equal :bloco_executado, resultado
  end

  test "all_tool_classes registra as tools de busca (websearch, platformsearch e pagefetch com a flag)" do
    ChatSessionManager.unstub(:all_tool_classes) # o setup stuba com [] — aqui provamos o metodo real
    original = ENV["ENABLE_PAGE_FETCH"]
    ENV["ENABLE_PAGE_FETCH"] = "true"
    tools = ChatSessionManager.send(:all_tool_classes)
    assert_includes tools, WebSearchTool
    assert_includes tools, PlatformSearchTool
    assert_includes tools, PageFetchTool
  ensure
    ENV["ENABLE_PAGE_FETCH"] = original
  end

  test "all_tool_classes registra as tools de watchlist (topic_add_tool, topic_list_tool, topic_remove_tool)" do
    ChatSessionManager.unstub(:all_tool_classes)
    tools = ChatSessionManager.send(:all_tool_classes)
    assert_includes tools, TopicAddTool
    assert_includes tools, TopicListTool
    assert_includes tools, TopicRemoveTool
  end


  test "ask define thread.current[:cleitin_actor] durante a chamada e limpa no ensure" do
    actor_durante_execucao = nil

    chat = mock("chat")
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:with_tool).returns(chat)
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(chat)
    chat.stubs(:ask).with do |_msg|
      actor_durante_execucao = Thread.current[:cleitin_actor]
      true
    end.returns(stub(content: "resposta ok"))
    RubyLLM.stubs(:chat).returns(chat)

    res = ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "999", username: "usuario_teste")

    assert_equal "resposta ok", res
    assert_equal({ user_id: "999", username: "usuario_teste" }, actor_durante_execucao)
    assert_nil Thread.current[:cleitin_actor], "cleitin_actor deve ser limpo apos a execucao"
  end

  test "ask limpa thread.current[:cleitin_actor] mesmo quando ocorre excecao ou resposta em branco" do
    # Caso resposta em branco (usando next)
    stub_chat("")
    res = ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "999", username: "usuario_teste")
    assert_equal ChatSessionManager::BLANK_RESPONSE_WARNING, res
    assert_nil Thread.current[:cleitin_actor], "cleitin_actor deve ser limpo apos resposta em branco"

    # Caso excecao
    chat_err = mock("chat_err")
    chat_err.stubs(:with_thinking).returns(chat_err)
    chat_err.stubs(:with_params).returns(chat_err)
    chat_err.stubs(:with_tool).returns(chat_err)
    chat_err.stubs(:with_instructions).returns(chat_err)
    chat_err.stubs(:add_message).returns(chat_err)
    chat_err.stubs(:ask).raises(RubyLLM::Error, "erro llm")
    RubyLLM.stubs(:chat).returns(chat_err)

    assert_raises(RubyLLM::Error) do
      ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "999", username: "usuario_teste")
    end
    assert_nil Thread.current[:cleitin_actor], "cleitin_actor deve ser limpo apos excecao"
  end

  test "ask define e limpa thread.current[:cleitin_turn] durante o turno" do
    turn_durante_execucao = nil

    chat = mock("chat")
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:with_tool).returns(chat)
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(chat)
    chat.stubs(:ask).with do |_msg|
      turn_durante_execucao = Thread.current[:cleitin_turn]
      true
    end.returns(stub(content: "resposta ok"))
    RubyLLM.stubs(:chat).returns(chat)

    res = ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "999", username: "usuario_teste")

    assert_equal "resposta ok", res
    assert_not_nil turn_durante_execucao, "cleitin_turn deve ser definido durante ask"
    assert_nil Thread.current[:cleitin_turn], "cleitin_turn deve ser limpo apos a execucao"
  end

  # CASO 6 — invalidação por assinatura: trocar o primary (modelo A -> B) sem
  # reiniciar e sem esperar o TTL de 30 min deve fazer o turno seguinte construir
  # B, descartando o chat quente de A. Prova de que "troca vale imediatamente".
  #
  # O setup stuba `links`/`primary` com @link (openrouter/free). Aqui trocamos o
  # primary para tencent/hy3:free entre dois `ask` e provamos que o segundo turno
  # NÃO reaproveita o chat de A (RubyLLM.chat é chamado de novo e devolve B).
  test "troca de primary A->B sem TTL faz o proximo turno construir B (invalidacao por assinatura)" do
    ConversationCompactor.stubs(:needs_compaction?).returns(false)

    link_a = Llm::ModelChain::Link.new(label: "openrouter", provider: :openrouter, model: "openrouter/free")
    link_b = Llm::ModelChain::Link.new(label: "nous", provider: :nous, model: "tencent/hy3:free",
                                       effort: "none", params: { tags: ["user=cleitin-bot"] })

    chat_a = stub_chat("resposta do A")
    chat_b = stub_chat("resposta do B")
    # Cada chat só responde UMA vez — se A vazasse para o turno B, o teste quebra.
    chat_a.expects(:ask).once.returns(stub(content: "resposta do A"))
    chat_b.expects(:ask).once.returns(stub(content: "resposta do B"))

    holder = { link: link_a }
    Llm::ModelChain.stubs(:primary).returns(holder[:link])
    Llm::ModelChain.stubs(:links).returns([holder[:link]])
    RubyLLM.stubs(:chat).returns(chat_a, chat_b)

    # Turno 1: aquece com A.
    resp1 = ChatSessionManager.ask(scope: @scope, content: "primeiro", user_id: "101", username: "joao")
    assert_equal "resposta do A", resp1
    sess = ChatSessionManager.instance_variable_get(:@sessions)[@scope.key]
    refute_nil sess, "chat de A deve estar em cache"
    assert_equal [:openrouter, "openrouter/free", nil, nil], sess[:assinatura_primary]

    # Troca o primary para B (sem restart, sem esperar TTL).
    holder[:link] = link_b
    Llm::ModelChain.stubs(:primary).returns(holder[:link])
    Llm::ModelChain.stubs(:links).returns([holder[:link]])

    # Turno 2: prepare_chat detecta assinatura divergente e descarta o quente;
    # o turno reconstrói com B.
    resp2 = ChatSessionManager.ask(scope: @scope, content: "segundo", user_id: "101", username: "joao")
    assert_equal "resposta do B", resp2
    sess2 = ChatSessionManager.instance_variable_get(:@sessions)[@scope.key]
    assert_equal [:nous, "tencent/hy3:free", "none", { tags: ["user=cleitin-bot"] }],
                 sess2[:assinatura_primary], "cache deve refletir a assinatura de B"
  end

  # CASO 2 (Sol R1-A) — snapshot único de links por turno. A configuração do
  # YAML não pode ser relida pontualmente no meio do turno: se ela mudar ENTRE
  # preparar (prepare_chat) e enviar (ask_through_chain/touch_session), o chat
  # montado para o link A NUNCA pode ser rotulado com a assinatura/elo B.
  #
  # Prova: `ask` tira UM snapshot de links no início. Qualquer re-leitura (caso
  # antigo) receberia `list_evil` e usaria `link_c`. O teste garante que o turno
  # usa o snapshot (link_a/link_b) e que `link_c` jamais é tocado — e que a
  # assinatura guardada no cache vem do snapshot, não de re-leitura.
  test "snapshot unico de links por turno: troca de config no meio nao contamina o turno" do
    ConversationCompactor.stubs(:needs_compaction?).returns(false)

    link_a = Llm::ModelChain::Link.new(label: "openrouter", provider: :openrouter, model: "openrouter/free")
    link_b = Llm::ModelChain::Link.new(label: "nous", provider: :nous, model: "tencent/hy3:free",
                                       effort: "none", params: { tags: ["user=cleitin-bot"] })
    # O que uma re-leitura (comportamento antigo) retornaria no meio do turno.
    link_c = Llm::ModelChain::Link.new(label: "evil", provider: :openrouter, model: "openrouter/OUTRO")

    list_snapshot = [link_a, link_b]
    list_evil = [link_c]

    chat_a = stub_chat("resposta do A")
    chat_b = stub_chat("resposta do B")
    chat_c = mock("chat_c")
    # link_c NUNCA deve ser usado neste turno (nem perguntado, nem construído).
    chat_c.expects(:ask).never

    Llm::ModelChain.expects(:links).once.returns(list_snapshot)
    RubyLLM.stubs(:chat).returns(chat_a, chat_b, chat_c)

    resp = ChatSessionManager.ask(scope: @scope, content: "primeiro", user_id: "101", username: "joao")
    assert_equal "resposta do A", resp, "turno deve responder com o elo do snapshot (link_a)"

    sess = ChatSessionManager.instance_variable_get(:@sessions)[@scope.key]
    refute_nil sess, "chat de A deve estar em cache"
    # A assinatura guardada vem de link_a (snapshot), NÃO de link_c (re-leitura).
    assert_equal [:openrouter, "openrouter/free", nil, nil], sess[:assinatura_primary],
                 "assinatura em cache deve vir do snapshot, não de re-leitura"
  end

  # ---------------------------------------------------------------------------
  # D2-F5a-v3 (30/08/2026) — Caracterização do entrypoint do teto (manager)
  # ---------------------------------------------------------------------------
  #
  # Estes testes travam o entrypoint: `ChatSessionManager#ask` é quem seta
  # `:cleitin_origin = :discord` e `:cleitin_conversation_scope_key = scope.key`
  # no Thread.current (DENTRO do lock de escopo) e quem os limpa no `ensure`.
  # Esse par é o que a `WebSearchTool` lê para fazer o gate F5a. Se a
  # manager não setar, o gate pula e o teto não se aplica.

  test "D2-F5a-v3: ask seta :cleitin_origin e :cleitin_conversation_scope_key durante o turno" do
    origin_durante = nil
    scope_key_durante = nil

    chat = mock("chat")
    chat.stubs(:with_thinking).returns(chat)
    chat.stubs(:with_params).returns(chat)
    chat.stubs(:with_tool).returns(chat)
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(chat)
    chat.stubs(:ask).with do |_msg|
      origin_durante = Thread.current[:cleitin_origin]
      scope_key_durante = Thread.current[:cleitin_conversation_scope_key]
      true
    end.returns(stub(content: "resposta ok"))
    RubyLLM.stubs(:chat).returns(chat)

    res = ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "101", username: "joao")

    assert_equal "resposta ok", res
    assert_equal :discord, origin_durante,
                 ":cleitin_origin deve ser :discord durante o turno (caminho do bot)"
    assert_equal @scope.key, scope_key_durante,
                 ":cleitin_conversation_scope_key deve ser scope.key durante o turno"
    # Após o ask, ensure limpou as chaves. Sem isso, o próximo turno
    # (ou outro teste no mesmo processo) veria a chave residual.
    assert_nil Thread.current[:cleitin_origin]
    assert_nil Thread.current[:cleitin_conversation_scope_key]
  end

  test "D2-F5a-v3: ask limpa :cleitin_* mesmo em excecao (rede do ensure)" do
    chat_err = mock("chat_err")
    chat_err.stubs(:with_thinking).returns(chat_err)
    chat_err.stubs(:with_params).returns(chat_err)
    chat_err.stubs(:with_tool).returns(chat_err)
    chat_err.stubs(:with_instructions).returns(chat_err)
    chat_err.stubs(:add_message).returns(chat_err)
    chat_err.stubs(:ask).raises(RubyLLM::Error, "boom")
    RubyLLM.stubs(:chat).returns(chat_err)

    assert_raises(RubyLLM::Error) do
      ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "101", username: "joao")
    end

    assert_nil Thread.current[:cleitin_conversation_scope_key],
               "ensure precisa limpar mesmo quando o turno explode"
    assert_nil Thread.current[:cleitin_origin]
  end

  test "reset! fecha conversa ativa e preserva histórico da antiga" do
    # F5a foi removida (teto morreu), mas a invariante de reset! continua:
    # conversa antiga fica com active=false e count preservado; nova ask
    # abre row nova。
    antiga = Conversation.open_for(scope: @scope.key, channel_id: @scope.channel_id, user_id: @scope.user_id)
    antiga.update!(web_search_count: 5)

    ChatSessionManager.reset!(@scope)
    assert_not antiga.reload.active, "conversa antiga deve ficar inativa após /new"
    assert_equal 5, antiga.reload.web_search_count, "count da antiga é preservado (não é zerado)"

    stub_chat("resposta")
    ChatSessionManager.ask(scope: @scope, content: "ola", user_id: "101", username: "joao")
    nova = Conversation.active_for(@scope.key)

    assert_not_nil nova, "deve existir conversa ativa após ask"
    assert_not_equal antiga.id, nova.id, "deve ser uma row nova, não a antiga reaberta"
  end
end

