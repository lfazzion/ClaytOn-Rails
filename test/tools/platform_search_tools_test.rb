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

  test "busca no reddit devolve os itens do canal pontuados e PRESERVA o score nativo" do
    Fetcher::Channels::Reddit.expects(:search).with(query: "ruby 4", limit: 10).returns(THREADS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "reddit")

    assert_equal :success, result[:status]
    assert_equal "reddit", result[:data][:platform]
    item = result[:data][:results].first
    # O scoring expõe o composto em "relevance_score" e NÃO apaga os 54 upvotes
    # que o canal Reddit entrega em "score" (colisão de campo = perda de info).
    assert_kind_of Float, item["relevance_score"]
    assert_equal 54, item["score"]
  end

  test "resultados da busca sao reordenados pelo score composto" do
    item_baixo = { "url" => "https://www.youtube.com/watch?v=1", "title" => "Bolo de cenoura" }
    item_alto  = { "url" => "https://www.youtube.com/watch?v=2", "title" => "Ruby 4 novidades e tutorial" }

    Fetcher::Channels::Youtube.expects(:search).with(query: "ruby 4", limit: 10).returns([item_baixo, item_alto])

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "youtube")

    assert_equal :success, result[:status]
    results = result[:data][:results]
    assert_equal 2, results.size
    assert_equal "https://www.youtube.com/watch?v=2", results.first["url"], "Item mais relevante deve vir primeiro"
    assert results.first["relevance_score"] > results.last["relevance_score"]
  end

  test "fallback do scorer nao sobrescreve o score nativo do reddit" do
    Research::Scorer.stubs(:sort).raises(StandardError, "falha forçada")
    Fetcher::Channels::Reddit.expects(:search).with(query: "ruby 4", limit: 10).returns(THREADS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "reddit")

    assert_equal :success, result[:status]
    assert_equal 1, result[:data][:count]
    item = result[:data][:results].first
    assert_equal 54, item["score"], "Fallback devolve intacto — upvotes do Reddit não podem virar 0.0"
    refute item.key?("relevance_score")
  end

  test "x (por perfil) nao passa pelo scorer e mantem ordem cronologica" do
    post_antigo = { "url" => "https://x.com/jack/status/2", "title" => "post antigo e popular" }
    post_novo   = { "url" => "https://x.com/jack/status/1", "title" => "post novo" }

    Research::Scorer.expects(:sort).never
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: 10).returns([post_antigo, post_novo])

    result = PlatformSearchTool.new.execute(query: "@jack", platform: "x")

    assert_equal :success, result[:status]
    urls = result[:data][:results].map { |r| r["url"] }
    assert_equal ["https://x.com/jack/status/2", "https://x.com/jack/status/1"], urls,
                 "X mantém a ordem cronológica do canal (posts mais recentes)"
    refute result[:data][:results].first.key?("relevance_score")
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
    Fetcher::Channels::Hackernews.expects(:search).never
    Fetcher::Channels::Github.expects(:search).never
    Fetcher::Channels::Polymarket.expects(:search).never

    result = PlatformSearchTool.new.execute(query: "x", platform: "tiktok")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "tiktok"
    assert_includes result[:reason], "youtube"
    assert_includes result[:reason], "reddit"
    assert_includes result[:reason], "hackernews"
    assert_includes result[:reason], "github"
    assert_includes result[:reason], "polymarket"
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

  test "timeout de render em plataforma nao vira falha inesperada" do
    Fetcher::Channels::Reddit.stubs(:search).raises(Fetcher::BrowserSession::RenderTimeout.new("old.reddit.com"))

    result = PlatformSearchTool.new.execute(query: "ruby", platform: "reddit")

    assert_equal :error, result[:status]
    assert_match(/tempo|timeout|render/i, result[:reason])
    refute_match(/falha inesperada/i, result[:reason])
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
    # Os 3 canais novos também precisam aparecer para o modelo poder escolhê-los
    assert_includes desc, "Hacker News"
    assert_includes desc, "GitHub"
    assert_includes desc, "Polymarket"
  end

  # ---------------------------------------------------------------------------
  # X (Twitter) — `query` pode ser perfil (@handle → timeline) ou assunto
  # (termo sem @ → busca por assunto). A tool faz a fronteira e o modelo
  # precisa enxergar a diferença em vez de adivinhar.
  # ---------------------------------------------------------------------------

  POSTS = [
    { "url" => "https://x.com/jack/status/1001", "text" => "post", "author" => "Jack",
      "screen_name" => "jack", "created_at" => "2026-08-05T12:00:00Z",
      "likes" => 1234, "retweets" => nil, "replies" => nil }
  ].freeze

  test "no x a query com @ e o perfil, e o roteamento vai para timeline" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: 10).returns(POSTS)
    Fetcher::Channels::X.expects(:search).never

    result = PlatformSearchTool.new.execute(query: "@jack", platform: "x")

    assert_equal :success, result[:status]
    assert_equal "x", result[:data][:platform]
    assert_equal "https://x.com/jack/status/1001", result[:data][:results].first["url"]
    assert_nil result[:data][:results].first["retweets"], "contador ilegivel chega ao modelo como nil"
  end

  test "handle com arroba e com espaco chega limpo ao canal" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: 10).twice.returns([])

    assert_equal :success, PlatformSearchTool.new.execute(query: " @jack ", platform: "x")[:status]
    assert_equal :success, PlatformSearchTool.new.execute(query: "@jack", platform: "x")[:status]
  end

  test "termo de 1 palavra sem @ no x e roteado para search e passa pelo scorer" do
    Fetcher::Channels::X.expects(:timeline).never
    Fetcher::Channels::X.expects(:search).with(query: "bitcoin", limit: 10).returns(POSTS)

    result = PlatformSearchTool.new.execute(query: "bitcoin", platform: "x")

    assert_equal :success, result[:status]
    assert_equal "x", result[:data][:platform]
    # O Scorer acrescenta relevance_score sobre os resultados do canal, como no
    # youtube e no reddit — ver asserções em ~linhas 41/57.
    assert_kind_of Float, result[:data][:results].first["relevance_score"]
  end

  test "query nao-perfil no x e roteada para X.search e passa pelo scorer" do
    Fetcher::Channels::X.expects(:timeline).never
    Fetcher::Channels::X.expects(:search).with(query: "ruby rails", limit: 10).returns(POSTS)

    result = PlatformSearchTool.new.execute(query: "ruby rails", platform: "x")

    assert_equal :success, result[:status]
    assert_equal "x", result[:data][:platform]
    assert_equal "https://x.com/jack/status/1001", result[:data][:results].first["url"]
    assert_kind_of Float, result[:data][:results].first["relevance_score"]
  end

  test "limite no x e clampado igual aos outros" do
    Fetcher::Channels::X.expects(:timeline).with(user: "jack", limit: PlatformSearchTool::MAX_LIMIT).returns([])

    assert_equal :success, PlatformSearchTool.new.execute(query: "@jack", platform: "x", limit: 999)[:status]
  end

  test "rate limit e sessao expirada do x viram erro nomeado, nunca lista vazia" do
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::Channels::X::RateLimited.new("x.com"))
    limitado = PlatformSearchTool.new.execute(query: "@jack", platform: "x")

    assert_equal :error, limitado[:status]
    assert_includes limitado[:reason], "x.com"

    Fetcher::Channels::X.unstub(:timeline)
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::CookieJar::Expired.new("x.com"))
    sem_sessao = PlatformSearchTool.new.execute(query: "@jack", platform: "x")

    assert_equal :error, sem_sessao[:status]
    assert_includes sem_sessao[:reason], "sessão"
    assert_includes sem_sessao[:reason], "x.com"
  end

  test "timeline ilegivel vira erro nomeado, nao sucesso com zero posts" do
    Fetcher::Channels::X.stubs(:timeline).raises(Fetcher::Channels::X::TimelineFailed.new)

    result = PlatformSearchTool.new.execute(query: "@jack", platform: "x")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "timeline", "o motivo do canal chega ao modelo, nao um sucesso vazio"
  end

  # Busca por assunto no X que falha — a tool deve devolver erro nomeado (hash
  # com :error), espelhando o padrão do teste de erro da timeline acima.
  test "busca ilegivel no x vira erro nomeado via SearchFailed, nao sucesso com zero posts" do
    Fetcher::Channels::X.stubs(:search).raises(Fetcher::Channels::X::SearchFailed.new)

    result = PlatformSearchTool.new.execute(query: "ruby rails", platform: "x")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "busca", "o motivo do canal chega ao modelo, nao um sucesso vazio"
  end

  test "x aparece entre as plataformas validas quando o modelo erra o nome" do
    result = PlatformSearchTool.new.execute(query: "@jack", platform: "twitter")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "x"
  end

  test "a description explica a busca por perfil e por assunto no X" do
    desc = PlatformSearchTool.description.to_s

    assert_includes desc, "X"
    assert_match(/perfil/i, desc)
    assert_match(/assunto/i, desc)
  end

  test "a description do parametro query explica o duplo papel" do
    query = PlatformSearchTool.parameters[:query]

    assert_match(/perfil|handle|assunto/i, query.description.to_s)
  end

  test "parametro inventado pelo modelo e ignorado, nao derruba a chamada" do
    Fetcher::Channels::Youtube.expects(:search).with(query: "x", limit: 10).returns([])

    result = PlatformSearchTool.new.execute(query: "x", platform: "youtube", engine: "youtube")

    assert_equal :success, result[:status]
  end

  # ---------------------------------------------------------------------------
  # Hackernews, Github, Polymarket — busca por ASSUNTO (query = tema, não perfil)
  # Estes canais passam pelo Scorer exatamente como YouTube e Reddit.
  # ---------------------------------------------------------------------------

  HN_ITEMS = [
    { "url" => "https://news.ycombinator.com/item?id=111", "title" => "Ruby 4 anunciado",
      "source" => "hackernews", "points" => 500, "comments" => 200,
      "author" => "pg", "created_at" => "2026-08-01T10:00:00Z", "external_url" => nil },
    { "url" => "https://news.ycombinator.com/item?id=222", "title" => "Muffin de beterraba",
      "source" => "hackernews", "points" => 1, "comments" => 0,
      "author" => "anon", "created_at" => "2026-08-01T09:00:00Z", "external_url" => nil }
  ].freeze

  test "busca no hackernews roteado para search do canal, nao para timeline" do
    Fetcher::Channels::Hackernews.expects(:search).with(query: "ruby 4", limit: 10).returns(HN_ITEMS)
    Fetcher::Channels::Hackernews.expects(:timeline).never if Fetcher::Channels::Hackernews.respond_to?(:timeline)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "hackernews")

    assert_equal :success, result[:status]
    assert_equal "hackernews", result[:data][:platform]
    assert_equal 2, result[:data][:count]
    assert_equal "https://news.ycombinator.com/item?id=111", result[:data][:results].first["url"]
  end

  test "resultados do hackernews sao reordenados pelo scorer" do
    item_baixo = { "url" => "https://news.ycombinator.com/item?id=333", "title" => "Muffin de beterraba",
                   "source" => "hackernews", "points" => 1, "comments" => 0 }
    item_alto  = { "url" => "https://news.ycombinator.com/item?id=444", "title" => "Ruby 4 novidades e tutorial",
                   "source" => "hackernews", "points" => 500, "comments" => 200 }

    Fetcher::Channels::Hackernews.expects(:search).with(query: "ruby 4", limit: 10).returns([item_baixo, item_alto])

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "hackernews")

    assert_equal :success, result[:status]
    results = result[:data][:results]
    assert_equal 2, results.size
    assert_equal "https://news.ycombinator.com/item?id=444", results.first["url"],
                 "Item mais relevante para 'ruby 4' deve vir primeiro"
    assert results.first["relevance_score"] > results.last["relevance_score"]
  end

  test "hackernews nao esta na lista POR_PERFIL" do
    refute PlatformSearchTool::POR_PERFIL.include?("hackernews")
  end

  test "erro de api do hackernews vira erro nomeado via Fetcher::Channels::Error" do
    Fetcher::Channels::Hackernews.stubs(:search)
                                  .raises(Fetcher::Channels::Hackernews::ApiError, "API do HN respondeu HTTP 503")

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "hackernews")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "hackernews"
  end

  GH_ITEMS = [
    { "url" => "https://github.com/ruby/ruby/issues/1", "title" => "Ruby 4 planning",
      "source" => "github", "reactions" => 300, "comments" => 50,
      "author" => "matz", "created_at" => "2026-08-01T08:00:00Z" },
    { "url" => "https://github.com/ruby/ruby/issues/2", "title" => "Fix typo in README",
      "source" => "github", "reactions" => 1, "comments" => 0,
      "author" => "bot", "created_at" => "2026-08-02T08:00:00Z" }
  ].freeze

  test "busca no github roteado para search do canal" do
    Fetcher::Channels::Github.expects(:search).with(query: "ruby 4", limit: 10).returns(GH_ITEMS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "github")

    assert_equal :success, result[:status]
    assert_equal "github", result[:data][:platform]
    assert_equal 2, result[:data][:count]
  end

  test "resultados do github sao reordenados pelo scorer" do
    item_baixo = { "url" => "https://github.com/ruby/ruby/issues/9", "title" => "Fix typo",
                   "source" => "github", "reactions" => 0, "comments" => 0 }
    item_alto  = { "url" => "https://github.com/ruby/ruby/issues/8", "title" => "Ruby 4 planning discussion",
                   "source" => "github", "reactions" => 300, "comments" => 50 }

    Fetcher::Channels::Github.expects(:search).with(query: "ruby 4", limit: 10).returns([item_baixo, item_alto])

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "github")

    assert_equal :success, result[:status]
    results = result[:data][:results]
    assert_equal 2, results.size
    assert_equal "https://github.com/ruby/ruby/issues/8", results.first["url"],
                 "Item mais relevante para 'ruby 4' deve vir primeiro"
    assert results.first["relevance_score"] > results.last["relevance_score"]
  end

  test "github nao esta na lista POR_PERFIL" do
    refute PlatformSearchTool::POR_PERFIL.include?("github")
  end

  test "github devolve lista vazia em 403 sem virar erro" do
    # Github.search faz fallback gracioso [] em 403/429/5xx — tool reporta sucesso
    Fetcher::Channels::Github.expects(:search).with(query: "ruby 4", limit: 10).returns([])

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "github")

    assert_equal :success, result[:status]
    assert_equal 0, result[:data][:count]
  end

  PM_ITEMS = [
    { "url" => "https://polymarket.com/event/ruby-4-release", "title" => "Ruby 4 released in 2026?",
      "source" => "polymarket", "volume" => 50_000.0, "liquidity" => 10_000.0,
      "created_at" => "2026-07-01" },
    { "url" => "https://polymarket.com/event/muffin", "title" => "Muffin sales up?",
      "source" => "polymarket", "volume" => 100.0, "liquidity" => 50.0,
      "created_at" => "2026-07-02" }
  ].freeze

  test "busca no polymarket roteado para search do canal" do
    Fetcher::Channels::Polymarket.expects(:search).with(query: "ruby 4", limit: 10).returns(PM_ITEMS)

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "polymarket")

    assert_equal :success, result[:status]
    assert_equal "polymarket", result[:data][:platform]
    assert_equal 2, result[:data][:count]
  end

  test "resultados do polymarket sao reordenados pelo scorer" do
    item_baixo = { "url" => "https://polymarket.com/event/muffin", "title" => "Muffin sales up?",
                   "source" => "polymarket", "volume" => 100.0, "liquidity" => 50.0 }
    item_alto  = { "url" => "https://polymarket.com/event/ruby-4", "title" => "Ruby 4 released in 2026?",
                   "source" => "polymarket", "volume" => 50_000.0, "liquidity" => 10_000.0 }

    Fetcher::Channels::Polymarket.expects(:search).with(query: "ruby 4", limit: 10).returns([item_baixo, item_alto])

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "polymarket")

    assert_equal :success, result[:status]
    results = result[:data][:results]
    assert_equal 2, results.size
    assert_equal "https://polymarket.com/event/ruby-4", results.first["url"],
                 "Item mais relevante para 'ruby 4' deve vir primeiro"
    assert results.first["relevance_score"] > results.last["relevance_score"]
  end

  test "polymarket nao esta na lista POR_PERFIL" do
    refute PlatformSearchTool::POR_PERFIL.include?("polymarket")
  end

  test "erro de api do polymarket vira erro nomeado via Fetcher::Channels::Error" do
    Fetcher::Channels::Polymarket.stubs(:search)
                                  .raises(Fetcher::Channels::Polymarket::RateLimited.new("gamma-api.polymarket.com"))

    result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "polymarket")

    assert_equal :error, result[:status]
    assert_includes result[:reason], "polymarket"
  end

  test "a description do parametro platform lista os 6 valores validos" do
    desc = PlatformSearchTool.parameters[:platform].description.to_s

    assert_includes desc, "hackernews"
    assert_includes desc, "github"
    assert_includes desc, "polymarket"
    assert_includes desc, "youtube"
    assert_includes desc, "reddit"
    assert_includes desc, "x"
  end
end
