# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x"
require_relative "../../../../lib/fetcher/channels/youtube"

class Fetcher::Channels::XTest < ActiveSupport::TestCase
  # Formato real da api.fxtwitter.com, conferido ao vivo em 04/08/2026.
  TWEET = {
    "code" => 200, "message" => "OK",
    "tweet" => {
      "id" => "20", "url" => "https://x.com/jack/status/20",
      "text" => "just setting up my twttr",
      # `raw_text` e objeto no espelho de verdade, nao String.
      "raw_text" => { "text" => "just setting up my twttr", "facets" => [] },
      "lang" => "en", "created_timestamp" => 1_142_974_214,
      "likes" => 308_439, "retweets" => 124_825, "replies" => 17_966, "views" => nil,
      "author" => { "screen_name" => "jack", "name" => "jack" }
    }
  }.freeze

  test "monta o post com autor, texto e contadores" do
    result = Fetcher::Channels::X.build("https://x.com/jack/status/20", TWEET)

    assert_equal "Post de jack (@jack)", result[:title]
    assert_equal "x", result[:metadata]["source"]
    assert_equal "tweet", result[:metadata]["kind"]
    assert_equal "jack", result[:metadata]["screen_name"]
    assert_equal 308_439, result[:metadata]["likes"]
    assert_equal "2006-03-21T20:50:14Z", result[:metadata]["created_at"]
    assert_includes result[:content], "just setting up my twttr"
    assert_includes result[:content], "308439 curtidas"
  end

  # Regra 3 do CLAUDE.md: métrica ausente é nil, nunca 0 — zero é uma medição.
  test "contador ausente fica nil e some do rodape, nunca vira zero" do
    result = Fetcher::Channels::X.build("https://x.com/jack/status/20", TWEET)

    assert_nil result[:metadata]["views"]
    refute_includes result[:content], "visualizações"
  end

  test "post citado entra no conteudo" do
    com_citacao = TWEET.deep_dup
    com_citacao["tweet"]["quote"] = {
      "raw_text" => { "text" => "texto do citado" }, "author" => { "screen_name" => "outro", "name" => "Outro" }
    }

    result = Fetcher::Channels::X.build("https://x.com/jack/status/20", com_citacao)

    assert_includes result[:content], "## Citando @outro"
    assert_includes result[:content], "texto do citado"
    assert_equal true, result[:metadata]["has_quote"]
  end

  # Sem a nota, o leitor recebe a afirmação sem o que a contesta.
  test "nota da comunidade entra no conteudo" do
    com_nota = TWEET.deep_dup
    com_nota["tweet"]["community_note"] = { "text" => "Contexto: isto e enganoso." }

    result = Fetcher::Channels::X.build("https://x.com/jack/status/20", com_nota)

    assert_includes result[:content], "## Nota da comunidade"
    assert_includes result[:content], "Contexto: isto e enganoso."
    assert_equal true, result[:metadata]["community_note"]
  end

  test "payload sem tweet levanta NotFound, nunca conteudo vazio" do
    assert_raises(Fetcher::Channels::X::NotFound) do
      Fetcher::Channels::X.build("https://x.com/jack/status/1", { "code" => 404, "tweet" => nil })
    end
  end

  test "NotFound e um erro de canal, que o ExtractService sabe pegar" do
    assert Fetcher::Channels::X::NotFound < Fetcher::Channels::Error
  end

  test "reconhece as formas de URL de post" do
    {
      "https://x.com/jack/status/20"              => %w[jack 20],
      "https://twitter.com/jack/status/20"        => %w[jack 20],
      "https://www.x.com/jack/statuses/20"        => %w[jack 20],
      "https://x.com/i/status/1234567890"         => %w[i 1234567890],
      "https://x.com/jack/status/20/photo/1"      => %w[jack 20],
      "https://x.com/jack/status/20?s=46&t=abc"   => %w[jack 20]
    }.each do |url, esperado|
      assert_equal esperado, Fetcher::Channels::X.status_from(url), url
    end
  end

  test "perfil, busca e home nao sao post" do
    %w[
      https://x.com/jack
      https://x.com/home
      https://x.com/search?q=ruby
      https://x.com/jack/with_replies
      https://outrosite.test/jack/status/20
    ].each do |url|
      assert_nil Fetcher::Channels::X.status_from(url), url
    end
  end

  test "URL que nao e post nao chega a fazer requisicao" do
    Fetcher::SafeHttpClient.expects(:get).never

    assert_nil Fetcher::Channels::X.call(url: "https://x.com/jack")
  end

  # Deduplicacao ocorre antes da canonicalizacao do permalink: variantes que
  # apontam para o mesmo post (query de rastreio, host legado, sufixo de media)
  # devem colapsar em um unico item canonico e nao antecipar o limite.
  test "deduplicacao canonaliza permalink antes de contar itens unicos" do
    Kernel.stubs(:sleep)
    lotes = [
      [
        raw_post(id: 1001, extras: { "url" => "https://x.com/jack/status/1001?s=20" }),
        raw_post(id: 1001, extras: { "url" => "https://twitter.com/jack/status/1001" }),
        raw_post(id: 1001, extras: { "url" => "https://x.com/jack/status/1001/photo/1", "text" => "dup do photo" }),
        raw_post(id: 2002)
      ]
    ]
    itens = from_timeline(lotes, limit: 10)

    assert_equal 2, itens.size, "duplicatas colapsam em um unico item canonico"
    assert_equal "https://x.com/jack/status/1001", itens.first["url"]
    assert_equal "https://x.com/jack/status/2002", itens.last["url"]
  end
  # A regressao que isto guarda: o fixture original supunha `raw_text` String, o
  # teste passava, e a chamada real morria em `undefined method 'strip' for Hash`.
  test "aceita raw_text como objeto, como String, e ausente" do
    %w[objeto string ausente].each do |forma|
      payload = TWEET.deep_dup
      case forma
      when "objeto"  then payload["tweet"]["raw_text"] = { "text" => "corpo real" }
      when "string"  then payload["tweet"]["raw_text"] = "corpo real"
      when "ausente" then payload["tweet"].delete("raw_text")
      end

      conteudo = Fetcher::Channels::X.build("https://x.com/jack/status/20", payload)[:content]
      esperado = forma == "ausente" ? "just setting up my twttr" : "corpo real"

      assert_includes conteudo, esperado, "forma #{forma}"
    end
  end

  test "nota da comunidade tambem aceita objeto e String" do
    [{ "text" => "nota objeto" }, "nota string"].each do |forma|
      payload = TWEET.deep_dup
      payload["tweet"]["community_note"] = forma

      assert_includes Fetcher::Channels::X.build("https://x.com/jack/status/20", payload)[:content],
                      forma.is_a?(Hash) ? "nota objeto" : "nota string"
    end
  end

  # ---------------------------------------------------------------------------
  # Timeline de perfil (X.timeline) — os posts recentes lidos com a sessão do dono.
  #
  # Nenhum destes seletores foi exercitado ao vivo: a sessão ainda não existe. O
  # que estes testes fixa é o CONTRATO (chaves string, contador ilegível nil,
  # permalink de fora descartado, falha nomeada) — não a marcação do X.
  # ---------------------------------------------------------------------------

  # Página de mentira: devolve um lote por leitura e conta as rolagens. É por
  # `from_timeline_page`, público, que o teste entra sem Chrome — mesma forma do
  # `Reddit.FromSearchPage`.
  class FakePage
    attr_reader :scrolls, :leituras

    def initialize(lotes)
      @lotes = Array(lotes)
      @scrolls = 0
      @leituras = 0
    end

    def evaluate(js)
      return (@scrolls += 1) if js.include?("scrollTo")

      @leituras += 1
      lote = @lotes[[@leituras - 1, @lotes.size - 1].min]
      lote.is_a?(Array) || lote.is_a?(Hash) ? JSON.generate(lote) : lote
    end
  end

  def raw_post(id:, user: "jack", text: "post #{id}", extras: {})
    {
      "url"        => "https://x.com/#{user}/status/#{id}",
      "text"       => text,
      "author"     => "Jack Dorsey",
      "created_at" => "2026-08-05T12:00:00.000Z",
      "likes"      => { "label" => "1234 Likes", "text" => "1.2K" },
      "retweets"   => { "label" => nil, "text" => "3,4 mil" },
      "replies"    => { "label" => nil, "text" => "" }
    }.merge(extras)
  end

  def from_timeline(lotes, user: "jack", limit: 10)
    Fetcher::Channels::X.from_timeline_page(page: FakePage.new(lotes), user: user, limit: limit)
  end

  # MEDIDO AO VIVO em 05/08/2026: o post fixado do perfil era um "Article" (formato
  # longo do X), que NÃO renderiza em `[data-testid="tweetText"]` — voltava com
  # `text` nil enquanto o título e a chamada estavam visíveis na página. O JS passou
  # a ter uma reserva, e o Ruby só precisa não estragá-la: texto que veio pela
  # reserva é texto igual.
  test "post sem tweetText usa o texto de reserva em vez de ficar nil" do
    bruto = raw_post(id: 3001, text: nil, extras: { "text_reserva" => "How to master Seedance 2.5" })
    itens = from_timeline([[bruto]])

    assert_equal 1, itens.size
    assert_equal "How to master Seedance 2.5", itens.first["text"]
  end

  test "reserva nao sobrepoe o texto normal quando ele existe" do
    bruto = raw_post(id: 3002, text: "texto de verdade", extras: { "text_reserva" => "lixo do cabecalho" })

    assert_equal "texto de verdade", from_timeline([[bruto]]).first["text"]
  end

  # MEDIDO AO VIVO em 05/08/2026, com a sessão do dono: `x.com` é SPA React e o
  # `go_to` volta ANTES da hidratação. A primeira leitura devolve zero artigo; seis
  # segundos depois a mesma página tem quatro. A parada por "a contagem não cresceu"
  # confundia isso com página ilegível e a timeline inteira levantava
  # `TimelineFailed` — com a sessão VÁLIDA e o perfil cheio de posts.
  test "primeira leitura vazia e hidratacao da SPA, nao pagina ilegivel" do
    itens = from_timeline([[], [], [raw_post(id: 2001)]])

    assert_equal 1, itens.size
    assert_equal "https://x.com/jack/status/2001", itens.first["url"]
  end

  # O portão continua valendo: página que NUNCA hidrata é ilegível de verdade, e
  # tem que estourar em vez de devolver [] com cara de "perfil sem posts".
  test "pagina que nunca hidrata continua sendo erro nomeado" do
    erro = assert_raises(Fetcher::Channels::X::TimelineFailed) { from_timeline([[], [], [], [], [], []]) }

    assert_match(/sem nenhum post/i, erro.message)
  end

  test "timeline devolve hash de chaves string no mesmo contrato dos outros canais" do
    itens = from_timeline([[raw_post(id: 1001)]])

    assert_equal 1, itens.size
    assert_equal %w[url text author screen_name created_at likes retweets replies].sort, itens.first.keys.sort
    assert_equal "https://x.com/jack/status/1001", itens.first["url"]
    assert_equal "post 1001", itens.first["text"]
    assert_equal "Jack Dorsey", itens.first["author"]
    assert_equal "jack", itens.first["screen_name"]
    assert_equal "2026-08-05T12:00:00Z", itens.first["created_at"]
  end

  # O aria-label do X carrega o número EXATO; o texto visível é abreviado e vira
  # aproximação declarada. O que não pode é aproximação virar zero.
  test "contador exato vem do aria-label e abreviado e convertido" do
    item = from_timeline([[raw_post(id: 1001)]]).first

    assert_equal 1234, item["likes"], "1234 Likes no aria-label ganha do 1.2K visível"
    assert_equal 3400, item["retweets"], "3,4 mil"
  end

  # Regra dura da casa: métrica que não deu para ler é nil. Zero seria um post
  # sem interação nenhuma, que é outro fato.
  test "contador ilegivel fica nil, nunca 0" do
    item = from_timeline([[raw_post(id: 1001)]]).first

    assert_nil item["replies"]
    assert_nil from_timeline([[raw_post(id: 1, extras: { "likes" => nil })]]).first["likes"]
    assert_nil from_timeline([[raw_post(id: 1, extras: { "likes" => { "label" => "Curtir", "text" => "" } })]]).first["likes"]
  end

  test "data ilegivel vira nil, e o post continua valendo" do
    item = from_timeline([[raw_post(id: 1, extras: { "created_at" => "ontem" })]]).first

    assert_nil item["created_at"]
    assert_equal "https://x.com/jack/status/1", item["url"]
  end

  # Reescrever host de link promovido produziria URL do X que não existe — o
  # Reddit já paga essa conta em `permalink`.
  test "permalink fora do x.com e de terceiro sao descartados" do
    lote = [
      raw_post(id: 1001),
      raw_post(id: 2002, user: "outro"),
      raw_post(id: 3003, extras: { "url" => "https://t.co/abcdef" }),
      raw_post(id: 4004, extras: { "url" => nil })
    ]

    itens = from_timeline([lote])

    assert_equal ["https://x.com/jack/status/1001"], itens.map { |i| i["url"] }
  end

  test "sufixo de midia no permalink e cortado para a forma canonica" do
    itens = from_timeline([[raw_post(id: 1, extras: { "url" => "https://x.com/jack/status/1/photo/1" })]])

    assert_equal "https://x.com/jack/status/1", itens.first["url"]
  end

  test "campo nulo do JS nao derruba o item inteiro" do
    vazio = { "url" => "https://x.com/jack/status/1", "text" => nil, "author" => nil,
              "created_at" => nil, "likes" => nil, "retweets" => nil, "replies" => nil }

    item = from_timeline([[vazio]]).first

    assert_equal "https://x.com/jack/status/1", item["url"]
    assert_nil item["text"]
    assert_nil item["author"]
  end

  # Zero artigos na página não é "perfil sem posts": é sessão não aplicada,
  # seletor mudado ou muro de login. Lista vazia aqui o modelo leria como "esse
  # perfil não tem posts" e responderia isso ao usuário.
  test "pagina sem nenhum artigo vira erro nomeado, nunca lista vazia" do
    erro = assert_raises(Fetcher::Channels::X::TimelineFailed) { from_timeline([[]]) }

    assert_kind_of Fetcher::Channels::Error, erro, "a tool faz rescue de Channels::Error"
    assert_includes erro.message, "x.com"
  end

  # Artigo na página e NENHUM permalink legível não é "perfil só de repost": o
  # repost traz permalink do X (o do autor original), então ele passa por aqui.
  # Zero permalinks é o seletor do link do carimbo de hora tendo mudado — e
  # devolver [] faz o modelo responder "esse perfil não postou nada", que é a
  # mesma falha silenciosa que a página sem artigo já evita.
  test "artigos sem nenhum permalink legivel viram erro, nunca lista vazia" do
    Kernel.stubs(:sleep)
    cegos = Array.new(3) { |i| raw_post(id: i + 1, extras: { "url" => nil }) }

    erro = assert_raises(Fetcher::Channels::X::TimelineFailed) { from_timeline([cegos]) }

    assert_includes erro.message, "permalink"
    assert_includes erro.message, "x.com"
  end

  # Controle do teste acima: com permalink legível, "nenhum post é deste perfil"
  # continua sendo RESPOSTA. Quem esvaziou foi o filtro de autor, não a página.
  test "timeline so de post de terceiro continua sendo resposta, nao erro" do
    Kernel.stubs(:sleep)
    itens = from_timeline([[raw_post(id: 1, user: "outro"), raw_post(id: 2, user: "terceiro")]])

    assert_equal [], itens
  end

  test "JS que devolveu null vira erro, nao zero posts" do
    assert_raises(Fetcher::Channels::X::TimelineFailed) { from_timeline([nil]) }
    assert_raises(Fetcher::Channels::X::TimelineFailed) { from_timeline(["{nao json"]) }
  end

  test "pagina sem artigo nao gasta rolagem" do
    page = FakePage.new([[]])

    assert_raises(Fetcher::Channels::X::TimelineFailed) do
      Fetcher::Channels::X.from_timeline_page(page: page, user: "jack", limit: 10)
    end
    assert_equal 0, page.scrolls
  end

  test "para de rolar assim que junta o limite pedido" do
    page = FakePage.new([[raw_post(id: 1), raw_post(id: 2), raw_post(id: 3)]])

    itens = Fetcher::Channels::X.from_timeline_page(page: page, user: "jack", limit: 2)

    assert_equal 2, itens.size
    assert_equal 0, page.scrolls, "já tinha o que foi pedido — rolar seria requisição de graça"
  end

  test "rola no maximo SCROLL_PASSES vezes e junta as passadas sem duplicar" do
    Kernel.stubs(:sleep)
    lotes = [
      [raw_post(id: 1)],
      [raw_post(id: 1), raw_post(id: 2)],
      [raw_post(id: 1), raw_post(id: 2), raw_post(id: 3)],
      [raw_post(id: 1), raw_post(id: 2), raw_post(id: 3), raw_post(id: 4)],
      [raw_post(id: 5)]
    ]
    page = FakePage.new(lotes)

    itens = Fetcher::Channels::X.from_timeline_page(page: page, user: "jack", limit: 50)

    assert_equal Fetcher::Channels::X::SCROLL_PASSES, page.scrolls
    assert_equal %w[1 2 3 4], itens.map { |i| i["url"].split("/").last }
  end

  test "para de rolar quando a contagem nao cresce" do
    Kernel.stubs(:sleep)
    page = FakePage.new([[raw_post(id: 1)]])

    Fetcher::Channels::X.from_timeline_page(page: page, user: "jack", limit: 50)

    assert_equal 1, page.scrolls, "uma rolagem que não trouxe nada novo encerra a leitura"
  end

  test "limite e clampado no piso e no teto da classe" do
    Kernel.stubs(:sleep)
    muitos = Array.new(40) { |i| raw_post(id: i + 1) }

    assert_equal 1, from_timeline([muitos], limit: 0).size, "limite invalido nao pode virar lista vazia"
    assert_equal Fetcher::Channels::X::MAX_RESULTADOS, from_timeline([muitos], limit: 999).size
  end

  # ---------------------------------------------------------------------------
  # timeline() — os portões que rodam ANTES de gastar Chrome.
  # ---------------------------------------------------------------------------

  test "handle invalido nao gasta browser nem cota" do
    Fetcher::BrowserSession.expects(:with_page).never
    Fetcher::HostRateLimiter.expects(:exceeded?).never

    ["", "   ", "nome com espaco", "handle-com-hifen", "a" * 16, "@", "jack/status/20"].each do |ruim|
      assert_raises(Fetcher::Channels::X::InvalidHandle, ruim) { Fetcher::Channels::X.timeline(user: ruim) }
    end
  end

  test "aceita o handle com e sem arroba e navega no perfil" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::BrowserSession.expects(:with_page).with("https://x.com/jack").twice.returns([])

    Fetcher::Channels::X.timeline(user: "@jack")
    Fetcher::Channels::X.timeline(user: " jack ")
  end

  # Sem sessão o x.com devolve casca de SPA — medido em 04/08. Lista vazia daí
  # seria lida como "esse perfil não tem posts".
  test "sem sessao no jar levanta Expired nomeando x.com, antes do browser" do
    Fetcher::CookieJar.stubs(:valid?).returns(false)
    Fetcher::BrowserSession.expects(:with_page).never

    erro = assert_raises(Fetcher::CookieJar::Expired) { Fetcher::Channels::X.timeline(user: "jack") }

    assert_equal "x.com", erro.domain
  end

  # `HostRateLimiter.exceeded?` INCREMENTA o contador. Se ele correr antes do
  # portão de sessão, uma chamada que nem tinha como funcionar queima a única
  # leitura/min da conta do dono — e a próxima, com sessão, é recusada.
  test "chamada sem sessao nao queima cota do limitador" do
    Fetcher::CookieJar.stubs(:valid?).returns(false)
    Fetcher::HostRateLimiter.expects(:exceeded?).never
    Fetcher::BrowserSession.expects(:with_page).never

    assert_raises(Fetcher::CookieJar::Expired) { Fetcher::Channels::X.timeline(user: "jack") }
  end

  # No X quem paga a rajada é a CONTA PESSOAL do dono, não só o IP. A rajada é mais
  # frouxa que a do YouTube de propósito (4/min contra 2/min), para bot e reader não
  # se atropelarem no mesmo minuto — mas o VOLUME sustentado é mais apertado: 30/h
  # é 1/2/min de média, metade do que o teto do YouTube permitiria.
  test "limitador barra antes de abrir o browser, e o volume sustentado e mais conservador que o do youtube" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.expects(:exceeded?)
                            .with("x.com", **Fetcher::Channels::X::TIMELINE_BUDGET)
                            .returns(true)
    Fetcher::BrowserSession.expects(:with_page).never

    erro = assert_raises(Fetcher::Channels::X::RateLimited) { Fetcher::Channels::X.timeline(user: "jack") }

    assert_includes erro.message, "x.com"
    assert Fetcher::Channels::X::RateLimited < Fetcher::Channels::Error
    assert_operator Fetcher::Channels::X::TIMELINE_BUDGET[:per_hour], :<=,
                    Fetcher::Channels::Youtube::MAX_PER_WINDOW * 60
  end

  test "o JS de timeline usa os seletores levantados e tem try/catch por campo" do
    js = Fetcher::Channels::X::TIMELINE_JS

    assert_includes js, 'article[data-testid="tweet"]'
    assert_includes js, '[data-testid="tweetText"]'
    assert_includes js, "time"
    %w[like retweet reply].each { |c| assert_includes js, c }
    # O JS de produção devolve {items, empty} (hash) — não um Array puro. O teste
    # de contrato fixa que ambas as chaves estão presentes no JS, para que a
    # camada de leitura Ruby dependa delas sem ramo de compatibilidade.
    assert_match /items\s*:/, js
    assert_match /empty\s*:/, js
    assert_match /empty_state_header_text/, js
    # Um seletor que mudou tem de virar campo nulo, não exceção que derruba a
    # chamada inteira — é o que o Reddit já faz. Cada helper tem seu próprio
    # try/catch, verificado individualmente em vez de por contagem global.
    %w[txt permalink quando autor reserva contador].each do |helper|
      bloco = extract_timeline_js_function(js, helper)
      refute_nil bloco, "helper #{helper} não declarado em TIMELINE_JS"
      assert_match(/try/, bloco, "helper #{helper} não protege com try")
      assert_match(/catch/, bloco, "helper #{helper} não tem catch")
    end
    # Rodada 3 (sol 13/08): o teste lexical acima pode ser enganado por try/catch
    # que exista SÓ em comentário. O contrato real: o try de cada helper está em
    # código executável (linha que não começa com //).
    %w[txt permalink quando autor reserva contador].each do |helper|
      bloco = extract_timeline_js_function(js, helper)
      linha_try = bloco.to_s.lines.find { |l| l.include?("try") && !l.strip.start_with?("//") }
      refute_nil linha_try, "helper #{helper}: try/catch deve estar em código executável (não só em comentário)"
    end
    refute_match(/querySelector\(\s*['"]\s*>/, js)
  end

  test "extract_timeline_js_function isola o último helper (contador) sem vazar o try/catch do IIFE externo" do
    js = Fetcher::Channels::X::TIMELINE_JS
    bloco = extract_timeline_js_function(js, "contador")
    refute_nil bloco
    assert_match(/try/, bloco)
    assert_match(/catch/, bloco)
    # O IIFE externo tem `var out = []` — se contador vazar, isto aparece:
    refute_match(/var out = \[\]/, bloco)
  end

  test "extract_timeline_js_function devolve nil e refute_nil falha quando o helper não existe" do
    js = Fetcher::Channels::X::TIMELINE_JS
    bloco = extract_timeline_js_function(js, "nao_existe")
    assert_nil bloco, "helper inexistente deveria devolver nil"
  end

  # O JS de produção devolve {items, empty} (hash). Este teste usa FakePage
  # devolvendo esse formato real e confirma que from_timeline_page decodifica e
  # devolve o item — sem ele, a camada Ruby só é testada contra Array (ramo de
  # compatibilidade que produção nunca emite).
  test "from_timeline_page aceita o formato real do JS ({items, empty}) e devolve os posts" do
    Kernel.stubs(:sleep)
    post = raw_post(id: 7001, text: "formato real do hash")
    hash_real = { "items" => [post], "empty" => false }

    itens = from_timeline([hash_real])

    assert_equal 1, itens.size
    assert_equal "https://x.com/jack/status/7001", itens.first["url"]
    assert_equal "formato real do hash", itens.first["text"]
  end

  # ---------------------------------------------------------------------------
  # Busca por assunto (X.search / X.from_search_page)
  # ---------------------------------------------------------------------------

  def from_search(lotes, limit: 10)
    Fetcher::Channels::X.from_search_page(page: FakePage.new(lotes), limit: limit)
  end

  # Extrai o corpo de uma função JS nomeada de TIMELINE_JS, delimitando a
  # declaração para in-specie. Usado para validar try/catch por helper, e não
  # por contagem global de "catch" no arquivo inteiro. Cada helper é extraído
  # do ponto da declaração `function NAME(` até o fechamento do bloco de chaves
  # da própria função — contagem de profundidade, não busca do próximo
  # `function`, para que o último helper (contador) não inclua o try/catch do
  # IIFE externo.
  def extract_timeline_js_function(js, name)
    marker = "function #{name}"
    start_idx = js.index(marker)
    return nil unless start_idx

    after = js[(start_idx + marker.length)..-1]

    # Encontre o início do bloco da função: o primeiro `{` após os parâmetros.
    # Os helpers têm todos a forma `function NAME(arg) {` ou `function NAME {`
    # com o `{` na mesma linha — `index("{")` pega o abre-chave da assinatura.
    body_start = after.index("{")
    return nil unless body_start

    # Conta profundidade de chaves para isolar o bloco desta função. AVISO
    # (Achado E): o extrator NAO exclui strings nem comentários — ele conta
    # qualquer `{`/`}` que apareça no texto, inclusive dentro de string literal
    # ou de um comentário `//`. Os helpers de produção por acaso não contêm
    # `{`/`}` dentro de strings, mas isso é coincidência, não garantia do
    # extrator. Não tratar como robustez: uma chave dentro de string trunca a
    # extração (ver teste que documenta essa limitação).
    depth = 0
    body_start.upto(after.length - 1) do |i|
      ch = after[i]
      if ch == "{"
        depth += 1
      elsif ch == "}"
        depth -= 1
        return after[0..i] if depth.zero?
      end
    end
    # Nunca deveria chegar aqui (JS bem formado sempre fecha), mas se o
    # heredoc estiver truncado devolve nil para falhar explícito:
    nil
  end

  # Achado E (GREEN): o extrator so conta profundidade de chaves e NAO exclui
  # strings/comentarios. Uma chave de fechamento dentro de string literal
  # trunca a extracao. Registramos esse comportamento REAL como contrato
  # explicito (para nao reintroduzir a falsa afirmacao de robustez): o bloco
  # extraido e interrompido pela `}` da string e nao contem o try/catch.
  test "extractor e cego a chaves dentro de string: documenta a limitacao real (sem enganar)" do
    js = <<~JS
      (function () {
        function demo(el) {
          var s = "chave}dentro";
          try { return el; } catch (e) { return null; }
        }
        var out = [];
      })();
    JS
    bloco = extract_timeline_js_function(js, "demo")
    refute_nil bloco
    # Comportamento REAL: a `}` dentro de "chave}dentro" decrementa a
    # profundidade e trunca o bloco ANTES do try/catch. O teste afirma essa
    # limitacao de forma honesta (reflete o que o extrator faz de verdade).
    refute_match(/try/, bloco, "extrator e cego a strings: a `}` na string trunca e o try/catch some do bloco")
  end

  test "from_search_page com busca com resultados devolve hash de chaves string" do
    lote = [raw_post(id: 5001, user: "alice", text: "ruby on rails 8.1")]
    itens = from_search([lote])

    assert_equal 1, itens.size
    assert_equal %w[url text author screen_name created_at likes retweets replies].sort, itens.first.keys.sort
    assert_equal "https://x.com/alice/status/5001", itens.first["url"]
    assert_equal "ruby on rails 8.1", itens.first["text"]
    assert_equal "alice", itens.first["screen_name"]
  end

  test "from_search_page com busca vazia legitima devolve array vazio sem erro" do
    Kernel.stubs(:sleep)
    itens = from_search([{ "items" => [], "empty" => true }])

    assert_equal [], itens
  end

  test "from_search_page sem artigos e sem marcador de estado vira SearchFailed" do
    Kernel.stubs(:sleep)
    erro = assert_raises(Fetcher::Channels::X::SearchFailed) { from_search([[]]) }

    assert_kind_of Fetcher::Channels::Error, erro
    assert_includes erro.message, "busca"
  end

  test "from_search_page com JSON invalido vira SearchFailed" do
    erro = assert_raises(Fetcher::Channels::X::SearchFailed) { from_search([nil]) }

    assert_kind_of Fetcher::Channels::Error, erro
    assert_includes erro.message, "busca"
  end

  test "from_search_page com artigos sem permalink legivel vira SearchFailed" do
    Kernel.stubs(:sleep)
    cegos = Array.new(3) { |i| raw_post(id: i + 1, extras: { "url" => nil }) }

    erro = assert_raises(Fetcher::Channels::X::SearchFailed) { from_search([cegos]) }

    assert_includes erro.message, "permalink"
    assert_includes erro.message, "busca"
  end

  test "search com query vazia devolve lista vazia sem abrir browser" do
    Fetcher::BrowserSession.expects(:with_page).never

    assert_equal [], Fetcher::Channels::X.search(query: "   ")
  end

  # ---------------------------------------------------------------------------
  # Transporte GraphQL vs Browser (T5)
  # ---------------------------------------------------------------------------

  test "busca por assunto usa XGraphql e nunca abre browser no default" do
    Fetcher::BrowserSession.expects(:with_page).never
    Fetcher::Channels::XGraphql.expects(:search).with(query: "ruby rails", limit: 10).returns([])

    Fetcher::Channels::X.search(query: "ruby rails")
  end

  test "X_SEARCH_TRANSPORT=browser usa search_via_browser em vez de graphql" do
    Fetcher::Channels::XGraphql.expects(:search).never
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::BrowserSession.expects(:with_page)
                           .with("https://x.com/search?q=ruby+rails&f=live&src=typed_query")
                           .returns([])

    ENV["X_SEARCH_TRANSPORT"] = "browser"
    begin
      Fetcher::Channels::X.search(query: "ruby rails")
    ensure
      ENV.delete("X_SEARCH_TRANSPORT")
    end
  end

  test "transporte invalido levanta InvalidTransport" do
    Fetcher::Channels::XGraphql.expects(:search).never
    Fetcher::BrowserSession.expects(:with_page).never

    erro = assert_raises(Fetcher::Channels::X::InvalidTransport) do
      ENV["X_SEARCH_TRANSPORT"] = "invalido"
      begin
        Fetcher::Channels::X.search(query: "ruby rails")
      ensure
        ENV.delete("X_SEARCH_TRANSPORT")
      end
    end

    assert_includes erro.message, "transporte inválido"
    assert_includes erro.message, "graphql"
    assert_includes erro.message, "browser"
  end

  test "XGraphql falhando nao aciona browser automaticamente" do
    Fetcher::Channels::XGraphql.stubs(:search).raises(Fetcher::Channels::XGraphql::GraphQLError, "falha")
    Fetcher::BrowserSession.expects(:with_page).never

    assert_raises(Fetcher::Channels::XGraphql::GraphQLError) { Fetcher::Channels::X.search(query: "ruby rails") }
  end

  # ---------------------------------------------------------------------------
  # Testes atualizados para refletir novo contrato (default graphql; browser so com env)
  # ---------------------------------------------------------------------------

  test "search com X_SEARCH_TRANSPORT=browser navega na URL de busca com f=live e o termo codificado" do
    Fetcher::Channels::XGraphql.expects(:search).never
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::BrowserSession.expects(:with_page)
                           .with("https://x.com/search?q=ruby+rails&f=live&src=typed_query")
                           .returns([])

    ENV["X_SEARCH_TRANSPORT"] = "browser"
    begin
      Fetcher::Channels::X.search(query: "ruby rails")
    ensure
      ENV.delete("X_SEARCH_TRANSPORT")
    end
  end

  test "search com X_SEARCH_TRANSPORT=browser e rate limit estoura RateLimited nomeando x.com e o orcamento de busca" do
    Fetcher::Channels::XGraphql.expects(:search).never
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.expects(:exceeded?)
                            .with("x.com", **Fetcher::Channels::X::SEARCH_BUDGET)
                            .returns(true)
    Fetcher::BrowserSession.expects(:with_page).never

    ENV["X_SEARCH_TRANSPORT"] = "browser"
    begin
      erro = assert_raises(Fetcher::Channels::X::RateLimited) { Fetcher::Channels::X.search(query: "ruby") }

      assert_includes erro.message, "x.com"
      assert_includes erro.message, "search"
      assert Fetcher::Channels::X::RateLimited < Fetcher::Channels::Error
    ensure
      ENV.delete("X_SEARCH_TRANSPORT")
    end
  end

end
