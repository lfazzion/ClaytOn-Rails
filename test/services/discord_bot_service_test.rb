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
require_relative "../../app/services/response_attachment_builder"
require_relative "../../app/services/discord_bot_service"

class DiscordBotServiceTest < ActiveSupport::TestCase
  setup do
    ChatSessionManager.stubs(:all_tool_classes).returns([])
  end

  def mock_event(user_id: "123", channel_id: "456", content: "pergunta", username: "joao", private: false, attachments: [], parent_id: nil)
    user = stub(id: user_id, display_name: username, username: username, bot_account?: false)
    channel = stub(id: channel_id, private?: private, start_typing: nil, parent_id: parent_id)
    message = stub(content: content, attachments: attachments)
    event = mock("event")
    event.stubs(:user).returns(user)
    event.stubs(:channel).returns(channel)
    event.stubs(:message).returns(message)
    event
  end

  test "handle_message ignora content vazio" do
    event = mock_event(content: "   ")
    event.expects(:respond).never
    DiscordBotService.handle_message(event)
  end

  test "handle_message chama ChatSessionManager.ask e responde com o texto retornado" do
    event = mock_event(content: "pergunta")
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: "pergunta", user_id: "123", username: "joao")
                      .returns("resposta do bot")

    event.expects(:respond).with("resposta do bot")
    DiscordBotService.handle_message(event)
  end

  test "handle_message trata RateLimitError caindo no elo fallback da cadeia" do
    event = mock_event(content: "pergunta")
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    # DiscordBotService delega a resposta ao ChatSessionManager.ask. Se a cadeia inteira
    # esgotar ou estourar um RateLimitError durante ask, o bot captura a exceção
    # (StandardError) e envia a mensagem amigável de erro para o usuário sem derrubar o processo.
    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: "pergunta", user_id: "123", username: "joao")
                      .raises(RubyLLM::RateLimitError, "rate limit")

    event.expects(:respond).with("⚠️ Erro ao processar. Tente novamente.")
    DiscordBotService.handle_message(event)
  end

  test "handle_message trata StandardError" do
    event = mock_event(content: "pergunta")
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    ChatSessionManager.expects(:ask).raises(StandardError, "erro generico")

    event.expects(:respond).with("⚠️ Erro ao processar. Tente novamente.")
    DiscordBotService.handle_message(event)
  end

  # --- run_command: despacho e captura de erro ---

  test "run_command executa /new e devolve o texto de reset" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    ChatSessionManager.expects(:reset!).with(scope).returns(nil)

    texto = DiscordBotService.run_command(Discord::CommandRouter.build("new"), scope)

    assert_includes texto, "🆕 Nova conversa iniciada."
    assert_includes texto, "`/sessions` mostra a lista"
  end

  test "run_command despacha /sessions para a resposta de listagem" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    pagina = ChatSessionManager::Page.new(conversations: [], first_index: 1, number: 1,
                                          total_pages: 1, total: 0)
    ChatSessionManager.stubs(:page).with(scope, 1).returns(pagina)

    texto = DiscordBotService.run_command(Discord::CommandRouter.build("sessions"), scope)

    assert_equal "Nenhuma conversa por aqui ainda. É só começar a falar.", texto
  end

  test "run_command captura erro do comando e devolve mensagem generica" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    ChatSessionManager.expects(:reset!).with(scope).raises(StandardError, "boom")

    texto = DiscordBotService.run_command(Discord::CommandRouter.build("new"), scope)

    assert_equal "⚠️ Erro ao processar o comando.", texto
  end

  # --- sessions_response e pagina_inexistente ---

  test "sessions_response monta a listagem com titulo, marca e contagem sem N+1" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: true, title: "Titulo da conversa", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "oi",
                        discord_user_id: "123", discord_username: "joao")
    ChatMessage.create!(conversation: conv, role: "assistant", content: "ola")

    texto = DiscordBotService.send(:sessions_response, scope, 1)

    assert_includes texto, "**Conversas anteriores** (página 1 de 1, 1 no total)"
    assert_includes texto, "**1.** Titulo da conversa *(em andamento)* — há 2 horas, 2 mensagens"
    assert_includes texto, "Use `/resume <número>` para continuar, `/delete <número>` para apagar."
  end

  test "sessions_response sem conversas avisa que ainda nao ha historico" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    texto = DiscordBotService.send(:sessions_response, scope, 1)

    assert_equal "Nenhuma conversa por aqui ainda. É só começar a falar.", texto
  end

  test "sessions_response com pagina inexistente devolve a mensagem de faixa" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: false, last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "oi",
                        discord_user_id: "123", discord_username: "joao")

    texto = DiscordBotService.send(:sessions_response, scope, 99)

    assert_equal "Essa página não existe. Só existe 1 página.", texto
  end

  test "pagina_inexistente informa o numero de paginas existentes" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    25.times do |i|
      conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                  active: false, title: "c#{i}", last_active_at: (i + 1).hours.ago)
      ChatMessage.create!(conversation: conv, role: "user", content: "m#{i}",
                          discord_user_id: "123", discord_username: "joao")
    end

    texto = DiscordBotService.send(:pagina_inexistente, scope)

    assert_equal "Essa página não existe. Existem 2 páginas.", texto
  end

  # --- resume_response ---

  test "resume_response sem indice mostra a primeira pagina de sessoes" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    texto = DiscordBotService.send(:resume_response, scope, nil)

    assert_equal "Nenhuma conversa por aqui ainda. É só começar a falar.", texto
  end

  test "resume_response devolve mensagem de retomada da conversa" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = stub(title: "meu titulo")
    ChatSessionManager.stubs(:resume!).with(scope, 2).returns(conv)

    texto = DiscordBotService.send(:resume_response, scope, 2)

    assert_equal "▶️ Voltamos para: **meu titulo**. Pode continuar de onde parou.", texto
  end

  test "resume_response fora da faixa informa o tamanho da lista" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    c1 = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                              active: false, title: "c1", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: c1, role: "user", content: "m1",
                        discord_user_id: "123", discord_username: "joao")
    c2 = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                              active: true, title: "c2", last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: c2, role: "user", content: "m2",
                        discord_user_id: "123", discord_username: "joao")

    texto = DiscordBotService.send(:resume_response, scope, 99)

    assert_equal "Não existe conversa 99. A lista vai até 2.", texto
  end

  test "resume_response sem nenhuma conversa avisa para comecar a falar" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    ChatSessionManager.stubs(:resume!).with(scope, 1).returns(nil)

    texto = DiscordBotService.send(:resume_response, scope, 1)

    assert_equal "Não encontrei nenhuma conversa por aqui ainda. É só começar a falar.", texto
  end

  # --- delete_response: as duas etapas ---

  test "delete_response sem conversas avisa que nao ha o que apagar" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    texto = DiscordBotService.send(:delete_response, scope, 1, false)

    assert_equal "Nenhuma conversa para apagar por aqui.", texto
  end

  test "delete_response fora da faixa informa o tamanho da lista" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: false, title: "c", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "m",
                        discord_user_id: "123", discord_username: "joao")

    texto = DiscordBotService.send(:delete_response, scope, 5, false)

    assert_equal "Não existe conversa 5. A lista vai até 1.", texto
  end

  test "delete_response recusa a conversa em andamento" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: true, title: "ativa", last_active_at: 1.hour.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "m",
                        discord_user_id: "123", discord_username: "joao")

    texto = DiscordBotService.send(:delete_response, scope, 1, true)

    assert_equal "A #1 é a conversa em andamento. Dê `/new` primeiro para encerrá-la, " \
                 "e então ela pode ser apagada.", texto
  end

  test "delete_response sem confirmacao mostra a previa e pede o sim" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: false, title: "antiga", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "m1",
                        discord_user_id: "123", discord_username: "joao")
    ChatMessage.create!(conversation: conv, role: "assistant", content: "m2")

    texto = DiscordBotService.send(:delete_response, scope, 1, false)

    assert_includes texto, "Apagar **antiga**? 2 mensagens, última atividade há 2 horas."
    assert_includes texto, "Confirme com `!delete 1 sim`"
  end

  test "delete_response com confirmacao apaga a conversa de verdade" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    conv = Conversation.create!(scope: scope.key, discord_channel_id: scope.channel_id,
                                active: false, title: "antiga", last_active_at: 2.hours.ago)
    ChatMessage.create!(conversation: conv, role: "user", content: "m1",
                        discord_user_id: "123", discord_username: "joao")

    texto = DiscordBotService.send(:delete_response, scope, 1, true)

    assert_equal "🗑️ Apagada: **antiga** (1 mensagens)", texto
    assert_raise(ActiveRecord::RecordNotFound) { conv.reload }
  end

  # --- exclusao_concluida ---

  test "exclusao_concluida monta a mensagem com titulo e contagem" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    resultado = ChatSessionManager::Apagada.new(title: "titulo", message_count: 3)

    texto = DiscordBotService.send(:exclusao_concluida, scope, resultado, 1)

    assert_equal "🗑️ Apagada: **titulo** (3 mensagens)", texto
  end

  test "exclusao_concluida marca conversa da sala quando o escopo e compartilhado" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "999")
    resultado = ChatSessionManager::Apagada.new(title: "titulo", message_count: 3)

    texto = DiscordBotService.send(:exclusao_concluida, scope, resultado, 1)

    assert_equal "🗑️ Apagada: **titulo** (3 mensagens) (conversa da sala)", texto
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  test "exclusao_concluida cobre os simbolos de status do destroy" do
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    assert_equal "Nenhuma conversa para apagar por aqui.",
                 DiscordBotService.send(:exclusao_concluida, scope, :lista_vazia, 1)
    assert_equal "Não existe conversa 2. Use `/sessions` para ver a lista.",
                 DiscordBotService.send(:exclusao_concluida, scope, :fora_da_faixa, 2)
    assert_equal "A #3 é a conversa em andamento. Dê `/new` primeiro para encerrá-la, " \
                 "e então ela pode ser apagada.",
                 DiscordBotService.send(:exclusao_concluida, scope, :em_andamento, 3)
  end

  # --- handle_slash_command e respond_deferred ---

  test "handle_slash_command defere, executa o comando e responde por edit_response" do
    event = mock("event")
    event.stubs(:user).returns(stub(id: "123"))
    event.stubs(:channel).returns(stub(id: "456", parent_id: nil))
    event.stubs(:options).returns({})
    event.expects(:defer).with(ephemeral: false)
    event.expects(:edit_response).with(content: "🆕 Nova conversa iniciada. A anterior ficou guardada — " \
                                                "`/sessions` mostra a lista e `/resume <número>` volta para ela.")
    definition = Discord::CommandRouter::SLASH_COMMANDS.find { |d| d[:name] == "new" }
    ChatSessionManager.stubs(:reset!).returns(nil)

    DiscordBotService.handle_slash_command(event, definition)
  end

  test "handle_slash_command captura erro e responde a mensagem generica" do
    event = mock("event")
    event.stubs(:user).returns(stub(id: "123"))
    event.stubs(:channel).returns(stub(id: "456", parent_id: nil))
    event.stubs(:options).returns({})
    event.expects(:defer).with(ephemeral: false)
    event.expects(:edit_response).with(content: "⚠️ Erro ao processar o comando.")
    definition = Discord::CommandRouter::SLASH_COMMANDS.find { |d| d[:name] == "delete" }
    Discord::CommandRouter.stubs(:build).raises(StandardError, "boom")

    DiscordBotService.handle_slash_command(event, definition)
  end

  test "respond_deferred com resposta curta so edita a interacao deferida" do
    event = mock("event")
    event.expects(:edit_response).with(content: "resposta")
    event.expects(:send_message).never

    DiscordBotService.send(:respond_deferred, event, "resposta")
  end

  test "respond_deferred quebra resposta longa em edit_response e follow-ups" do
    event = mock("event")
    event.expects(:edit_response).with(content: "a" * 2000)
    event.expects(:send_message).with(content: "a" * 500, ephemeral: false)

    DiscordBotService.send(:respond_deferred, event, "a" * 2500)
  end

  # --- should_handle?, handle_mention e text_command? ---

  test "should_handle? aceita mensagem direta" do
    assert DiscordBotService.should_handle?(mock_event(private: true))
  end

  test "should_handle? aceita canal aberto configurado" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"

    assert DiscordBotService.should_handle?(mock_event(channel_id: "999", private: false))
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  test "should_handle? aceita comando de texto e recusa mensagem comum fora de DM" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = ""

    assert DiscordBotService.should_handle?(mock_event(private: false, content: "!sessions"))
    assert_not DiscordBotService.should_handle?(mock_event(private: false, content: "pergunta normal"))
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  test "handle_mention nao reprocessa o que o bot.message ja atende" do
    event = mock_event(private: true)

    DiscordBotService.expects(:handle_message).never
    DiscordBotService.handle_mention(event)
  end

  test "handle_mention processa mensagem fora dos filtros do bot.message" do
    event = mock_event(private: false, content: "pergunta")

    DiscordBotService.expects(:handle_message).with(event)
    DiscordBotService.handle_mention(event)
  end

  test "text_command? so reconhece comando que existe" do
    assert DiscordBotService.send(:text_command?, mock_event(content: "!resume 3"))
    assert_not DiscordBotService.send(:text_command?, mock_event(content: "!play"))
    assert_not DiscordBotService.send(:text_command?, mock_event(content: "texto normal"))
  end

  # === Missão thread-heranca (plano v2): invariantes 1-7 ===

  # Invariante 1: thread cujo PAI está em DISCORD_OPEN_CHANNEL_IDS é atendida
  # sem menção; o escopo é compartilhado com a IDENTIDADE da thread (não do pai).
  test "thread em canal aberto e atendida e usa identidade da thread (invariante 1)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    event = mock_event(channel_id: "777", parent_id: "999", private: false, content: "pergunta")

    assert DiscordBotService.should_handle?(event)

    scope = Discord::SessionScope.for(user_id: "123", channel_id: "777", open_channel_id: "999")
    assert scope.shared
    assert_equal "c:777", scope.key
    assert_equal "777", scope.channel_id
    assert_nil scope.user_id
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # Invariante 2: canal normal (não aberto) — open_channel_id == channel_id.
  test "canal normal mantem open_channel_id igual a channel_id (invariante 2)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "456"
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456", open_channel_id: nil)
    assert_equal "456", scope.open_channel_id
    assert_equal "456", scope.channel_id
    assert_equal "c:456", Discord::SessionScope.for(user_id: "123", channel_id: "456", open_channel_id: "456").key
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # Invariante 3: thread de canal NÃO aberto exige menção/!; escopo individual.
  test "thread em canal nao aberto exige mencao e tem escopo individual (invariante 3)" do
    event = mock_event(channel_id: "777", parent_id: "888", private: false, content: "pergunta")
    assert_not DiscordBotService.should_handle?(event)

    scope = Discord::SessionScope.for(user_id: "123", channel_id: "777", open_channel_id: "888")
    assert_not scope.shared
    assert_equal "u:123:c:777", scope.key
    assert_equal "777", scope.channel_id
  end

  # Invariante 4: parent_id nil OU 0 não herda — usa o próprio id, sem crash.
  test "thread com parent_id nil ou 0 nao herda e nao quebra (invariante 4)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    nil_event = mock_event(channel_id: "777", parent_id: nil, private: false, content: "pergunta")
    zero_event = mock_event(channel_id: "777", parent_id: 0, private: false, content: "pergunta")

    # Em nenhum dos dois casos a thread (id 777) herda o canal aberto 999 (nil/0 = inválido).
    assert_not DiscordBotService.should_handle?(nil_event)
    assert_not DiscordBotService.should_handle?(zero_event)

    # O helper efetivo cai no próprio id em ambos os casos.
    assert_equal "777", DiscordBotService.send(:effective_open_channel_id, nil_event.channel)
    assert_equal "777", DiscordBotService.send(:effective_open_channel_id, zero_event.channel)
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # Invariante 5: /new na thread aberta usa o MESMO escopo c:<thread_id> de mensagem e !.
  test "slash /new na thread aberta usa o escopo da thread (invariante 5)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    event = mock("event")
    event.stubs(:user).returns(stub(id: "123"))
    event.stubs(:channel).returns(stub(id: "777", parent_id: "999"))
    event.stubs(:options).returns({})
    event.expects(:defer).with(ephemeral: false)
    event.expects(:edit_response).with(content: "🆕 Nova conversa iniciada. Como este canal é compartilhado, ela vale para todo mundo. A anterior ficou guardada — " \
                                                "`/sessions` mostra a lista e `/resume <número>` volta para ela.")
    definition = Discord::CommandRouter::SLASH_COMMANDS.find { |d| d[:name] == "new" }
    ChatSessionManager.stubs(:reset!).returns(nil)

    DiscordBotService.handle_slash_command(event, definition)
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # Invariante 6: DM continua individual; comando ! continua; mute prefix // silencia na thread.
  test "DM individual, comando ! e mute // continuam funcionando na thread (invariante 6)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    dm_event = mock_event(private: true)
    assert DiscordBotService.should_handle?(dm_event)

    bang_event = mock_event(channel_id: "777", parent_id: "888", private: false, content: "!sessions")
    assert DiscordBotService.should_handle?(bang_event)

    thread_event = mock_event(channel_id: "777", parent_id: "999", private: false, content: "// assunto humano")
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "777", open_channel_id: "999")
    assert scope.shared
    assert Discord::SessionScope.muted?(thread_event.message.content)
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # Invariante 7: a chave da thread aberta é diferente da chave do canal pai.
  test "chave da thread aberta difere da chave do canal pai (invariante 7)" do
    ENV["DISCORD_OPEN_CHANNEL_IDS"] = "999"
    parent = Discord::SessionScope.for(user_id: "123", channel_id: "999", open_channel_id: "999")
    thread = Discord::SessionScope.for(user_id: "123", channel_id: "777", open_channel_id: "999")
    assert_equal "c:999", parent.key
    assert_equal "c:777", thread.key
    refute_equal parent.key, thread.key
  ensure
    ENV.delete("DISCORD_OPEN_CHANNEL_IDS")
  end

  # --- time_ago ---

  test "time_ago formata em portugues" do
    assert_equal "há pouco", DiscordBotService.send(:time_ago, nil)
    assert_equal "há pouco", DiscordBotService.send(:time_ago, "")
    assert_equal "agora há pouco", DiscordBotService.send(:time_ago, 30.seconds.ago)
    assert_equal "há 1 minuto", DiscordBotService.send(:time_ago, 1.minute.ago)
    assert_equal "há 5 minutos", DiscordBotService.send(:time_ago, 5.minutes.ago)
    assert_equal "há 1 hora", DiscordBotService.send(:time_ago, 1.hour.ago)
    assert_equal "há 2 horas", DiscordBotService.send(:time_ago, 2.hours.ago)
    assert_equal "há 3 dias", DiscordBotService.send(:time_ago, 3.days.ago)
  end

  # --- anexos de arquivos ---

  test "handle_message com mais de um anexo responde aviso educado" do
    att1 = stub(filename: "a.txt")
    att2 = stub(filename: "b.txt")
    event = mock_event(attachments: [att1, att2])

    event.expects(:respond).with("Envie apenas um arquivo por mensagem.")
    ChatSessionManager.expects(:ask).never

    DiscordBotService.handle_message(event)
  end

  # B4 (revisão Opus): anexo NÃO-suportado não bloqueia a pergunta — o fluxo
  # volta ao normal (sem processar) e a pergunta é respondida. Antes do fix,
  # print.png + pergunta virava "Formato de arquivo não suportado" e descartava.
  test "handle_message ignora anexo nao suportado e responde a pergunta (B4)" do
    att = stub(filename: "print.png")
    event = mock_event(content: "por que isso da erro?", attachments: [att])
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")

    AttachmentProcessor.expects(:process).never
    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: "por que isso da erro?", user_id: "123", username: "joao")
                      .returns("resposta normal")

    event.expects(:respond).with("resposta normal")

    DiscordBotService.handle_message(event)
  end

  test "handle_message responde erro do process para anexo suportado que falha" do
    att = stub(filename: "texto.txt")
    event = mock_event(attachments: [att])

    AttachmentProcessor.expects(:process).with(att, "pergunta").returns(
      AttachmentProcessor::Result.new(success: false, error_message: "Não consegui baixar o arquivo.")
    )
    event.expects(:respond).with("Não consegui baixar o arquivo.")
    ChatSessionManager.expects(:ask).never

    DiscordBotService.handle_message(event)
  end

  # #4 (2ª rodada): filename com NUL levanta ArgumentError no File.extname do
  # filtro de suportados — a rede final do handle_message responde educado,
  # nunca deixa o usuário no vácuo.
  test "handle_message com filename contendo NUL responde erro educado (#4)" do
    att = stub(filename: "rel\u0000atorio.txt")
    event = mock_event(attachments: [att])

    AttachmentProcessor.expects(:process).never
    ChatSessionManager.expects(:ask).never
    event.expects(:respond).with("⚠️ Erro ao processar. Tente novamente.")

    DiscordBotService.handle_message(event)
  end

  test "handle_message com anexo valido passa o frame para ChatSessionManager.ask e ignora comando de texto" do
    att = stub(filename: "doc.txt")
    event = mock_event(content: "!help", attachments: [att])
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    frame_content = "!help\n\n[ARQUIVO nome=\"doc.txt\"]\nConteudo\n[/ARQUIVO]"

    AttachmentProcessor.expects(:process).with(att, "!help").returns(
      AttachmentProcessor::Result.new(success: true, content: frame_content, truncated: false, filename: "doc.txt")
    )
    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: frame_content, user_id: "123", username: "joao")
                      .returns("Resposta da LLM sobre o arquivo")

    event.expects(:respond).with("Resposta da LLM sobre o arquivo")

    DiscordBotService.handle_message(event)
  end

  test "handle_message com anexo truncado por chars adiciona aviso com numero (B3)" do
    att = stub(filename: "grande.txt")
    event = mock_event(content: "analise", attachments: [att])
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    frame_content = "analise\n\n[ARQUIVO nome=\"grande.txt\"]\nConteudo\n[truncado em 30000 chars]\n[/ARQUIVO]"

    AttachmentProcessor.expects(:process).with(att, "analise").returns(
      AttachmentProcessor::Result.new(success: true, content: frame_content, truncated: true,
                                      truncated_reason: :chars, filename: "grande.txt")
    )
    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: frame_content, user_id: "123", username: "joao")
                      .returns("Analise feita")

    event.expects(:respond).with("Analise feita\n\n⚠️ *(O arquivo foi truncado em 30000 caracteres.)*")

    DiscordBotService.handle_message(event)
  end

  # B3 (revisão Opus): corte por PÁGINAS no sidecar não pode virar um aviso de
  # N caracteres (número errado) — o aviso é genérico de leitura parcial.
  test "handle_message com anexo truncado por paginas usa aviso honesto (B3)" do
    att = stub(filename: "slides.pdf")
    event = mock_event(content: "conclusao", attachments: [att])
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    frame_content = "conclusao\n\n[ARQUIVO nome=\"slides.pdf\"]\nSlide 1\n[arquivo longo demais — o início foi lido]\n[/ARQUIVO]"

    AttachmentProcessor.expects(:process).with(att, "conclusao").returns(
      AttachmentProcessor::Result.new(success: true, content: frame_content, truncated: true,
                                      truncated_reason: :pages, filename: "slides.pdf")
    )
    ChatSessionManager.expects(:ask)
                      .with(scope: scope, content: frame_content, user_id: "123", username: "joao")
                      .returns("A conclusão está na parte que não li")

    event.expects(:respond).with("A conclusão está na parte que não li\n\n⚠️ *(O arquivo é longo demais e foi lido parcialmente.)*")

    DiscordBotService.handle_message(event)
  end

  # --- resposta LLM como anexo ---

  test "handle_message quando builder devolve nil envia resposta em chunks inline" do
    event = mock_event(content: "pergunta")
    scope = Discord::SessionScope.for(user_id: "123", channel_id: "456")
    texto = "resposta curta"

    ChatSessionManager.expects(:ask).returns(texto)
    ResponseAttachmentBuilder.expects(:build).with(texto).returns(nil)
    event.expects(:respond).with("resposta curta")
    event.channel.expects(:send_file).never

    DiscordBotService.handle_message(event)
  end

  test "handle_message quando builder devolve Result envia por send_file com Tempfile e nao chama respond_in_chunks" do
    event = mock_event(content: "pergunta")
    texto = "```python\n" + ("  print('hello')\n" * 30) + "```"
    result = ResponseAttachmentBuilder::Result.new(
      caption: "Aqui esta o arquivo.",
      filename: "codigo.py",
      content: "  print('hello')\n" * 30
    )

    ChatSessionManager.expects(:ask).returns(texto)
    ResponseAttachmentBuilder.expects(:build).with(texto).returns(result)

    event.expects(:respond).never
    event.channel.expects(:send_file).with do |file, kwargs|
      file.is_a?(Tempfile) && kwargs[:caption] == "Aqui esta o arquivo." && kwargs[:filename] == "codigo.py"
    end.returns(true)

    DiscordBotService.handle_message(event)
  end

  test "handle_message quando send_file levanta erro faz fallback para respond_in_chunks" do
    event = mock_event(content: "pergunta")
    texto = "```python\n" + ("  print('hello')\n" * 30) + "```"
    result = ResponseAttachmentBuilder::Result.new(
      caption: "Aqui esta o arquivo.",
      filename: "codigo.py",
      content: "  print('hello')\n" * 30
    )

    ChatSessionManager.expects(:ask).returns(texto)
    ResponseAttachmentBuilder.expects(:build).with(texto).returns(result)

    # raise como COMPORTAMENTO da expectativa (.raises), nunca dentro do bloco
    # do .with: o bloco é o matcher do Mocha — um raise ali propaga o erro mas
    # não registra a invocação ("invoked never") e a expectativa fica
    # insatisfeita mesmo com o fallback funcionando.
    event.channel.expects(:send_file).raises(StandardError, "Discord API error")
    event.expects(:respond).with(texto)

    DiscordBotService.handle_message(event)
  end

  test "handle_message com caption_resto envia o excedente como mensagens apos o arquivo (B2)" do
    event = mock_event(content: "pergunta")
    texto = "texto da resposta"
    result = ResponseAttachmentBuilder::Result.new(
      caption: "explicacao…", caption_resto: "continuacao da explicacao",
      filename: "codigo.py", content: "code", kind: :code
    )

    ChatSessionManager.expects(:ask).returns(texto)
    ResponseAttachmentBuilder.expects(:build).with(texto).returns(result)

    event.channel.expects(:send_file).returns(true)
    # o excedente do caption vai como mensagem (respond_in_chunks) — nada se perde
    event.expects(:respond).with("continuacao da explicacao")

    DiscordBotService.handle_message(event)
  end

  test "answer com prosa truncada e arquivo prefixa o aviso no caption (M3)" do
    att = stub(filename: "grande.txt")
    event = mock_event(content: "analise", attachments: [att])
    frame = "analise\n\n[ARQUIVO nome=\"grande.txt\"]\nConteudo\n[/ARQUIVO]"
    AttachmentProcessor.expects(:process).with(att, "analise").returns(
      AttachmentProcessor::Result.new(success: true, content: frame, truncated: true,
                                      truncated_reason: :chars, filename: "grande.txt")
    )

    texto = "prosa longa"
    texto_com_aviso = "#{texto}\n\n⚠️ *(O arquivo foi truncado em 30000 caracteres.)*"
    result = ResponseAttachmentBuilder::Result.new(
      caption: "📄 preview…", filename: "resposta.md", content: texto_com_aviso, kind: :prose
    )

    ChatSessionManager.expects(:ask).returns(texto)
    ResponseAttachmentBuilder.expects(:build).with(texto_com_aviso).returns(result)

    # M3: o aviso aparece PREFIXADO no caption (e nao enterrado dentro do .md)
    event.channel.expects(:send_file).with do |_file, kwargs|
      kwargs[:caption].start_with?("⚠️")
    end.returns(true)

    DiscordBotService.handle_message(event)
  end

  test "send_attachment_with_fallback remove o Tempfile apos sucesso e apos erro" do
    event = mock_event(content: "pergunta")
    texto = "conteudo longo"
    result = ResponseAttachmentBuilder::Result.new(
      caption: "caption",
      filename: "codigo.py",
      content: "code"
    )

    tempfile_path_sucesso = nil
    event.channel.expects(:send_file).with do |file, _kwargs|
      tempfile_path_sucesso = file.path
      true
    end.returns(true)

    DiscordBotService.send(:send_attachment_with_fallback, event, texto, result)
    refute_nil tempfile_path_sucesso
    refute File.exist?(tempfile_path_sucesso)

    tempfile_path_erro = nil
    # Mesma regra do teste acima: o bloco do .with só CAPTURA (matcher); o
    # erro vem de .raises como comportamento, senão a invocação não é
    # registrada e a expectativa falha mesmo com o fallback correto.
    event.channel.expects(:send_file).with do |file, _kwargs|
      tempfile_path_erro = file.path
      true
    end.raises(StandardError, "fail")
    event.expects(:respond).with(texto)

    DiscordBotService.send(:send_attachment_with_fallback, event, texto, result)
    refute_nil tempfile_path_erro
    refute File.exist?(tempfile_path_erro)
  end

  # --- start: encerramento rapido quando bot.run termina (CORRECAO 1) ---

  test "start termina rapidamente quando bot.run retorna e libera a cleanup_thread" do
    bot_instance = mock("bot")
    bot_instance.stubs(:message)
    bot_instance.stubs(:ready)
    bot_instance.stubs(:mention)
    bot_instance.stubs(:stop)
    bot_instance.stubs(:run)

    DiscordBotService.stubs(:register_commands)
    DiscordBotService.stubs(:attach_command_handlers)
    DiscordBotService.stubs(:should_handle?).returns(false)
    Discordrb::Bot.expects(:new).returns(bot_instance)

    inicio = Time.now
    DiscordBotService.start
    duracao = Time.now - inicio

    assert duracao < 2, "start devia terminar rapido, levou #{duracao}s"
  end

  test "start propaga excecao sem mascarar caso a configuracao do bot falhe" do
    Discordrb::Bot.expects(:new).raises(StandardError, "falha de inicializacao do bot")

    err = assert_raises(StandardError) do
      DiscordBotService.start
    end

    assert_equal "falha de inicializacao do bot", err.message
  end
end
