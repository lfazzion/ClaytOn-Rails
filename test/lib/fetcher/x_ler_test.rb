# frozen_string_literal: true

require "test_helper"

class Fetcher::XLerTest < ActiveSupport::TestCase
  Resp = Fetcher::SafeHttpClient::Response

  class Cliente
    attr_reader :urls

    def initialize(resposta = nil, erro: nil)
      @resposta = resposta
      @erro = erro
      @urls = []
    end

    def get(url)
      @urls << url
      raise @erro if @erro

      @resposta
    end
  end

  def resp(body, status: 200, tipo: "text/html", final: "https://exemplo.com/final", headers: {})
    Resp.new(status: status, final_url: final, content_type: tipo, body: body, headers: headers)
  end

  HTML = "<html><head><title>  Meu  Paper </title></head><body><nav>menu</nav><h1>Ola</h1><p>Texto do paper.</p>" \
         "<script>segredo()</script></body></html>"

  test "caminho feliz: url final, titulo e texto sem script/nav" do
    cliente = Cliente.new(resp(HTML))
    r = Fetcher::XLer.ler(url: "https://exemplo.com/a", cliente: cliente)
    assert_equal "https://exemplo.com/final", r["url"]
    assert_equal "Meu Paper", r["titulo"]
    assert_includes r["texto"], "Texto do paper."
    refute_includes r["texto"], "segredo"
    refute_includes r["texto"], "menu"
    assert_equal false, r["truncado"]
    assert_equal ["https://exemplo.com/a"], cliente.urls
  end

  test "nao vaza cabecalho nem cookie no retorno" do
    r = Fetcher::XLer.ler(url: "https://exemplo.com/a",
                          cliente: Cliente.new(resp(HTML, headers: { "set-cookie" => "sid=ABC123" })))
    refute_includes JSON.generate(r), "ABC123"
    assert_equal %w[caracteres_total texto titulo truncado url], r.keys.sort
  end

  test "texto acima do teto e cortado e diz que cortou" do
    grande = "<html><title>T</title><body><p>#{'a' * (Fetcher::XLer::MAX_TEXTO + 500)}</p></body></html>"
    r = Fetcher::XLer.ler(url: "https://exemplo.com/a", cliente: Cliente.new(resp(grande)))
    assert_equal Fetcher::XLer::MAX_TEXTO, r["texto"].length
    assert r["truncado"]
    assert_operator r["caracteres_total"], :>, Fetcher::XLer::MAX_TEXTO
  end

  test "url invalida nao chama o cliente" do
    ["", "ftp://x.com/a", "javascript:alert(1)", "https://", "https://u:p@x.com/", "nao é url", "https://x.com/#{'a' * 2100}"].each do |ruim|
      cliente = Cliente.new(resp(HTML))
      assert_raises(Fetcher::XLer::UrlInvalida, ruim) { Fetcher::XLer.ler(url: ruim, cliente: cliente) }
      assert_empty cliente.urls
    end
  end

  test "dominio bloqueado pelo SsrfGuard vira Bloqueado legivel" do
    cliente = Cliente.new(erro: Fetcher::SsrfGuard::Blocked.new("IP 127.0.0.1 é interno"))
    e = assert_raises(Fetcher::XLer::Bloqueado) { Fetcher::XLer.ler(url: "http://localhost/", cliente: cliente) }
    assert_includes e.message, "não abre este endereço"
  end

  test "timeout, corpo grande, redirect e falha de rede viram erro legivel sem a mensagem crua" do
    {
      Fetcher::SafeHttpClient::RequestTimeout.new("10.0.0.1 lento") => [Fetcher::XLer::TempoEsgotado, "a tempo"],
      Fetcher::SafeHttpClient::BodyTooLarge.new("interno") => [Fetcher::XLer::CorpoGrande, "grande demais"],
      Fetcher::SafeHttpClient::TooManyRedirects.new("loop em http://10.0.0.1") => [Fetcher::XLer::HttpErro, "redireciona"],
      Fetcher::SafeHttpClient::Error.new("SocketError: 10.0.0.1") => [Fetcher::XLer::HttpErro, "não consegui baixar"]
    }.each do |erro, (classe, trecho)|
      e = assert_raises(classe) { Fetcher::XLer.ler(url: "https://exemplo.com/", cliente: Cliente.new(erro: erro)) }
      assert_includes e.message, trecho
      refute_includes e.message, "10.0.0.1"
    end
  end

  test "http 404, pdf e tipo binario sao recusados com motivo" do
    assert_raises(Fetcher::XLer::HttpErro) { Fetcher::XLer.ler(url: "https://a.com/", cliente: Cliente.new(resp(HTML, status: 404))) }
    assert_raises(Fetcher::XLer::TipoNaoSuportado) do
      Fetcher::XLer.ler(url: "https://a.com/", cliente: Cliente.new(resp("%PDF", tipo: "application/pdf")))
    end
    assert_raises(Fetcher::XLer::TipoNaoSuportado) do
      Fetcher::XLer.ler(url: "https://a.com/", cliente: Cliente.new(resp("x", tipo: "image/png")))
    end
  end

  test "pagina sem texto vira SemTexto" do
    assert_raises(Fetcher::XLer::SemTexto) do
      Fetcher::XLer.ler(url: "https://a.com/", cliente: Cliente.new(resp("<html><body><script>x</script></body></html>")))
    end
  end

  test "texto puro passa como esta" do
    r = Fetcher::XLer.ler(url: "https://a.com/r.txt", cliente: Cliente.new(resp("leia-me\nlinha", tipo: "text/plain")))
    assert_equal "leia-me\nlinha", r["texto"]
  end

  test "erro sai pelo envelope do x:ler como {erro,tipo}" do
    saida = StringIO.new
    status = Fetcher::XComando.executa(saida) { Fetcher::XLer.ler(url: "ftp://x", cliente: Cliente.new) }
    assert_equal 1, status
    assert_equal "UrlInvalida", JSON.parse(saida.string)["tipo"]
  end
end
