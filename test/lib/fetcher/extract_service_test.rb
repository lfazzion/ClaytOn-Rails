# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/extract_service"

class Fetcher::ExtractServiceTest < ActiveSupport::TestCase
  ARTICLE = <<~HTML
    <html><head>
      <title>Guia de deploy</title>
      <meta name="description" content="Como publicar">
      <meta property="og:site_name" content="Docs Example">
    </head><body><article>
      <h1>Guia de deploy</h1>
      <p>#{'Parágrafo com conteúdo real o bastante para não ser considerado magro. ' * 10}</p>
      <ul><li>Passo um</li><li>Passo dois</li></ul>
    </article></body></html>
  HTML

  setup do
    Rails.cache.clear
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    Fetcher::PageFetcher.stubs(:hard_domains).returns([])
  end

  def stub_page(url, body: ARTICLE, status: 200, content_type: "text/html; charset=utf-8")
    stub_request(:get, url).to_return(status: status, body: body, headers: { "Content-Type" => content_type })
  end

  test "caminho barato resolve sem subir Chrome" do
    stub_page("http://docs.test/guia")
    Fetcher::PageFetcher.any_instance.expects(:call).never

    result = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_nil result[:error]
    assert_equal "static", result[:metadata]["source"]
    assert_includes result[:content], "# Guia de deploy"
    assert_includes result[:content], "- Passo um"
  end

  test "contrato: requested_url é a URL pedida e url é a final" do
    stub_request(:get, "http://docs.test/velho")
      .to_return(status: 301, headers: { "Location" => "http://docs.test/novo" })
    stub_page("http://docs.test/novo")

    result = Fetcher::ExtractService.call("http://docs.test/velho")

    assert_equal "http://docs.test/velho", result[:requested_url]
    assert_equal "http://docs.test/novo", result[:url]
  end

  test "metadata carrega título, descrição e site" do
    stub_page("http://docs.test/guia")

    result = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_equal "Guia de deploy", result[:title]
    assert_equal "Como publicar", result[:metadata]["description"]
    assert_equal "Docs Example", result[:metadata]["site_name"]
  end

  test "página magra escala para o Chrome" do
    stub_page("http://spa.test/", body: "<html><body><div id='root'></div></body></html>")

    Fetcher::PageFetcher.any_instance.expects(:call)
      .with("http://spa.test/", include_html: true)
      .returns(
        title: "App", url: "http://spa.test/", content: "texto renderizado",
        article_html: "<h1>Renderizado</h1><p>#{'conteudo ' * 60}</p>",
        cache_age_seconds: 0
      )

    result = Fetcher::ExtractService.call("http://spa.test/")

    assert_nil result[:error]
    assert_equal "browser", result[:metadata]["source"]
    assert_includes result[:content], "# Renderizado"
  end

  test "escalada que falha não apaga o resultado estático" do
    thin = "<html><title>T</title><body><p>curto</p></body></html>"
    stub_page("http://spa.test/", body: thin)
    Fetcher::PageFetcher.any_instance.expects(:call).raises(Fetcher::PageFetcher::RenderTimeout)

    result = Fetcher::ExtractService.call("http://spa.test/")

    assert_nil result[:error]
    assert_includes result[:content], "curto"
  end

  test "hard domain vai direto pro browser sem tentar o estático" do
    Fetcher::PageFetcher.stubs(:hard_domains).returns(["duro.test"])
    Fetcher::PageFetcher.any_instance.expects(:call)
      .returns(title: "D", url: "http://duro.test/", content: "via nodriver", article_html: "", cache_age_seconds: 0)

    result = Fetcher::ExtractService.call("http://duro.test/")

    assert_equal "via nodriver", result[:content]
    assert_not_requested :get, "http://duro.test/"
  end

  test "URL bloqueada vira erro por URL, não exceção" do
    result = Fetcher::ExtractService.call("http://127.0.0.1/admin")

    assert_match(/privado|interno/i, result[:error])
    assert_nil result[:content]
    assert_equal "http://127.0.0.1/admin", result[:requested_url]
  end

  test "PDF não é extraído nem escalado pro Chrome" do
    stub_page("http://docs.test/a.pdf", body: "%PDF-1.4", content_type: "application/pdf")
    Fetcher::PageFetcher.any_instance.expects(:call).never

    result = Fetcher::ExtractService.call("http://docs.test/a.pdf")

    assert_match(/PDF/i, result[:error])
  end

  test "HTTP 404 vira erro na URL" do
    stub_page("http://docs.test/sumiu", body: "<html>nao achei</html>", status: 404)
    Fetcher::PageFetcher.any_instance.stubs(:call).raises(Fetcher::PageFetcher::FetchError, "sem chrome")

    result = Fetcher::ExtractService.call("http://docs.test/sumiu")

    assert_match(/404/, result[:error])
  end

  test "max_chars trunca o conteúdo" do
    stub_page("http://docs.test/guia")

    result = Fetcher::ExtractService.call("http://docs.test/guia", max_chars: 500)

    assert_operator result[:content].length, :<=, 500
  end

  test "max_chars é clampado entre o piso e o teto" do
    stub_page("http://docs.test/guia")

    small = Fetcher::ExtractService.new(max_chars: 1)
    assert_equal Fetcher::ExtractService::MIN_MAX_CHARS, small.instance_variable_get(:@max_chars)

    huge = Fetcher::ExtractService.new(max_chars: 10_000_000)
    assert_equal Fetcher::ExtractService::MAX_MAX_CHARS, huge.instance_variable_get(:@max_chars)
  end

  test "segunda chamada vem do cache sem nova requisição" do
    stub_page("http://docs.test/guia")

    first = Fetcher::ExtractService.call("http://docs.test/guia")
    second = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_equal first[:content], second[:content]
    assert_requested :get, "http://docs.test/guia", times: 1
  end

  test "rate limit por host vira erro na URL" do
    stub_page("http://docs.test/guia")
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)

    result = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_match(/rate limit/i, result[:error])
  end

  test "caminho estático se declara como não-renderizado" do
    stub_page("http://docs.test/guia")

    result = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_equal "static", result[:engine]
    assert_not result[:rendered],
               "sem esse sinal o chamador não distingue leitura completa de degradação silenciosa"
  end

  test "erro também traz rendered: false" do
    result = Fetcher::ExtractService.call("http://127.0.0.1/admin")

    assert_nil result[:engine]
    assert_not result[:rendered]
  end

  test "canal por host responde e nao faz fetch nenhum" do
    canal = Module.new do
      def self.call(url:, response: nil)
        { url: url, title: "do canal", content: "conteudo do canal", metadata: { "source" => "falso" } }
      end
    end
    Fetcher::Channels::Registry.stubs(:for_host).with("canal.test").returns(canal)
    Fetcher::PageFetcher.any_instance.expects(:call).never

    result = Fetcher::ExtractService.call("http://canal.test/x")

    assert_nil result[:error]
    assert_equal "falso", result[:engine]
    assert_equal "conteudo do canal", result[:content]
  end

  test "host sem canal segue o caminho comum" do
    Fetcher::Channels::Registry.stubs(:for_host).returns(nil)
    stub_page("http://docs.test/guia")

    result = Fetcher::ExtractService.call("http://docs.test/guia")

    assert_equal "static", result[:engine]
  end

  test "feed servido como application/xml vira lista de itens" do
    feed = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Feed Real</title>
        <item><title>Item unico</title><link>https://docs.test/1</link></item>
      </channel></rss>
    XML
    stub_page("http://docs.test/feed", body: feed, content_type: "application/xml")

    result = Fetcher::ExtractService.call("http://docs.test/feed")

    assert_equal "rss", result[:engine]
    assert_equal "Feed Real", result[:title]
    assert_includes result[:content], "## Item unico"
  end

  test "XML que nao e feed volta para o caminho comum" do
    sitemap = '<?xml version="1.0"?><sitemapindex><sitemap><loc>https://docs.test/</loc></sitemap></sitemapindex>'
    stub_page("http://docs.test/sitemap.xml", body: sitemap, content_type: "application/xml")
    # O sitemap é magro (bem abaixo de THIN_CONTENT_CHARS), então o caminho comum
    # tenta escalar pro Chrome como faria para qualquer HTML curto — igual ao
    # teste "página magra escala para o Chrome" acima. Sem este stub a chamada
    # bateria de verdade em chrome:9222, que o WebMock bloqueia neste ambiente.
    Fetcher::PageFetcher.any_instance.expects(:call).raises(Fetcher::PageFetcher::RenderTimeout)

    result = Fetcher::ExtractService.call("http://docs.test/sitemap.xml")

    refute_equal "rss", result[:engine]
  end

  test "canal de YouTube sem transcricao devolve error, nunca a casca da pagina" do
    canal = Module.new do
      def self.call(url:, response: nil)
        raise Fetcher::Channels::Error, "vídeo sem faixa de legenda disponível"
      end
    end
    Fetcher::Channels::Registry.stubs(:for_host).with("youtube.com").returns(canal)

    result = Fetcher::ExtractService.call("https://youtube.com/watch?v=X")

    assert_includes result[:error].to_s, "sem faixa de legenda"
    assert_empty result[:content].to_s
    # Falha de canal é prevista, não acidente: sai pelo `rescue` nomeado, com a
    # mensagem limpa. O `rescue StandardError` de último recurso prefixa a classe
    # e loga como erro — se a mensagem vier prefixada, o `rescue` nomeado não
    # pegou e o teste não estaria medindo nada.
    refute_includes result[:error].to_s, "Fetcher::Channels::Error"
  end

  test "cookie expirado devolve error nomeando o dominio" do
    canal = Module.new do
      def self.call(url:, response: nil)
        raise Fetcher::CookieJar::Expired, "youtube.com"
      end
    end
    Fetcher::Channels::Registry.stubs(:for_host).with("youtube.com").returns(canal)

    result = Fetcher::ExtractService.call("https://youtube.com/watch?v=X")

    assert_includes result[:error].to_s, "youtube.com"
    assert_includes result[:error].to_s, "renovar"
    refute_includes result[:error].to_s, "Fetcher::CookieJar::Expired"
  end

  test "raw_content fica nulo — o contrato o trata como opcional" do
    stub_page("http://docs.test/guia")

    assert_nil Fetcher::ExtractService.call("http://docs.test/guia")[:raw_content]
  end

  # A lacuna que so apareceu ao ligar o chatbot no ExtractService: live host serve
  # HTML de sobra (bem acima de THIN_CONTENT_CHARS) e o VALOR que se quer — preco,
  # cotacao — e renderizado por JS. Sem esta regra o estatico voltaria "gordo" e
  # sem o numero, sem nunca escalar, quebrando o caso de uso do `page_fetch`.
  test "live host vai direto pro browser, sem tentar o estatico" do
    Fetcher::TtlPolicy.stubs(:live_host?).with("coingecko.com").returns(true)
    Fetcher::PageFetcher.any_instance.expects(:call)
      .returns(title: "BTC", url: "https://coingecko.com/", content: "preco renderizado",
               article_html: "", cache_age_seconds: 0)

    result = Fetcher::ExtractService.call("https://coingecko.com/")

    assert_equal "chrome", result[:engine]
    assert_equal "preco renderizado", result[:content]
    assert_not_requested :get, "https://coingecko.com/"
  end

  test "host comum continua tentando o estatico primeiro" do
    Fetcher::TtlPolicy.stubs(:live_host?).returns(false)
    stub_page("http://docs.test/guia")
    Fetcher::PageFetcher.any_instance.expects(:call).never

    assert_equal "static", Fetcher::ExtractService.call("http://docs.test/guia")[:engine]
  end
end
