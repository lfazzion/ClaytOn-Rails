# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/browser_cookies"

class Fetcher::BrowserCookiesTest < ActiveSupport::TestCase
  # Dublê no formato do Ferrum: `cookies.all` devolve hash nome => Cookie, e o
  # Cookie responde a name/value/domain/path (ferrum-0.17.2 cookies.rb:49).
  Cookie = Struct.new(:name, :value, :domain, :path)

  class FakeCookies
    def initialize(lista) = @lista = lista
    def all = @lista.to_h { |c| [c.name, c] }
  end

  class FakeBrowser
    attr_reader :cookies

    def initialize(lista) = @cookies = FakeCookies.new(lista)
  end

  def com_browser(lista)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(lista))
  end

  test "pega os cookies do dominio e ignora os de outros" do
    com_browser([
                  Cookie.new("SID", "abc", ".youtube.com", "/"),
                  Cookie.new("sessionid", "xyz", ".reddit.com", "/"),
                  Cookie.new("LOGIN_INFO", "def", "www.youtube.com", "/")
                ])

    lidos = Fetcher::BrowserCookies.for("youtube.com")

    assert_equal %w[SID LOGIN_INFO], lidos.map { |c| c["name"] }
    assert_equal "abc", lidos.first["value"]
    assert_equal ".youtube.com", lidos.first["domain"]
  end

  test "subdominio do alvo conta como o mesmo dominio" do
    com_browser([Cookie.new("SID", "abc", ".www.youtube.com", "/")])

    assert_equal 1, Fetcher::BrowserCookies.for("youtube.com").size
  end

  test "dominio que apenas termina parecido nao casa" do
    com_browser([Cookie.new("X", "1", ".naoyoutube.com", "/")])

    assert_empty Fetcher::BrowserCookies.for("youtube.com")
  end

  test "path vazio vira barra" do
    com_browser([Cookie.new("SID", "abc", ".youtube.com", "")])

    assert_equal "/", Fetcher::BrowserCookies.for("youtube.com").first["path"]
  end

  test "browser indisponivel devolve lista vazia, nunca excecao" do
    Fetcher::PageFetcher.stubs(:browser).raises(StandardError, "sem chrome")

    assert_empty Fetcher::BrowserCookies.for("youtube.com"),
                 "o canal ainda pode cair no jar; derrubar a chamada tiraria essa chance"
  end

  class Espiao
    attr_reader :postos

    def initialize = @postos = []
    def all = @postos.to_h { |k| [k[:name], Cookie.new(k[:name], k[:value], k[:domain], k[:path])] }
    def set(**kwargs) = @postos << kwargs
  end

  class BrowserEspiao
    attr_reader :cookies

    def initialize = @cookies = Espiao.new
  end

  def com_espiao
    espiao = BrowserEspiao.new
    Fetcher::PageFetcher.stubs(:browser).returns(espiao)
    espiao
  end

  # Sem `expires` o cookie vira de SESSAO e o Chrome o descarta ao reiniciar.
  test "load! traduz expirationDate para expires" do
    espiao = com_espiao
    Fetcher::BrowserCookies.load!([{ "name" => "SID", "value" => "v", "domain" => ".youtube.com",
                                     "path" => "/", "expirationDate" => 2_000_000_000.5 }])

    assert_equal 2_000_000_000, espiao.cookies.postos.first[:expires]
  end

  test "load! traduz os nomes de sameSite do Cookie-Editor para os do CDP" do
    espiao = com_espiao
    Fetcher::BrowserCookies.load!([
                                   { "name" => "a", "value" => "1", "domain" => ".x.test", "sameSite" => "no_restriction" },
                                   { "name" => "b", "value" => "1", "domain" => ".x.test", "sameSite" => "lax" },
                                   { "name" => "c", "value" => "1", "domain" => ".x.test", "sameSite" => nil }
                                 ])
    postos = espiao.cookies.postos

    assert_equal "None", postos[0][:samesite]
    assert_equal "Lax", postos[1][:samesite]
    assert_not postos[2].key?(:samesite), "sameSite ausente nao pode virar valor inventado"
  end

  test "load! confirma lendo de volta e ignora entrada sem nome" do
    com_espiao
    resultado = Fetcher::BrowserCookies.load!([
                                                { "name" => "SID", "value" => "v", "domain" => ".youtube.com" },
                                                { "name" => "", "value" => "x", "domain" => ".youtube.com" }
                                              ])

    assert_equal({ postos: 1, confirmados: 1 }, resultado)
  end
end
