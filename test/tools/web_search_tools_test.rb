# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/web_search_tools"

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

  test "time_range é anexado como param SearXNG quando válido" do
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

  test "sem time_range, SearXNG é chamado sem o param" do
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

  test "guarda lexical reprova a busca inteira quando os resultados são lixo (caso Roblox medido)" do
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
  test "flexão de plural não derruba a manchete correta (coleta real da Argentina)" do
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

  test "resultado vazio ainda é cacheado por instantes para não martelar o SearXNG" do
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
end
