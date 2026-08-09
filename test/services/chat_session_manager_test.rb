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

  test "cleanup_expired remove sessoes expiradas e limpa mutexes orfaos" do
    sessions = ChatSessionManager.instance_variable_get(:@sessions)
    mutexes = ChatSessionManager.instance_variable_get(:@mutexes)

    sessions["expired_key"] = { chat: mock("chat"), expires_at: 1.hour.ago }
    sessions["active_key"] = { chat: mock("chat"), expires_at: 30.minutes.from_now }
    mutexes["expired_key"] = Mutex.new
    mutexes["active_key"] = Mutex.new

    ChatSessionManager.cleanup_expired

    assert_nil sessions["expired_key"]
    assert_not_nil sessions["active_key"]
    assert_nil mutexes["expired_key"]
    assert_not_nil mutexes["active_key"]
  end

  test "build_chat constroi objeto RubyLLM::Chat com instrucoes e ferramentas" do
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
end
