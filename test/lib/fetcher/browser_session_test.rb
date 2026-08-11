# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/browser_session"

class Fetcher::BrowserSessionTest < ActiveSupport::TestCase
  # `Ferrum::Cookies#set` é `def set(options)` — UM hash POSICIONAL, não keywords
  # (ferrum-0.17.2/lib/ferrum/cookies.rb:118). O dublê copia a assinatura real:
  # um dublê com `set(**kwargs)` aceitaria chamadas que o Ferrum recusaria.
  class FakeCookies
    attr_reader :postos

    def initialize
      @postos = []
    end

    def set(options)
      @postos << options
      true
    end
  end

  class FakePage
    attr_reader :cookies, :visitado, :fechada

    def initialize(document_remote_ip: nil)
      @cookies = FakeCookies.new
      @fechada = false
      @document_remote_ip = document_remote_ip
      @listeners = {}
    end

    def go_to(url)
      @visitado = url
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

    def current_url = @visitado
    def close = @fechada = true
  end

  class FakeContext
    attr_reader :page, :descartado

    def initialize(page)
      @page = page
      @descartado = false
    end

    def create_page = @page
    def dispose = @descartado = true
  end

  class FakeContexts
    def initialize(context) = @context = context
    def create = @context
  end

  class FakeBrowser
    attr_reader :contexts

    def initialize(context) = @contexts = FakeContexts.new(context)
  end

  setup do
    @page = FakePage.new
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))
    # O `with_page` valida a URL com o SsrfGuard antes de gastar browser —
    # sem o stub, isto resolveria DNS de verdade no ambiente de teste.
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    Fetcher::CookieJar.store!(
      domain: "youtube.com",
      cookies: [{ "name" => "SID", "value" => "abc", "domain" => ".youtube.com", "path" => "/" }],
      expires_at: 7.days.from_now
    )
  end

  test "injeta o cookie ANTES de navegar" do
    ordem = []
    @page.cookies.stubs(:set).with { |**_| ordem << :cookie; true }
    @page.stubs(:go_to).with { |_| ordem << :navegou; true }

    Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }

    assert_equal %i[cookie navegou], ordem
  end

  test "passa nome, valor, dominio e path para o CDP" do
    Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }

    posto = @page.cookies.postos.first
    assert_equal "SID", posto[:name]
    assert_equal "abc", posto[:value]
    assert_equal ".youtube.com", posto[:domain]
    assert_equal "/", posto[:path]
  end

  test "devolve o valor do bloco" do
    assert_equal 42, Fetcher::BrowserSession.with_page("https://www.youtube.com/x") { |_p| 42 }
  end

  test "sem sessao viva levanta Expired e nao navega" do
    assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::BrowserSession.with_page("https://reddit.com/r/x") { |_p| :nunca }
    end

    assert_nil @page.visitado
  end

  test "fecha a pagina e descarta o contexto mesmo quando o bloco levanta" do
    assert_raises(RuntimeError) do
      Fetcher::BrowserSession.with_page("https://www.youtube.com/x") { |_p| raise "erro do bloco" }
    end

    assert @page.fechada
    assert @context.descartado
  end

  test "URL privada é recusada antes de gastar browser (invariante enforced)" do
    Fetcher::SsrfGuard.stubs(:resolve_all).with("192.168.1.10").returns(["192.168.1.10"])

    erro = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::BrowserSession.with_page("http://192.168.1.10/admin") { |_p| :nunca }
    end

    assert_match(/privado|interno/i, erro.message)
    assert_nil @page.visitado
  end

  test "documento que veio de IP privado levanta Blocked (DNS rebinding)" do
    @page = FakePage.new(document_remote_ip: "10.0.0.1")
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))

    erro = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }
    end

    assert_match(/rebinding/i, erro.message)
  end

  test "documento que veio de loopback (127.0.0.1) levanta Blocked mesmo com outro IP público no conjunto" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34", "1.1.1.1"])
    @page = FakePage.new(document_remote_ip: "127.0.0.1")
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))

    erro = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }
    end

    assert_match(/127\.0\.0\.1/, erro.message)
  end

  test "documento que veio de IP público do conjunto (não o primeiro) passa — CDN/dual-stack" do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34", "1.1.1.1"])
    @page = FakePage.new(document_remote_ip: "1.1.1.1")
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))

    assert_equal :ok, Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }
  end

  test "documento que veio do IP validado passa" do
    @page = FakePage.new(document_remote_ip: "93.184.216.34")
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))

    assert_equal :ok, Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }
  end

  test "inject_cookies pula cookies fora da allowlist e nao chama set no Ferrum" do
    misturados = [
      { "name" => "reddit_session", "value" => "ok", "domain" => ".reddit.com", "path" => "/" },
      { "name" => "__Secure-YNID", "value" => "bad", "domain" => ".youtube.com", "path" => "/" }
    ]
    Fetcher::SessionCookies.stubs(:for).with("old.reddit.com").returns([misturados, :jar])

    @page.cookies.expects(:set).with(has_entry(name: "reddit_session")).once
    @page.cookies.expects(:set).with(has_entry(name: "__Secure-YNID")).never

    Fetcher::BrowserSession.with_page("https://old.reddit.com/r/test") { |_p| :ok }
  end

  test "inject_cookies passa secure: true para cookies __Secure-*" do
    sec_cookie = { "name" => "__Secure-3PSID", "value" => "sec_val", "domain" => ".youtube.com", "path" => "/" }
    Fetcher::SessionCookies.stubs(:for).with("www.youtube.com").returns([[sec_cookie], :jar])

    Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { |_p| :ok }

    posto = @page.cookies.postos.find { |c| c[:name] == "__Secure-3PSID" }
    assert_not_nil posto
    assert_equal true, posto[:secure]
  end
end
