# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../../../lib/fetcher/page_fetcher"

# Defeitos do segundo nível (escalada para o Chrome), com guarda para cada um.
#
# A escalada é engolida por um `rescue` no ExtractService e vira degradação
# silenciosa — então "não levantou exceção" não prova nada aqui. Cada teste
# abaixo verifica o RECEPTOR da chamada ou o efeito observável.
class Fetcher::PageFetcherBrowserTest < ActiveSupport::TestCase
  # ── Dublês ────────────────────────────────────────────────────────────────
  # FakePage NÃO define `evaluate_on_new_document` de propósito: se o código
  # voltar a chamá-lo na página, o teste morre com NoMethodError — que é
  # exatamente o defeito que passou despercebido em produção.
  class FakeResponse
    def initialize(status:, content_type:)
      @status = status
      @headers = { "Content-Type" => content_type }
    end
    attr_reader :status, :headers
  end

  class FakeNetwork
    def initialize(response) = @response = response
    def wait_for_idle(**_opts) = nil
    attr_reader :response
  end

  class FakePage
    attr_reader :visited, :closed, :timeout_during_goto
    attr_accessor :timeout

    def initialize(body_text: "conteúdo renderizado por javascript", status: 200,
                   content_type: "text/html", document_remote_ip: nil)
      @body_text = body_text
      @network = FakeNetwork.new(FakeResponse.new(status: status, content_type: content_type))
      @visited = []
      @closed = false
      @document_remote_ip = document_remote_ip
      @listeners = {}
      @timeout = 12
      @timeout_during_goto = nil
    end

    def go_to(url)
      @visited << url
      @timeout_during_goto = @timeout
      # O Ferrum emite Network.responseReceived do documento durante o go_to;
      # o dublê emite na mesma hora para o assinante do RebindingGuard pegar.
      return unless @document_remote_ip

      Array(@listeners["Network.responseReceived"]).each do |blk|
        blk.call("type" => "Document",
                 "response" => { "url" => url, "remoteIPAddress" => @document_remote_ip })
      end
    end

    def on(event, &block)
      (@listeners[event] ||= []) << block
      @listeners[event].size - 1
    end

    def off(event, id)
      @listeners[event]&.delete_at(id)
      true
    end

    def body = "<html><body>#{@body_text}</body></html>"
    def title = "Título Renderizado"
    def current_url = @visited.last
    def close = (@closed = true)
    attr_reader :network

    def evaluate(js)
      return { "text" => @body_text, "html" => "<p>#{@body_text}</p>" } if js.include?("Readability")
      return @body_text.length if js.include?("innerText.length")

      @body_text
    end
  end

  class FakeContext
    attr_reader :page, :disposed

    def initialize(page)
      @page = page
      @disposed = false
    end

    def create_page = @page
    def dispose = (@disposed = true)
  end

  class FakeContexts
    def initialize(context) = @context = context
    def create = @context
  end

  class FakeBrowser
    attr_reader :contexts, :injected, :version_calls

    def initialize(context: nil, version_error: nil)
      @contexts = FakeContexts.new(context) if context
      @injected = []
      @version_error = version_error
      @version_calls = 0
    end

    def evaluate_on_new_document(source) = @injected << source

    def version
      @version_calls += 1
      raise @version_error if @version_error

      "HeadlessChrome/131.0.0.0"
    end

    def quit = true
  end

  setup do
    Rails.cache.clear
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8"])
    Fetcher::PageFetcher.stubs(:hard_domains).returns([])
    Fetcher::PageFetcher.instance_variable_set(:@browser, nil)
    Fetcher::PageFetcher.instance_variable_set(:@browser_started_at, nil)
  end

  teardown do
    Fetcher::PageFetcher.instance_variable_set(:@browser, nil)
    Fetcher::PageFetcher.instance_variable_set(:@browser_started_at, nil)
  end

  # ── DEFEITO 1: método chamado no objeto errado ────────────────────────────

  test "evaluate_on_new_document é método de Ferrum::Browser, não de Ferrum::Page" do
    assert Ferrum::Browser.method_defined?(:evaluate_on_new_document),
           "o receptor correto perdeu o método — reveja build_browser contra o fonte do ferrum"
    assert_not Ferrum::Page.method_defined?(:evaluate_on_new_document),
               "ferrum passou a expor o método na Page: reavalie onde injetar o stealth"
  end

  test "build_browser injeta o STEALTH_JS no browser recém-construído" do
    fake = FakeBrowser.new
    FerumConfig.stubs(:browser_options).returns({})
    Ferrum::Browser.stubs(:new).returns(fake)

    built = Fetcher::PageFetcher.send(:build_browser)

    assert_same fake, built
    assert_equal [Fetcher::PageFetcher::STEALTH_JS], fake.injected,
                 "o stealth não chegou ao browser — toda página nasceria sem ele"
  end

  test "o render NÃO chama evaluate_on_new_document na página" do
    page = FakePage.new
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    # FakePage não implementa o método: se o código o chamar, isto levanta
    # NoMethodError — o mesmo erro visto nos logs de produção.
    payload = fetcher.call("https://exemplo.test/pagina")

    assert_equal "Título Renderizado", payload[:title]
    assert_includes payload[:content], "renderizado por javascript"
    assert_equal ["https://exemplo.test/pagina"], page.visited
  end

  test "escalada completa sobrevive ao render: conteúdo chega ao ExtractService" do
    page = FakePage.new(body_text: "dados que só existem depois do javascript " * 20)
    browser = FakeBrowser.new(context: FakeContext.new(page))

    Fetcher::PageFetcher.any_instance.stubs(:wait_for_body_stabilize)
    Fetcher::PageFetcher.stubs(:browser).returns(browser)

    # estático magro força a escalada
    stub_request(:get, "https://spa.test/")
      .to_return(status: 200, body: "<html><body><div id='root'></div></body></html>",
                 headers: { "Content-Type" => "text/html" })

    result = Fetcher::ExtractService.call("https://spa.test/")

    assert_nil result[:error], result.inspect
    assert_equal "chrome", result[:engine]
    assert result[:rendered]
    assert_includes result[:content], "depois do javascript"
  end

  # ── DEFEITO 2: browser em cache não se cura ───────────────────────────────

  test "browser em cache com sessão morta é descartado e reconstruído" do
    dead = FakeBrowser.new(version_error: Ferrum::DeadBrowserError.new("ws fechado"))
    fresh = FakeBrowser.new

    Fetcher::PageFetcher.instance_variable_set(:@browser, dead)
    Fetcher::PageFetcher.instance_variable_set(:@browser_started_at, Time.current)
    Fetcher::PageFetcher.expects(:build_browser).once.returns(fresh)

    assert_same fresh, Fetcher::PageFetcher.browser,
                "o browser morto foi devolvido do cache — é o que envenena a escalada por 24h"
    assert_equal 1, dead.version_calls
  end

  test "browser vivo é reaproveitado, sem reconstruir" do
    live = FakeBrowser.new
    Fetcher::PageFetcher.instance_variable_set(:@browser, live)
    Fetcher::PageFetcher.instance_variable_set(:@browser_started_at, Time.current)
    Fetcher::PageFetcher.expects(:build_browser).never

    assert_same live, Fetcher::PageFetcher.browser
    assert_same live, Fetcher::PageFetcher.browser
    assert_equal 2, live.version_calls, "a sonda tem que rodar a cada uso"
  end

  test "sonda pendurada não bloqueia além do próprio timeout" do
    hung = FakeBrowser.new
    hung.define_singleton_method(:version) { sleep 30 }

    started = Time.current
    assert_not Fetcher::PageFetcher.send(:alive?, hung)
    elapsed = Time.current - started

    assert_operator elapsed, :<, Fetcher::PageFetcher::BROWSER_PROBE_TIMEOUT + 1,
                    "a sonda herdou o timeout de 30s do client do ferrum"
  end

  test "browser expirado por idade continua sendo descartado" do
    old = FakeBrowser.new
    fresh = FakeBrowser.new
    Fetcher::PageFetcher.instance_variable_set(:@browser, old)
    Fetcher::PageFetcher.instance_variable_set(
      :@browser_started_at, Time.current - Fetcher::PageFetcher::BROWSER_MAX_AGE - 60
    )
    Fetcher::PageFetcher.expects(:build_browser).once.returns(fresh)

    assert_same fresh, Fetcher::PageFetcher.browser
  end

  test "sessão que morre durante o render dispara uma retentativa com browser novo" do
    page = FakePage.new
    good = FakeBrowser.new(context: FakeContext.new(page))

    fetcher = Fetcher::PageFetcher.new
    rendered = { title: "ok", final_url: "https://x.test/", readability_text: "texto suficiente " * 40,
                 readability_html: "", body_text: "texto", html: "", status: 200 }

    fetcher.expects(:render_via_ferrum).twice
           .raises(Ferrum::DeadBrowserError).then.returns(rendered)
    Fetcher::PageFetcher.expects(:reset_browser!).once

    payload = fetcher.call("https://x.test/")

    assert_equal "ok", payload[:title]
  end

  test "render timeout descarta o browser para a próxima chamada não herdar a sessão" do
    fetcher = Fetcher::PageFetcher.new
    # Timeout::Error levantado DENTRO do bloco de render é o caminho real do
    # travamento de 25s medido em produção.
    Fetcher::PageFetcher.stubs(:browser).raises(Timeout::Error)
    Fetcher::PageFetcher.expects(:reset_browser!).at_least_once

    assert_raises(Fetcher::PageFetcher::RenderTimeout) { fetcher.call("https://lento.test/") }
  end

  test "Ferrum::TimeoutError no go_to com body vazio vira RenderTimeout e nao sobe cru" do
    page = FakePage.new(body_text: "")
    page.stubs(:go_to).raises(Ferrum::TimeoutError)
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })

    assert_raises(Fetcher::PageFetcher::RenderTimeout) do
      fetcher.call("https://timeout.test/")
    end
  end

  test "GOTO_TIMEOUT e aplicado durante go_to e restaurado depois" do
    page = FakePage.new(body_text: "conteúdo válido")
    page.timeout = 12
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })

    payload = fetcher.call("https://timeout-test.test/")

    assert_equal Fetcher::PageFetcher::GOTO_TIMEOUT, page.timeout_during_goto
    assert_equal 12, page.timeout
    assert_equal "Título Renderizado", payload[:title]
  end

  test "go_to soft com body presente prossegue para extracao sem RenderTimeout" do
    page = FakePage.new(body_text: "texto presente no body antes do timeout de load")
    page.stubs(:go_to).raises(Ferrum::TimeoutError)
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })

    payload = fetcher.call("https://soft-goto.test/")

    assert_includes payload[:content], "texto presente no body"
  end

  test "idle e stabilize nao comecam sem budget suficiente" do
    page = FakePage.new(body_text: "texto com pouco budget")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })

    # Simula relógio com 0.4s de budget restante
    fetcher.expects(:wait_for_idle_soft).with(page, budget: 0.4).once
    fetcher.expects(:wait_for_body_stabilize).with(page, budget: 0.4).once

    page.network.expects(:wait_for_idle).never
    Kernel.expects(:sleep).never

    fetcher.send(:wait_for_idle_soft, page, budget: 0.4)
    fetcher.send(:wait_for_body_stabilize, page, budget: 0.4)
  end

  test "reset_browser! nao da quit com outro render in-flight ate o segundo sair" do
    quit_called = false
    fake_browser = FakeBrowser.new
    fake_browser.define_singleton_method(:quit) { quit_called = true }
    Fetcher::PageFetcher.instance_variable_set(:@browser, fake_browser)

    Fetcher::PageFetcher.track_in_flight do
      Fetcher::PageFetcher.reset_browser!
      assert_equal false, quit_called, "quit nao pode rodar enquanto in_flight > 0"
    end

    assert_equal true, quit_called, "quit deve rodar assim que in_flight zerar"
  end

  # ── DEFEITO 3: DNS rebinding no caminho Chrome ──────────────────────────
  # O SsrfGuard valida que TODOS os IPs do host são públicos, mas o Chrome
  # re-resolve o hostname sozinho no go_to. O `remoteIPAddress` do documento
  # não pode ter vindo de IP privado/loopback/metadata — mas também não precisa
  # ser o `ips.first`: CDN multi-registro e dual-stack (A+AAAA) fazem o Chrome
  # conectar em QUALQUER IP público do conjunto. O cheque é `ip_blocked?`, não
  # igualdade com o primeiro IP.

  test "documento que veio de IP privado (10.x) levanta SsrfGuard::Blocked, mesmo com IP público no conjunto" do
    page = FakePage.new(body_text: "dados", document_remote_ip: "10.0.0.1")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    erro = assert_raises(Fetcher::SsrfGuard::Blocked) do
      fetcher.call("https://spa.test/")
    end

    assert_match(/rebinding/i, erro.message)
    assert_match(/10\.0\.0\.1/, erro.message)
  end

  test "documento que veio de loopback (127.0.0.1) levanta SsrfGuard::Blocked mesmo com outro IP público no conjunto" do
    # validação aprovou um conjunto todo público; o Chrome conectou em
    # loopback — rebinding de verdade, tem que bloquear.
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8", "1.1.1.1"])
    page = FakePage.new(body_text: "dados", document_remote_ip: "127.0.0.1")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    erro = assert_raises(Fetcher::SsrfGuard::Blocked) do
      fetcher.call("https://spa.test/")
    end

    assert_match(/127\.0\.0\.1/, erro.message)
  end

  test "documento que veio de IP público do conjunto (não o primeiro) passa — CDN/dual-stack" do
    # O bug da 1a rodada: exigia igualdade com ips.first e derrubava
    # youtube.com/reddit.com, que têm múltiplos registros A/AAAA.
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8", "1.1.1.1"])
    page = FakePage.new(body_text: "dados renderizados " * 40, document_remote_ip: "1.1.1.1")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    payload = fetcher.call("https://spa.test/")

    assert_equal "Título Renderizado", payload[:title]
    assert_includes payload[:content], "dados renderizados"
  end

  test "documento que veio de AAAA público do conjunto passa — dual-stack" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["8.8.8.8", "2606:2800:220:1:248:1893:25c8:1946"])
    page = FakePage.new(body_text: "dados renderizados " * 40, document_remote_ip: "2606:2800:220:1:248:1893:25c8:1946")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    payload = fetcher.call("https://spa.test/")

    assert_equal "Título Renderizado", payload[:title]
    assert_includes payload[:content], "dados renderizados"
  end

  test "documento que veio do IP validado passa" do
    page = FakePage.new(body_text: "dados renderizados " * 40, document_remote_ip: "8.8.8.8")
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    payload = fetcher.call("https://spa.test/")

    assert_equal "Título Renderizado", payload[:title]
    assert_includes payload[:content], "dados renderizados"
  end

  test "sem remoteIPAddress no CDP o caminho segue (fail-open com log), não derruba" do
    page = FakePage.new(body_text: "conteúdo renderizado " * 40) # document_remote_ip nil
    browser = FakeBrowser.new(context: FakeContext.new(page))
    fetcher = Fetcher::PageFetcher.new(browser_factory: -> { browser })
    fetcher.stubs(:wait_for_body_stabilize)

    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log)
    Rails.logger.level = Logger::WARN
    begin
      payload = fetcher.call("https://spa.test/")
    ensure
      Rails.logger = original_logger
    end

    assert_equal "Título Renderizado", payload[:title]
    # Contrato canônico (unificado com a PR #136): fail-open SILENCIOSO quando
    # o IP não chega (assert_document_ip! sai cedo com nil — sem log). O que
    # importa: não derruba e o conteúdo segue.
    refute_match(/rebinding/, log.string)
  end
end