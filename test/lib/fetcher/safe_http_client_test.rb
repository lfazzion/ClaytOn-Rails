# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/safe_http_client"

class Fetcher::SafeHttpClientTest < ActiveSupport::TestCase
  PUBLIC_IP = "93.184.216.34"

  setup do
    Fetcher::SsrfGuard.stubs(:resolve_all).returns([PUBLIC_IP])
  end

  def resolve(host, ips)
    Fetcher::SsrfGuard.stubs(:resolve_all).with(host).returns(ips)
  end

  test "GET simples devolve corpo, status e content-type" do
    stub_request(:get, "http://ok.test/pagina")
      .to_return(status: 200, body: "<html>oi</html>", headers: { "Content-Type" => "text/html; charset=utf-8" })

    response = Fetcher::SafeHttpClient.get("http://ok.test/pagina")

    assert_equal 200, response.status
    assert_equal "text/html", response.content_type
    assert_equal "http://ok.test/pagina", response.final_url
    assert_includes response.body, "oi"
    assert_predicate response, :html?
  end

  test "conecta no IP validado, não re-resolve na hora do connect" do
    resolve("pinado.test", ["93.184.216.34"])
    stub_request(:get, "http://pinado.test/").to_return(status: 200, body: "ok")

    Net::HTTP.any_instance.expects(:ipaddr=).with("93.184.216.34").at_least_once

    Fetcher::SafeHttpClient.get("http://pinado.test/")
  end

  # ── Redirects ───────────────────────────────────────────────────────────────
  test "redirect para host público é seguido e final_url reflete o destino" do
    resolve("a.test", [PUBLIC_IP])
    resolve("b.test", [PUBLIC_IP])
    stub_request(:get, "http://a.test/").to_return(status: 301, headers: { "Location" => "http://b.test/final" })
    stub_request(:get, "http://b.test/final").to_return(status: 200, body: "destino")

    response = Fetcher::SafeHttpClient.get("http://a.test/")

    assert_equal "http://b.test/final", response.final_url
    assert_equal "destino", response.body
  end

  test "redirect para loopback é bloqueado e a requisição interna não acontece" do
    resolve("a.test", [PUBLIC_IP])
    stub_request(:get, "http://a.test/").to_return(status: 302, headers: { "Location" => "http://127.0.0.1/x" })

    error = assert_raises(Fetcher::SsrfGuard::Blocked) { Fetcher::SafeHttpClient.get("http://a.test/") }

    assert_match(/privado|interno/i, error.reason)
    assert_not_requested :get, "http://127.0.0.1/x"
  end

  test "redirect para metadata da nuvem é bloqueado" do
    resolve("a.test", [PUBLIC_IP])
    stub_request(:get, "http://a.test/")
      .to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/meta-data/" })

    assert_raises(Fetcher::SsrfGuard::Blocked) { Fetcher::SafeHttpClient.get("http://a.test/") }
  end

  test "redirect relativo para host interno via hostname é bloqueado" do
    resolve("a.test", [PUBLIC_IP])
    resolve("interno.test", ["10.1.2.3"])
    stub_request(:get, "http://a.test/").to_return(status: 302, headers: { "Location" => "http://interno.test/" })

    assert_raises(Fetcher::SsrfGuard::Blocked) { Fetcher::SafeHttpClient.get("http://a.test/") }
  end

  test "redirect para scheme não-http é bloqueado" do
    resolve("a.test", [PUBLIC_IP])
    stub_request(:get, "http://a.test/").to_return(status: 302, headers: { "Location" => "gopher://a.test/1" })

    error = assert_raises(Fetcher::SsrfGuard::Blocked) { Fetcher::SafeHttpClient.get("http://a.test/") }
    assert_match(/scheme/i, error.reason)
  end

  test "cadeia de redirects longa demais é interrompida" do
    resolve("loop.test", [PUBLIC_IP])
    (0..10).each do |i|
      stub_request(:get, "http://loop.test/#{i}")
        .to_return(status: 302, headers: { "Location" => "http://loop.test/#{i + 1}" })
    end

    assert_raises(Fetcher::SafeHttpClient::TooManyRedirects) { Fetcher::SafeHttpClient.get("http://loop.test/0") }
  end

  test "loop de redirect é detectado" do
    resolve("loop.test", [PUBLIC_IP])
    stub_request(:get, "http://loop.test/a").to_return(status: 302, headers: { "Location" => "http://loop.test/b" })
    stub_request(:get, "http://loop.test/b").to_return(status: 302, headers: { "Location" => "http://loop.test/a" })

    assert_raises(Fetcher::SafeHttpClient::TooManyRedirects) { Fetcher::SafeHttpClient.get("http://loop.test/a") }
  end

  # ── Tetos ───────────────────────────────────────────────────────────────────
  test "Content-Length acima do teto é recusado antes de baixar" do
    stub_request(:get, "http://grande.test/")
      .to_return(status: 200, body: "x",
                 headers: { "Content-Length" => (Fetcher::SafeHttpClient::MAX_COMPRESSED_BYTES + 1).to_s })

    assert_raises(Fetcher::SafeHttpClient::BodyTooLarge) { Fetcher::SafeHttpClient.get("http://grande.test/") }
  end

  test "corpo acima do teto de bytes baixados é recusado" do
    stub_request(:get, "http://grande.test/")
      .to_return(status: 200, body: "x" * (Fetcher::SafeHttpClient::MAX_COMPRESSED_BYTES + 10))

    assert_raises(Fetcher::SafeHttpClient::BodyTooLarge) { Fetcher::SafeHttpClient.get("http://grande.test/") }
  end

  test "zip bomb: gzip pequeno que infla além do teto é recusado" do
    payload = "A" * (Fetcher::SafeHttpClient::MAX_DECOMPRESSED_BYTES + 1_000)
    gzipped = begin
      io = StringIO.new(+"", "wb")
      gz = Zlib::GzipWriter.new(io)
      gz.write(payload)
      gz.close
      io.string
    end
    assert_operator gzipped.bytesize, :<, Fetcher::SafeHttpClient::MAX_COMPRESSED_BYTES

    stub_request(:get, "http://bomba.test/")
      .to_return(status: 200, body: gzipped, headers: { "Content-Encoding" => "gzip" })

    error = assert_raises(Fetcher::SafeHttpClient::BodyTooLarge) { Fetcher::SafeHttpClient.get("http://bomba.test/") }
    assert_match(/descomprimidos/, error.message)
  end

  test "gzip dentro do teto é descomprimido normalmente" do
    io = StringIO.new(+"", "wb")
    gz = Zlib::GzipWriter.new(io)
    gz.write("<html>conteudo comprimido</html>")
    gz.close

    stub_request(:get, "http://gz.test/")
      .to_return(status: 200, body: io.string, headers: { "Content-Encoding" => "gzip" })

    response = Fetcher::SafeHttpClient.get("http://gz.test/")
    assert_includes response.body, "conteudo comprimido"
  end

  # ── Higiene da requisição ───────────────────────────────────────────────────
  test "não manda cookie nem header vindo de fora" do
    stub_request(:get, "http://limpo.test/").to_return(status: 200, body: "ok")

    Fetcher::SafeHttpClient.get("http://limpo.test/")

    assert_requested(:get, "http://limpo.test/") do |req|
      req.headers.keys.map(&:downcase).none? { |k| %w[cookie authorization].include?(k) }
    end
  end

  test "PDF é sinalizado no content-type e não confundido com html" do
    stub_request(:get, "http://doc.test/a.pdf")
      .to_return(status: 200, body: "%PDF-1.4", headers: { "Content-Type" => "application/pdf" })

    response = Fetcher::SafeHttpClient.get("http://doc.test/a.pdf")

    assert_predicate response, :pdf?
    assert_not response.html?
  end

  # ── Headers extras (Authorization) em redirect ─────────────────────────────
  # O header é segredo da ORIGEM original: mesma origem (scheme+host+porta)
  # preserva (repo do GitHub transferido precisa continuar autenticado);
  # qualquer mudança de origem limpa (nunca vazar o token para outro domínio).

  test "headers extras são enviados no primeiro hop e em redirect same-origin" do
    stub_request(:get, "http://api.test/start").to_return(status: 301, headers: { "Location" => "http://api.test/same" })
    stub_request(:get, "http://api.test/same").to_return(status: 200, body: "ok")

    Fetcher::SafeHttpClient.get("http://api.test/start", headers: { "Authorization" => "Bearer token-x" })

    assert_requested(:get, "http://api.test/start") { |req| req.headers["Authorization"] == "Bearer token-x" }
    assert_requested(:get, "http://api.test/same")  { |req| req.headers["Authorization"] == "Bearer token-x" }
  end

  test "headers extras são removidos em redirect cross-origin" do
    stub_request(:get, "http://api.test/start").to_return(status: 301, headers: { "Location" => "http://outro.test/final" })
    stub_request(:get, "http://outro.test/final").to_return(status: 200, body: "ok")

    Fetcher::SafeHttpClient.get("http://api.test/start", headers: { "Authorization" => "Bearer token-x" })

    assert_requested(:get, "http://api.test/start") { |req| req.headers["Authorization"] == "Bearer token-x" }
    assert_requested(:get, "http://outro.test/final") { |req| req.headers["Authorization"].nil? }
  end

  test "headers extras são removidos em downgrade https para http (mudança de origem)" do
    stub_request(:get, "https://api.test/start").to_return(status: 302, headers: { "Location" => "http://api.test/plain" })
    stub_request(:get, "http://api.test/plain").to_return(status: 200, body: "ok")

    Fetcher::SafeHttpClient.get("https://api.test/start", headers: { "Authorization" => "Bearer token-x" })

    assert_requested(:get, "https://api.test/start") { |req| req.headers["Authorization"] == "Bearer token-x" }
    assert_requested(:get, "http://api.test/plain")  { |req| req.headers["Authorization"].nil? }
  end

  test "porta explícita igual à default é a mesma origem (mantém headers)" do
    stub_request(:get, "http://api.test:80/start").to_return(status: 301, headers: { "Location" => "http://api.test/same" })
    stub_request(:get, "http://api.test/same").to_return(status: 200, body: "ok")

    Fetcher::SafeHttpClient.get("http://api.test:80/start", headers: { "Authorization" => "Bearer token-x" })

    assert_requested(:get, "http://api.test/same") { |req| req.headers["Authorization"] == "Bearer token-x" }
  end
end
