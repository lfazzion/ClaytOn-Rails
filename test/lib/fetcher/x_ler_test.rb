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

  # Cliente REAL (`SafeHttpClient`) para o caminho que o cliente falso não alcança:
  # site público que responde 302 para 127.0.0.1. É aqui que nasce a distinção entre
  # "bloqueou antes de pedir qualquer coisa" e "pediu, e o redirecionamento foi recusado" —
  # o primeiro hop é buscado de verdade, e o segundo morre na SsrfGuard.
  class ClienteReal
    PUBLIC_IP = "93.184.216.34"

    attr_reader :pedidas

    def initialize
      @pedidas = []
    end

    def get(url)
      @pedidas << url
      Fetcher::SafeHttpClient.get(url)
    end
  end

  def setup
    super
    Fetcher::SsrfGuard.stubs(:resolve_all).returns([ClienteReal::PUBLIC_IP])
    stub_request(:get, "http://a2.test/")
      .to_return(status: 302, headers: { "Location" => "http://127.0.0.1/x" })
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

  # ---- a distinção de que a COTA depende: houve requisição de rede antes do bloqueio?
  #
  # `Bloqueado` chega ao porteiro como `{erro, tipo}` e o porteiro devolve a vaga da cota
  # quando a culpa é do PEDIDO (nada saiu). Num site público que responde 302 para
  # 127.0.0.1 a requisição ao site JÁ SAIU: devolver a vaga ali deixava o laço de
  # "abrir até o teto" sem teto (21 chamadas ao Rails, zero contadas). O nome do caso
  # tem de travelar até o porteiro, e é `bloqueado_apos_rede`.
  test "bloqueio que aconteceu antes de pedir rede é marcado (bloqueado_apos_rede = false)" do
    cliente = Cliente.new(erro: Fetcher::SsrfGuard::Blocked.new("host privado/interno (127.0.0.1)"))
    e = assert_raises(Fetcher::XLer::Bloqueado) { Fetcher::XLer.ler(url: "http://localhost/", cliente: cliente) }
    assert_equal false, e.bloqueado_apos_rede
  end

  test "bloqueio em hop posterior (302 para IP interno) é marcado como bloqueio DEPOIS da rede" do
    cliente = ClienteReal.new
    e = assert_raises(Fetcher::XLer::Bloqueado) { Fetcher::XLer.ler(url: "http://a2.test/", cliente: cliente) }
    assert_equal true, e.bloqueado_apos_rede
    assert_equal ["http://a2.test/"], cliente.pedidas
  end

  test "a mensagem de Bloqueado NAO entrega o endereco interno, mas diz que é interno" do
    cliente = Cliente.new(erro: Fetcher::SsrfGuard::Blocked.new("host resolve para IP privado/interno (10.1.2.3)"))
    e = assert_raises(Fetcher::XLer::Bloqueado) { Fetcher::XLer.ler(url: "http://interno.test/", cliente: cliente) }
    refute_includes e.message, "10.1.2.3"
    assert_includes e.message, "interno"
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
