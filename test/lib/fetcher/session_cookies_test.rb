# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/session_cookies"

class Fetcher::SessionCookiesTest < ActiveSupport::TestCase
  VIVO = [{ "name" => "SID", "value" => "do-navegador", "domain" => ".youtube.com", "path" => "/" }].freeze
  GUARDADO = [{ "name" => "SID", "value" => "do-jar", "domain" => ".youtube.com", "path" => "/" }].freeze

  test "a sessao viva do Chrome tem precedencia sobre o jar" do
    Fetcher::BrowserCookies.stubs(:for).with("youtube.com").returns(VIVO)
    Fetcher::CookieJar.expects(:for).never

    assert_equal [VIVO, :browser], Fetcher::SessionCookies.for("youtube.com")
  end

  test "sem sessao no navegador, cai no jar e marca a origem" do
    Fetcher::BrowserCookies.stubs(:for).returns([])
    Fetcher::CookieJar.stubs(:for).with("youtube.com").returns(GUARDADO)

    assert_equal [GUARDADO, :jar], Fetcher::SessionCookies.for("youtube.com")
  end

  test "sem sessao em fonte nenhuma levanta Expired nomeando o dominio" do
    Fetcher::BrowserCookies.stubs(:for).returns([])
    Fetcher::CookieJar.stubs(:for).returns([])

    erro = assert_raises(Fetcher::CookieJar::Expired) { Fetcher::SessionCookies.for("old.reddit.com") }

    assert_equal "old.reddit.com", erro.domain
    assert_includes erro.message, "renovar"
  end

  # A regressão que isto guarda: o canal de Reddit só olhava o jar, então logar no
  # perfil persistente do Chrome não tinha efeito nenhum sobre ele.
  test "o mesmo caminho serve qualquer dominio, nao so o do YouTube" do
    do_reddit = [{ "name" => "reddit_session", "value" => "x", "domain" => ".reddit.com", "path" => "/" }]
    Fetcher::BrowserCookies.stubs(:for).with("old.reddit.com").returns(do_reddit)

    assert_equal [do_reddit, :browser], Fetcher::SessionCookies.for("old.reddit.com")
  end
end
