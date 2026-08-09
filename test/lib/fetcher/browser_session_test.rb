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

    def initialize
      @cookies = FakeCookies.new
      @fechada = false
    end

    def go_to(url) = @visitado = url
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
end
