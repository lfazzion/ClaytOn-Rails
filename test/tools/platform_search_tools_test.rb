# frozen_string_literal: true

require "test_helper"
# Rails autoload não resolve arquivo com várias classes de tool — sem estes dois
# requires o teste morre em `NameError: uninitialized constant`.
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/platform_search_tools"

class PlatformSearchToolsTest < ActiveSupport::TestCase
  VIDEOS = [
    { "url" => "https://www.youtube.com/watch?v=abc", "title" => "Aula",
      "channel" => "Canal", "duration_seconds" => 600 }
  ].freeze

  THREADS = [
    { "url" => "https://www.reddit.com/r/ruby/comments/aaa/t/", "title" => "Titulo",
      "subreddit" => "ruby", "score" => 54, "comments" => 15 }
  ].freeze

  test "busca no youtube devolve os itens do canal" do
    Fetcher::Channels::Youtube.expects(:search).with(query: "ruby 4", limit: 10).returns(VIDEOS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "youtube")

    assert_equal :success, result[:status]
    assert_equal "youtube", result[:data][:platform]
    assert_equal 1, result[:data][:count]
    assert_equal "https://www.youtube.com/watch?v=abc", result[:data][:results].first["url"]
  end

  test "busca no reddit devolve os itens do canal" do
    Fetcher::Channels::Reddit.expects(:search).with(query: "ruby 4", limit: 10).returns(THREADS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "reddit")

    assert_equal :success, result[:status]
    assert_equal "reddit", result[:data][:platform]
    assert_equal 54, result[:data][:results].first["score"]
  end

  test "nome de plataforma com maiuscula e espaco ainda casa" do
    Fetcher::Channels::Youtube.expects(:search).returns([])

    assert_equal :success, PlatformSearchTool.new.execute(query: "x", platform: " YouTube ")[:status]
  end

  # Adivinhar a plataforma entregaria resultado de outro lugar como se fosse do
  # pedido. O erro nomeia as válidas para o modelo poder repetir a chamada certo.
  test "plataforma desconhecida vira erro nomeado, sem chamar canal nenhum" do
    Fetcher::Channels::Youtube.expects(:search).never
    Fetcher::Channels::Reddit.expects(:search).never

    result = PlatformSearchTool.new.execute(query: "x", platform: "tiktok")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "tiktok"
    assert_includes result[:reason], "youtube"
    assert_includes result[:reason], "reddit"
  end

  test "query vazia vira erro antes de tocar no canal" do
    Fetcher::Channels::Youtube.expects(:search).never

    result = PlatformSearchTool.new.execute(query: "   ", platform: "youtube")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "query"
  end

  test "limite acima do teto e abaixo do piso sao clampados" do
    Fetcher::Channels::Youtube.expects(:search).with(query: "x", limit: PlatformSearchTool::MAX_LIMIT).returns([])
    assert_equal :success, PlatformSearchTool.new.execute(query: "x", platform: "youtube", limit: 999)[:status]

    Fetcher::Channels::Reddit.expects(:search).with(query: "x", limit: PlatformSearchTool::MIN_LIMIT).returns([])
    assert_equal :success, PlatformSearchTool.new.execute(query: "x", platform: "reddit", limit: 0)[:status]
  end

  # Lista vazia aqui seria lida pelo modelo como "não existe nada sobre isso", e
  # ele responderia isso ao usuário. O erro precisa dizer QUAL domínio renovar.
  test "sessao expirada vira erro nomeando o dominio, nunca lista vazia" do
    Fetcher::Channels::Reddit.stubs(:search).raises(Fetcher::CookieJar::Expired.new("reddit.com"))

    result = PlatformSearchTool.new.execute(query: "x", platform: "reddit")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "reddit.com"
    assert_includes result[:reason], "sessão"
  end

  test "rate limit do canal vira erro nomeado, nao lista vazia" do
    Fetcher::Channels::Reddit.stubs(:search).raises(Fetcher::Channels::Reddit::RateLimited.new("old.reddit.com"))

    result = PlatformSearchTool.new.execute(query: "x", platform: "reddit")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "old.reddit.com"
  end

  test "falha inesperada nao sobe como excecao para o chat" do
    Fetcher::Channels::Youtube.stubs(:search).raises(RuntimeError, "boom")

    result = PlatformSearchTool.new.execute(query: "x", platform: "youtube")

    assert_equal :error, result[:status]
    refute_includes result[:reason], "boom", "mensagem crua de exceção não vai para o modelo"
  end

  # Busca legítima que não achou nada é sucesso com zero itens — é resposta, não
  # falha. O que não pode é falha silenciosa virar lista vazia (testes acima).
  test "zero resultados com sessao boa e sucesso, nao erro" do
    Fetcher::Channels::Youtube.expects(:search).returns([])

    result = PlatformSearchTool.new.execute(query: "assunto inexistente", platform: "youtube")

    assert_equal :success, result[:status]
    assert_equal 0, result[:data][:count]
  end

  test "falta de parametro obrigatorio e erro, nao ArgumentError" do
    result = PlatformSearchTool.new.execute(query: "x")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "platform"
  end

  # A tool convive com a web_search: sem a fronteira escrita na description, o
  # modelo escolhe a errada e devolve link de blog quando o usuário pediu thread.
  test "a description ensina a fronteira com a web_search" do
    desc = PlatformSearchTool.description.to_s

    assert_includes desc, "web_search"
    assert_includes desc, "YouTube"
    assert_includes desc, "Reddit"
  end

  # ---------------------------------------------------------------------------
  # X (Twitter) — aqui `query` NÃO é assunto, é perfil. Busca por assunto no X
  # não existe neste bot, e o modelo não pode ficar adivinhando qual dos dois é.
  # ---------------------------------------------------------------------------

  POSTS = [
    { "url" => "https://x.com/jack/status/1001", "text" => "post", "author" => "Jack",
      "screen_name" => "jack", "created_at" => "2026-08-05T12:00:00Z",
      "likes" => 1234, "retweets" => nil, "replies" => nil }
  ].freeze

  test "no x a query e o perfil, e o roteamento vai para timeline" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: 10).returns(POSTS)
    Fetcher::Channels::X.expects(:search).never

    result = PlatformSearchTool.new.execute(query: "jack", platform: "x")

    assert_equal :success, result[:status]
    assert_equal "x", result[:data][:platform]
    assert_equal "https://x.com/jack/status/1001", result[:data][:results].first["url"]
    assert_nil result[:data][:results].first["retweets"], "contador ilegivel chega ao modelo como nil"
  end

  test "handle com arroba e com espaco chega limpo ao canal" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: 10).twice.returns([])

    assert_equal :success, PlatformSearchTool.new.execute(query: " @jack ", platform: "x")[:status]
    assert_equal :success, PlatformSearchTool.new.execute(query: "jack", platform: "x")[:status]
  end

  # Se o modelo tratar o X como busca por assunto, a resposta tem de ENSINAR a
  # fronteira — não abrir Chrome para carregar `x.com/<frase>`.
  test "assunto no lugar do perfil vira erro que ensina, sem tocar no canal" do
    Fetcher::Channels::X.expects(:timeline).never

    result = PlatformSearchTool.new.execute(query: "o que estao falando de ruby", platform: "x")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "perfil"
    assert_includes result[:reason], "@"
  end

  test "limite no x e clampado igual aos outros" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: PlatformSearchTool::MAX_LIMIT).returns([])

    assert_equal :success, PlatformSearchTool.new.execute(query: "jack", platform: "x", limit: 999)[:status]
  end

  test "rate limit e sessao expirada do x viram erro nomeado, nunca lista vazia" do
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::Channels::X::RateLimited.new("x.com"))
    limitado = PlatformSearchTool.new.execute(query: "jack", platform: "x")

    assert_equal :error, limitado[:status]
    assert_includes limitado[:reason], "x.com"

    Fetcher::Channels::X.unstub(:timeline)
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::CookieJar::Expired.new("x.com"))
    sem_sessao = PlatformSearchTool.new.execute(query: "jack", platform: "x")

    assert_equal :error, sem_sessao[:status]
    assert_includes sem_sessao[:reason], "sessão"
    assert_includes sem_sessao[:reason], "x.com"
  end

  test "timeline ilegivel vira erro nomeado, nao sucesso com zero posts" do
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::Channels::X::TimelineFailed.new)

    result = PlatformSearchTool.new.execute(query: "jack", platform: "x")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "timeline", "o motivo do canal chega ao modelo, nao um sucesso vazio"
  end

  test "x aparece entre as plataformas validas quando o modelo erra o nome" do
    result = PlatformSearchTool.new.execute(query: "jack", platform: "twitter")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "x"
  end

  # Sem isto escrito na description, o modelo manda assunto para o X e recebe
  # erro em toda chamada — ou pior, entende o resultado de um perfil como se
  # fosse busca por assunto.
  test "a description diz que no X e perfil e nao assunto" do
    desc = PlatformSearchTool.description.to_s

    assert_includes desc, "X"
    assert_match(/perfil/i, desc)
    assert_match(/recentes/i, desc)
    assert_match(/n(ã|a)o (é|e) busca por assunto|n(ã|a)o existe busca por assunto/i, desc)
  end

  test "a description do parametro query explica o duplo papel" do
    query = PlatformSearchTool.parameters[:query]

    assert_match(/perfil|handle/i, query.description.to_s)
  end

  test "parametro inventado pelo modelo e ignorado, nao derruba a chamada" do
    Fetcher::Channels::Youtube.expects(:search).with(query: "x", limit: 10).returns([])

    result = PlatformSearchTool.new.execute(query: "x", platform: "youtube", engine: "youtube")

    assert_equal :success, result[:status]
  end
end
