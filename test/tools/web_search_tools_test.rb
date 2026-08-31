# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/web_search_tools"
# D2-F5a-v10 (31/08/2026): teste "fallback pago sucesso" usa
# `WebSearchTool::SearchApiRouter.stubs(:call)`. Sem este require o nome
# `SearchApiRouter` não está definido dentro da namespace da tool
# (web_search_tools.rb só faz require do SearchApiCache), e o stub estoura
# NameError ANTES de chegar à assertion do incremento 1x. require do router
# deixa o stub válido e isola o teste do fan-in de quem carrega o router
# em produção.
require_relative "../../app/services/search_api_router"

class WebSearchToolsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "retorna resultados mapeados em success" do
    stub_request(:get, "http://searxng:8080/search")
      .with(query: hash_including(q: "ruby on rails", format: "json"))
      .to_return(
        status: 200,
        body:   { results: [
          { "title" => "T", "url" => "https://x", "content" => "snippet", "engine" => "duckduckgo" }
        ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = WebSearchTool.new.execute(query: "ruby on rails")
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_equal "https://x", result[:data].first[:url]
  end

  # Sem `categories` o SearXNG assume `general`, e stackoverflow/github/askubuntu/
  # superuser/hackernews/mdn moram em `it` — ficavam registrados no catalogo e NUNCA
  # disparavam numa busca do bot. Medido em 05/08/2026 com a query
  # "ActiveRecord ConnectionNotEstablished": `general` devolveu 13 resultados de dois
  # engines; `general,it` devolveu 24 de cinco, com o stackoverflow entrando com 10.
  # A categoria e pedida pela TOOL, e nao mentida na config do engine: stackoverflow
  # E um engine de `it`, e trocar o rotulo dele quebraria o `!bang` de quem quisesse
  # so `it`.
  test "pede as categorias que fazem os engines de it e science dispararem" do
    stub_request(:get, "http://searxng:8080/search")
      .with(query: hash_including(format: "json", categories: "general,it,science"))
      .to_return(
        status: 200,
        body:   { results: [{ "title" => "T", "url" => "u", "content" => "c", "engine" => "e" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert_equal :success, WebSearchTool.new.execute(query: "activerecord")[:status]
  end

  test "trunca content acima de 200 chars (F1 payload magro)" do
    long = "a" * 1000
    stub_request(:get, "http://searxng:8080/search")
      .with(query: hash_including(format: "json"))
      .to_return(
        status: 200,
        body:   { results: [{ "title" => "T", "url" => "u", "content" => long, "engine" => "e" }] }.to_json
      )
    result = WebSearchTool.new.execute(query: "x")
    # F1 plano v2: CONTENT_MAX_CHARS 400→200. 200 chars + reticências = 201.
    assert_operator result[:data].first[:content].length, :<=, 201
  end

  test "clampa limit no teto" do
    stub_request(:get, "http://searxng:8080/search")
      .with(query: hash_including(format: "json"))
      .to_return(
        status: 200,
        body:   { results: Array.new(20) { |i| { "title" => i.to_s, "url" => "u#{i}", "content" => "c" } } }.to_json
      )
    result = WebSearchTool.new.execute(query: "x", limit: 999)
    # F1 plano v2 (30/08/2026): teto desce de 10 para 5.
    assert_operator result[:data].size, :<=, 5
  end

  test "query vazia retorna error" do
    result = WebSearchTool.new.execute(query: "  ")
    assert_equal :error, result[:status]
    assert_equal "query vazia", result[:reason]
  end

  test "HTTP 500 retorna error sem retry" do
    stub_request(:get, "http://searxng:8080/search")
      .with(query: hash_including(format: "json"))
      .to_return(status: 500)
    result = WebSearchTool.new.execute(query: "x")
    assert_equal :error, result[:status]
  end

  test "resultado é cacheado por query+limit" do
    stub = stub_request(:get, "http://searxng:8080/search")
           .with(query: hash_including(format: "json"))
           .to_return(
             status: 200,
             body:   { results: [{ "title" => "T", "url" => "u", "content" => "c", "engine" => "e" }] }.to_json
           )
    2.times { WebSearchTool.new.execute(query: "cache test") }
    assert_requested stub, times: 1
  end

  test "time_range é anexado como param searxng quando válido" do
    stub = stub_request(:get, "http://searxng:8080/search")
           .with(query: hash_including(q: "breaking news", time_range: "day"))
           .to_return(status: 200, body: { results: [] }.to_json)
    WebSearchTool.new.execute(query: "breaking news", time_range: "day")
    assert_requested stub
  end

  test "time_range valores permitidos: day/week/month/year" do
    %w[day week month year].each do |range|
      Rails.cache.clear
      stub = stub_request(:get, "http://searxng:8080/search")
             .with(query: hash_including(time_range: range))
             .to_return(status: 200, body: { results: [] }.to_json)
      WebSearchTool.new.execute(query: "teste #{range}", time_range: range)
      assert_requested stub
    end
  end

  test "time_range inválido é ignorado (não envia param)" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(status: 200, body: { results: [] }.to_json)
    WebSearchTool.new.execute(query: "x", time_range: "century")
    assert_requested(:get, /searxng:8080\/search/) do |req|
      !req.uri.query.to_s.include?("time_range")
    end
  end

  test "sem time_range, searxng é chamado sem o param" do
    stub_request(:get, /searxng:8080\/search/)
      .to_return(status: 200, body: { results: [] }.to_json)
    WebSearchTool.new.execute(query: "sem filtro de data")
    assert_requested(:get, /searxng:8080\/search/) do |req|
      !req.uri.query.to_s.include?("time_range")
    end
  end

  test "cache é keyed separadamente por time_range" do
    stub_request(:get, /searxng:8080\/search/)
      .with(query: hash_including(time_range: "day"))
      .to_return(status: 200, body: { results: [{ "title" => "t1", "url" => "u1", "content" => "c" }] }.to_json)
    stub_request(:get, /searxng:8080\/search/)
      .with(query: hash_including(format: "json"))
      .to_return(status: 200, body: { results: [{ "title" => "t2", "url" => "u2", "content" => "c" }] }.to_json)
    WebSearchTool.new.execute(query: "placar", time_range: "day")
    WebSearchTool.new.execute(query: "placar")
    assert_requested(:get, /searxng:8080\/search/, times: 2)
  end

  # ---------------------------------------------------------------------------
  # Guarda lexical de relevância
  #
  # Caso real medido em 05/08/2026: a query "reddit ruby performance" voltou do
  # bing com páginas de Roblox e cartas Pokémon, e a tool devolveu isso com cara
  # de sucesso. O bing já saiu do SearXNG; estes testes fecham o buraco no código.
  # ---------------------------------------------------------------------------

  ROBLOX_LIXO = [
    { "title" => "Log in to Roblox", "url" => "https://www.roblox.com/login",
      "content" => "Roblox is a global platform that brings people together through play.", "engine" => "bing" },
    { "title" => "Roblox Studio", "url" => "https://create.roblox.com/",
      "content" => "Roblox Studio is the building tool of the Roblox platform.", "engine" => "bing" },
    { "title" => "Careers | Roblox", "url" => "https://careers.roblox.com/",
      "content" => "Come build the platform that brings people together.", "engine" => "bing" },
    { "title" => "Pokémon Trading Card Game", "url" => "https://tcg.pokemon.com/",
      "content" => "Cartas colecionáveis, decks e torneios oficiais.", "engine" => "bing" },
    { "title" => "Roblox Corporation - Wikipedia", "url" => "https://en.wikipedia.org/wiki/Roblox_Corporation",
      "content" => "American video game company headquartered in San Mateo.", "engine" => "bing" }
  ].freeze

  REDDIT_RUBY_BONS = [
    { "title" => "r/ruby on Reddit: Is ruby really slow?", "url" => "https://reddit.com/r/ruby/1",
      "content" => "Discussão sobre performance de Ruby em aplicações reais.", "engine" => "duckduckgo" },
    { "title" => "Ruby Performance Evolution: From 1.0 to Today", "url" => "https://rubyperf.dev/evolution",
      "content" => "Benchmarks entre versões do interpretador.", "engine" => "duckduckgo" },
    { "title" => "Ruby 4.0 performance: o que mudou", "url" => "https://blog.dev/ruby4",
      "content" => "Thread do Reddit comparando YJIT e ZJIT.", "engine" => "brave" }
  ].freeze

  # Coleta REAL do SearXNG desta máquina em 05/08/2026 para "quem ganhou a eleicao na
  # Argentina" — uma das três queries que o dono mediu como boas. Copiada verbatim da
  # resposta JSON, sem edição: é o corpus que prova o comportamento da guarda em pt-BR.
  ARGENTINA_REAL = [
    { "title" => "Partido de Milei surpreende e vence eleições legislativas na Argentina | G1",
      "url" => "https://g1.globo.com/mundo/noticia/2025/10/26/eleicao-legislativa-argentina-resultados.ghtml",
      "content" => "26 de out. de 2025 ... O partido do presidente Javier Milei, A Liberdade Avança, venceu as " \
                    "eleições legislativas da Argentina neste domingo (26) e vai aumentar sua ...",
      "engine" => "duckduckgo web" },
    { "title" => "Milei vence eleição legislativa com ajuda bilionária de Trump",
      "url" => "https://www.poder360.com.br/poder-internacional/milei-vence-eleicao-legislativa-na-argentina/",
      "content" => "O presidente da Argentina, Javier Milei (La Libertad Avanza), saiu vitorioso das eleições " \
                    "legislativas realizadas neste domingo (26.out.2025) e duplicou sua base no Congresso.",
      "engine" => "duckduckgo web" },
    { "title" => "Milei conquista vitória 'surpreendente' em eleições legislativas na ...",
      "url" => "https://www.bbc.com/portuguese/articles/c751d36gg6zo",
      "content" => "Após meses de incertezas — incluindo uma derrota nas eleições legislativas da província de " \
                    "Buenos Aires em 7 de setembro, escândalos de corrupção e uma crise econômica...",
      "engine" => "duckduckgo web" },
    { "title" => "Eleição presidencial na Argentina em 2023",
      "url" => "https://pt.wikipedia.org/wiki/Elei%C3%A7%C3%A3o_presidencial_na_Argentina_em_2023",
      "content" => "A eleição presidencial na Argentina em 2023 foi realizada no dia 22 de outubro de 2023 para " \
                    "eleger o presidente e o vice-presidente da nação.",
      "engine" => "duckduckgo web" },
    { "title" => "Resultado da eleição na Argentina: Javier Milei ganha e será ... - Exame",
      "url" => "https://exame.com/mundo/resultado-da-eleicao-na-argentina/",
      "content" => "A Argentina elegeu neste domingo, 19, Javier Milei como novo presidente do país. O deputado " \
                    "ultralibertário teve 55,69% dos votos, 11 pontos percentuais à frente do rival Sergio Massa.",
      "engine" => "duckduckgo web" },
    { "title" => "Partido de Milei vence eleições na Argentina com ampla maioria",
      "url" => "https://agenciabrasil.ebc.com.br/internacional/noticia/2025-10/partido-de-milei-vence-eleicoes",
      "content" => "",
      "engine" => "google cse" },
    { "title" => "Bellemar Apartment by Homie",
      "url" => "https://www.google.com/travel/hotels/entity/CiQIyoiKkdDTpIRmEKvcoZnA4IPXywEaDS9nLzExdHhxbHA4cjgQAg",
      "content" => "Seja para um mergulho matinal, uma caminhada à beira-mar ou uma bebida ao fim da tarde, este " \
                    "será certamente um dos seus cenários de eleição.",
      "engine" => "seznam" },
    { "title" => "Veja o resultado das eleições na província de Buenos Aires",
      "url" => "https://www.poder360.com.br/poder-internacional/veja-o-resultado-das-eleicoes-na-provincia/",
      "content" => "Com 99% das urnas apuradas, a coalizão peronista Fuerza Pátria (esquerda) venceu as eleições " \
                    "na província de Buenos Aires, na Argentina.",
      "engine" => "duckduckgo web" },
    { "title" => "Milei conquista vitória 'surpreendente' em eleições legislativas na ...",
      "url" => "https://www.msn.com/pt-br/noticias/mundo/milei-conquista-vitoria-surpreendente/ar-AA1PeCpE",
      "content" => "A maior surpresa foi como o partido de Milei diminuiu a diferença na província de Buenos " \
                    "Aires, principal distrito eleitoral do país, onde há quase um mês e meio havia perdido...",
      "engine" => "duckduckgo web" },
    { "title" => "Eleição parlamentar na Argentina em 2025 - Wikipédia, a enciclopédia livre",
      "url" => "https://pt.wikipedia.org/wiki/Elei%C3%A7%C3%A3o_parlamentar_na_Argentina_em_2025",
      "content" => "A eleição foi vencida de forma surpreendente pela coalizão do presidente Javier Milei, A " \
                    "Liberdade Avança (LLA), com mais de 40% dos votos.",
      "engine" => "duckduckgo web" }
  ].freeze

  def stub_search(results, unresponsive: nil)
    body = { results: results }
    body[:unresponsive_engines] = unresponsive if unresponsive
    stub_request(:get, /searxng:8080\/search/).to_return(
      status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  test "guarda lexical reprova a busca inteira quando os resultados são lixo (caso roblox medido)" do
    stub_search(ROBLOX_LIXO)
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    assert_equal :error, result[:status]
    assert_match(/irrelevante/i, result[:reason])
  end

  test "guarda lexical aprova os resultados reais bons da mesma query" do
    stub_search(REDDIT_RUBY_BONS)
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    assert_equal :success, result[:status]
    assert_equal 3, result[:data].size
    piso = WebSearchTool::RelevanceGuard::RELEVANCE_FLOOR
    result[:data].each do |r|
      assert_operator r[:relevance], :>=, piso, "reprovou resultado bom: #{r[:title]}"
    end
  end

  test "resultado irrelevante isolado é descartado sem derrubar a busca" do
    stub_search(REDDIT_RUBY_BONS + ROBLOX_LIXO.first(2))
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    assert_equal :success, result[:status]
    assert_equal 3, result[:data].size
    assert_empty result[:data].select { |r| r[:url].include?("roblox") }
  end

  test "termos que só aparecem no snippet contam — título genérico não reprova resultado bom" do
    results = [
      { "title" => "Página inicial", "url" => "https://exemplo.dev/1",
        "content" => "Benchmark de performance do Ruby na versão 4.0.", "engine" => "duckduckgo" },
      { "title" => "Notas da versão", "url" => "https://exemplo.dev/2",
        "content" => "Thread no Reddit discute performance do Ruby.", "engine" => "duckduckgo" }
    ] + ROBLOX_LIXO.first(2)
    stub_search(results)
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
    assert(result[:data].all? { |r| r[:url].start_with?("https://exemplo.dev") })
  end

  test "acento na query não reprova resultado sem acento (e vice-versa)" do
    bons = [
      { "title" => "Eleicao na Argentina: resultado oficial", "url" => "https://n1.com/a",
        "content" => "Apuração encerrada.", "engine" => "duckduckgo" },
      { "title" => "Eleição argentina ao vivo", "url" => "https://n2.com/b",
        "content" => "Cobertura minuto a minuto.", "engine" => "duckduckgo" },
      { "title" => "Argentina define eleições", "url" => "https://n3.com/c",
        "content" => "Segundo turno.", "engine" => "seznam" }
    ]
    stub_search(bons + ROBLOX_LIXO.first(3))
    result = WebSearchTool.new.execute(query: "eleição na Argentina")
    assert_equal :success, result[:status]
    assert_equal 3, result[:data].size
  end

  test "query de um termo só não é filtrada — guarda desliga em vez de derrubar resultado bom" do
    results = [
      { "title" => "Cotação do BTC hoje", "url" => "https://m1.com", "content" => "Mercado cripto.", "engine" => "e" },
      { "title" => "Preço da moeda digital", "url" => "https://m2.com", "content" => "Análise.", "engine" => "e" },
      { "title" => "Criptomoedas em alta", "url" => "https://m3.com", "content" => "Resumo do dia.", "engine" => "e" },
      { "title" => "Mercado financeiro", "url" => "https://m4.com", "content" => "Fechamento.", "engine" => "e" }
    ]
    stub_search(results)
    result = WebSearchTool.new.execute(query: "bitcoin")
    assert_equal :success, result[:status]
    assert_equal 4, result[:data].size
    assert_nil result[:data].first[:relevance], "guarda desligada deve reportar relevance nil, nunca 0"

    # Contraste: com DOIS termos a guarda liga e filtra a mesma lista — prova que o que
    # salvou os 4 acima foi a regra de termo único, não a guarda estar quebrada.
    Rails.cache.clear
    dois = WebSearchTool.new.execute(query: "cotação do bitcoin")
    assert_equal :success, dois[:status]
    assert_equal ["https://m1.com"], dois[:data].map { |r| r[:url] }
  end

  # Prefixo estrito não cobre flexão portuguesa: "eleicao" não é prefixo de "eleicoes"
  # (o plural de -ção diverge antes do fim da palavra) e "ganhou" não casa com "ganha".
  # Com a coleta real abaixo isso derrubava a MANCHETE CORRETA em 1º lugar (G1), e numa
  # das coletas ao vivo levou a busca inteira a virar erro (2 de 10 aprovados).
  test "flexão de plural não derruba a manchete correta (coleta real da argentina)" do
    stub_search(ARGENTINA_REAL)
    result = WebSearchTool.new.execute(query: "quem ganhou a eleicao na Argentina", limit: 10)
    assert_equal :success, result[:status], result[:reason].to_s

    titulos = result[:data].map { |r| r[:title] }
    assert_includes titulos, "Partido de Milei surpreende e vence eleições legislativas na Argentina | G1"
    assert_includes titulos, "Partido de Milei vence eleições na Argentina com ampla maioria"

    # O outro lado da pinça: afrouxar a guarda até aprovar tudo também reprova este teste.
    # O anúncio de hotel só casa "eleição" (1 de 4 termos) e não pode entrar.
    refute_includes titulos, "Bellemar Apartment by Homie"
  end

  test "cada resultado carrega o score de relevância calculado" do
    stub_search(REDDIT_RUBY_BONS)
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    scores = result[:data].map { |r| r[:relevance] }
    assert(scores.all? { |s| s.is_a?(Float) && s.positive? && s <= 1.0 }, "scores: #{scores.inspect}")
    assert_equal 1.0, scores.first
  end

  # ---------------------------------------------------------------------------
  # Falha não pode parecer sucesso
  # ---------------------------------------------------------------------------

  test "zero resultados com engines fora do ar é erro nomeado, não 'não achei nada'" do
    stub_search([], unresponsive: [["brave", "Suspended: too many requests"], ["seznam", "timeout"]])
    result = WebSearchTool.new.execute(query: "quem ganhou a eleição na Argentina")
    assert_equal :error, result[:status]
    assert_match(/brave/, result[:reason])
    assert_match(/seznam/, result[:reason])
  end

  test "zero resultados sem engine caída continua sendo sucesso vazio" do
    stub_search([])
    result = WebSearchTool.new.execute(query: "termo inexistente xyzzy plugh")
    assert_equal :success, result[:status]
    assert_empty result[:data]
  end

  test "engine caída com resultados na mão devolve sucesso — degradação parcial não alarma" do
    stub_search(REDDIT_RUBY_BONS, unresponsive: [["brave", "Suspended: too many requests"]])
    result = WebSearchTool.new.execute(query: "reddit ruby performance")
    assert_equal :success, result[:status]
    assert_equal 3, result[:data].size
  end

  # ---------------------------------------------------------------------------
  # Cache não pode grudar lixo
  # ---------------------------------------------------------------------------

  test "resultado vazio não fica 15 minutos no cache" do
    stub_search([])
    WebSearchTool.new.execute(query: "consulta sem resposta alguma")
    travel 2.minutes do
      WebSearchTool.new.execute(query: "consulta sem resposta alguma")
    end
    assert_requested(:get, /searxng:8080\/search/, times: 2)
  end

  test "resultado vazio ainda é cacheado por instantes para não martelar o searxng" do
    stub_search([])
    2.times { WebSearchTool.new.execute(query: "consulta sem resposta alguma") }
    assert_requested(:get, /searxng:8080\/search/, times: 1)
  end

  test "busca reprovada pela guarda não é cacheada" do
    stub_search(ROBLOX_LIXO)
    2.times { WebSearchTool.new.execute(query: "reddit ruby performance") }
    assert_requested(:get, /searxng:8080\/search/, times: 2)
  end

  test "erro de engines fora do ar não é cacheado" do
    stub_search([], unresponsive: [["brave", "Suspended: too many requests"]])
    2.times { WebSearchTool.new.execute(query: "placar do jogo de ontem") }
    assert_requested(:get, /searxng:8080\/search/, times: 2)
  end

  # ---------------------------------------------------------------------------
  # D2-F5a-v3 (30/08/2026) — Caracterização do teto de conversa
  # ---------------------------------------------------------------------------
  #
  # Estes testes TRAVAM o contrato D4 (plano-fase2) na WebSearchTool: o
  # caminho Discord in-process (:cleitin_origin = :discord) tem teto de 5
  # buscas por conversa ativa; recusa NÃO incrementa; cache hit NÃO
  # incrementa; empty debounce NÃO incrementa; MCP pula o gate.
  #
  # Eles são CARACTERIZAÇÃO (lock do contrato), não RED-GREEN: a produção
  # já está correta. Devem passar de imediato contra o código atual; se um
  # quebrar, primeiro verifique se o teste está certo e só então investigue
  # regressão no WebSearchTool.

  # Limpa Thread.current[:cleitin_*] após cada teste para que setagens
  # manuais neste arquivo não vazem para outros testes no mesmo processo.
  # Mesmo padrão já usado em chat_session_manager_test.rb.
  teardown do
    Thread.current[:cleitin_origin] = nil
    Thread.current[:cleitin_conversation_scope_key] = nil
  end

  # Helper: cria conversa ATIVA, popula o contador, e seta o par
  # (origem, scope key) em Thread.current simulando o caminho Discord.
  # Devolve a própria conversa para asserções em conv.reload.
  def stub_discord_with_active_conversation(count: 0)
    conv = Conversation.open_for(
      scope: "u:discord-d2f5av3:c:9", channel_id: "9", user_id: "discord-d2f5av3"
    )
    conv.update!(web_search_count: count) if count.positive?
    Thread.current[:cleitin_origin] = :discord
    Thread.current[:cleitin_conversation_scope_key] = conv.scope
    conv
  end

  # Brief item 1: count == MAX => retorna WEB_SEARCH_LIMIT_MESSAGE, SearXNG
  # NÃO é chamado, count permanece em MAX.
  test "D2-F5a-v3: count == MAX recusa com web_search_limit_message, sem HTTP e sem incrementar" do
    conv = stub_discord_with_active_conversation(count: Conversation::MAX_WEB_SEARCH_PER_CONVERSATION)
    stub_search(REDDIT_RUBY_BONS)

    result = WebSearchTool.new.execute(query: "sexta busca em conversa saturada")

    assert_equal :error, result[:status]
    assert_equal WebSearchTool::WEB_SEARCH_LIMIT_MESSAGE, result[:reason]
    assert_match(/limite/i, result[:reason])
    assert_match(%r{/new}, result[:reason])
    refute_match(/quota|api|cota|key/i, result[:reason],
                 "mensagem NÃO pode expor quota/API/key — brief canônico D4")
    # NOTA: WebMock 3.26 não aceita 3º arg posicional como mensagem — a 3ª
    # posição é `options` (Hash), e `String#delete(:times)` no caminho interno
    # estoura `TypeError: no implicit conversion of Symbol into String`. O
    # contrato F5a (gate ANTES do HTTP) fica documentado no assert separado,
    # e a checagem efetiva do WebMock usa a forma `:get, /regex/` (2-arg,
    # padrão já usado em test/lib/fetcher/extract_service_test.rb e em
    # test/controllers/internal/extract_controller_test.rb).
    assert_not_requested(:get, /searxng:8080\/search/)
    assert_equal Conversation::MAX_WEB_SEARCH_PER_CONVERSATION, conv.reload.web_search_count,
                 "recusa NÃO incrementa o contador (não houve busca) — gate F5a bloqueia ANTES do HTTP"
  end

  # Brief item 2: count < MAX => busca acontece, count incrementa.
  test "D2-F5a-v3: count < MAX executa busca e incrementa contador" do
    conv = stub_discord_with_active_conversation(count: 0)
    stub_search(REDDIT_RUBY_BONS)

    WebSearchTool.new.execute(query: "primeira busca")

    assert_requested(:get, /searxng:8080\/search/, times: 1)
    assert_equal 1, conv.reload.web_search_count
  end

  # Brief item 3: MCP (origin != :discord) com count == 5 => busca acontece
  # (gate pulado), count NÃO incrementa. O teto MCP mora no plugin do
  # perfil (F5b, fora deste PR).
  # D2-F5a-v10 (31/08/2026): query e stub precisam CASAR para o RelevanceGuard
  # aprovar (caso contrário a guarda reprova TUDO, retorna :error com
  # "irrelevante", e o teste falha em `assert_equal :success` — falsificando
  # o sinal: o gate foi pulado sim, só que a busca em si falhou por poison
  # lexical, não por gate). Usar "reddit ruby performance" casa com
  # REDDIT_RUBY_BONS (cada snippet cita "ruby" + "reddit"/"performance").
  test "D2-F5a-v3: origem :mcp pula o gate e não incrementa mesmo com count saturado" do
    conv = Conversation.open_for(
      scope: "u:mcp-d2f5av3:c:9", channel_id: "9", user_id: "mcp-d2f5av3"
    )
    conv.update!(web_search_count: Conversation::MAX_WEB_SEARCH_PER_CONVERSATION)
    Thread.current[:cleitin_origin] = :mcp
    Thread.current[:cleitin_conversation_scope_key] = conv.scope
    stub_search(REDDIT_RUBY_BONS)

    result = WebSearchTool.new.execute(query: "reddit ruby performance")

    assert_equal :success, result[:status]
    assert_requested(:get, /searxng:8080\/search/, times: 1)
    assert_equal Conversation::MAX_WEB_SEARCH_PER_CONVERSATION, conv.reload.web_search_count,
                 "MCP não toca no contador — gate e ensure só rodam para :discord"
  end

  # Brief item 4: cache hit NAO incrementa. 2a chamada com a MESMA query:
  # SearXNG é chamado 1x TOTAL, contador permanece.
  test "D2-F5a-v3: cache hit nao incrementa o contador" do
    conv = stub_discord_with_active_conversation(count: 0)
    # Stub cujos resultados CASAM com a query "mesma busca" — sem isso o
    # RelevanceGuard reprova tudo (poisoned) e retorna erro, incrementando
    # 1x em cada uma das 2 execucoes (count=2, searxng=2x) — falso verde
    # porque o teste do contrato "cache hit nao increment" passa a ser
    # "duas buscas reais poisoned, ambas contam". O stub abaixo tem 3
    # resultados cujos snippets cobrem "mesma" e "busca" (2 de 2 termos =
    # score 1.0 cada, todos aprovados), garante que a 1a execucao entra
    # no caminho de SUCESSO (cache.write + increment 1x) e a 2a acerta
    # o cache (search:searxng:<sha>) sem nova busca e sem novo increment.
    cache_bons = [
      { "title" => "Mesma busca em cache",
        "url"    => "https://cache.exemplo/1",
        "content" => "Resultado da mesma busca, servido do cache.",
        "engine"  => "duckduckgo" },
      { "title" => "Busca identica anterior",
        "url"    => "https://cache.exemplo/2",
        "content" => "Conteudo da mesma consulta repetida.",
        "engine"  => "duckduckgo" },
      { "title" => "Cache de busca previa",
        "url"    => "https://cache.exemplo/3",
        "content" => "Mesmo resultado, mesma busca, ttl 15min.",
        "engine"  => "duckduckgo" }
    ]
    stub_search(cache_bons)

    WebSearchTool.new.execute(query: "mesma busca")
    assert_equal 1, conv.reload.web_search_count, "1a execucao incrementa"

    WebSearchTool.new.execute(query: "mesma busca") # cache hit
    assert_equal 1, conv.reload.web_search_count,
                 "cache hit NAO incrementa - e a mesma busca, nao execucao nova"
    assert_requested(:get, /searxng:8080\/search/, times: 1)
  end

  # Brief item 5: empty debounce NAO incrementa. 2a chamada com mesmo vazio
  # da 1a: SearXNG é chamado 1x TOTAL, contador permanece. O debounce vazio
  # é separado (Rails.cache direto, fora do SearchApiCache) e vive em chave
  # propria com TTL de 60s.
  test "D2-F5a-v3: empty debounce nao incrementa o contador" do
    conv = stub_discord_with_active_conversation(count: 0)
    stub_search([])

    WebSearchTool.new.execute(query: "consulta sem resposta alguma")
    assert_equal 1, conv.reload.web_search_count,
                 "1a execucao com vazio tambem e execucao real e incrementa"
    assert_requested(:get, /searxng:8080\/search/, times: 1)

    WebSearchTool.new.execute(query: "consulta sem resposta alguma")
    assert_equal 1, conv.reload.web_search_count,
                 "2a chamada cai no debounce vazio (60s) - NAO incrementa"
    assert_requested(:get, /searxng:8080\/search/, times: 1)
  end

      # Brief D2-F5a-v4 (30/08/2026): "Fetch nil / erro: ... HTTP disparado =
      # gastou. Incrementa." D4 do plano-fase2diz "5 buscas executadas, nao
      # chamadas" - a unidade e a busca disparada (HTTP saiu), nao a busca
      # que devolveu resultado util. Estes testes travam que o contador sobe
      # UMA vez em cada cenario de busca real que terminou em erro.
      #
      # Cenarios cobertos:
      #   a) SearXNG HTTP 5xx (fetch retorna nil por Net::HTTP nao-2xx)
      #   b) SearXNG 200 com results=[] e engines fora do ar (return error)
      #   c) SearXNG 200 com results bons mas guarda reprova (poisoned)
      #
      # Em todos os tres: gate passou (count<MAX), cache miss, empty miss,
      # HTTP disparado, retorno e de erro - e ainda assim incrementa 1x.

      test "D2-F5a-v4: searxng 5xx incrementa 1x (HTTP disparado, retorno de erro)" do
        conv = stub_discord_with_active_conversation(count: 0)
        stub_request(:get, "http://searxng:8080/search")
          .with(query: hash_including(format: "json"))
          .to_return(status: 500)

        result = WebSearchTool.new.execute(query: "x")

        assert_equal :error, result[:status]
        assert_requested(:get, /searxng:8080\/search/, times: 1)
        assert_equal 1, conv.reload.web_search_count,
                     "HTTP saiu (gastou cota de fanout/timeout) - contador sobe 1x"
      end

      test "D2-F5a-v4: engines fora do ar incrementa 1x (200 com results vazio e unresponsive)" do
        conv = stub_discord_with_active_conversation(count: 0)
        stub_search([], unresponsive: [["brave", "Suspended"], ["seznam", "timeout"]])

        WebSearchTool.new.execute(query: "placar do jogo")

        assert_requested(:get, /searxng:8080\/search/, times: 1)
        assert_equal 1, conv.reload.web_search_count,
                     "SearXNG respondeu (HTTP OK) mas nao serviu nada util - contador sobe 1x"
      end

      test "D2-F5a-v4: guarda poisoned incrementa 1x (HTTP OK, resultados irrelevantes)" do
        conv = stub_discord_with_active_conversation(count: 0)
        stub_search(ROBLOX_LIXO)

        result = WebSearchTool.new.execute(query: "reddit ruby performance")

        assert_equal :error, result[:status]
        assert_match(/irrelevante/i, result[:reason])
        assert_requested(:get, /searxng:8080\/search/, times: 1)
        assert_equal 1, conv.reload.web_search_count,
                     "busca real aconteceu, irrelevancia e falha do buscador - contador sobe 1x"
      end

      # Brief D2-F5a-v4 item 3: "Garantir UNICA execucao do incremento (nao
      # incrementar duas vezes no mesmo run - ex.: fallback tem return
      # proprio)". Cenario: busca com fallback pago SUCESSO - SearXNG dispara
      # (HTTP sai), fallback Tavily/Exa/Linkup dispara (HTTP sai), retorno
      # final vem do fallback. Contador deve subir exatamente 1x por run, NAO
      # 2x. Sem o teste, e facil demais regressar para "incrementa em cada
      # return" e contar 2.
      test "D2-F5a-v4: fallback pago sucesso incrementa 1x (searxng + tavily, nao 2x)" do
        conv = stub_discord_with_active_conversation(count: 0)
        # SearXNG responde vazio com engine fora do ar (dispara fallback)
        stub_search([], unresponsive: [["brave", "Suspended"]])
        # Stub Tavily (provider de type=news via F2) - stub direto no router
        # ja que SearchApiRouter e o caminho pago.
        tavily_result = {
          results: [{ title: "T", url: "https://tavily/x", content: "conteudo tavily", engine: "tavily" }],
          unresponsive: []
        }
        SearchApiRouter.stubs(:call).returns(tavily_result)

        result = WebSearchTool.new.execute(query: "ultima noticia", type: "news")

        assert_equal :success, result[:status],
                     "fallback Tavily devolveu resultado - deve ser sucesso mesmo com SearXNG zerado"
        assert_requested(:get, /searxng:8080\/search/, times: 1)
        assert_equal 1, conv.reload.web_search_count,
                     "1 run de busca = 1 increment, mesmo que 2 provedores tenham sido chamados"
      end
    end
