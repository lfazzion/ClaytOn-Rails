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
require_relative "../../app/services/discord_bot_service"

class DiscordBotServiceTest < ActiveSupport::TestCase
  setup do
    ChatSessionManager.stubs(:all_tool_classes).returns([])
  end

  def mock_event(user_id: "123", channel_id: "456", content: "pergunta", username: "joao", private: false)
    user = stub(id: user_id, display_name: username, username: username, bot_account?: false)
    channel = stub(id: channel_id, private?: private, start_typing: nil)
    message = stub(content: content)
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
end
