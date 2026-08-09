# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/fetcher/extract_service")
require Rails.root.join("lib/fetcher/channels/x")
require Rails.root.join("lib/fetcher/channels/reddit")

class Fetcher::ExtractServiceBudgetTest < ActiveSupport::TestCase
  ARTIGO = <<~HTML
    <html><head><title>Guia de deploy</title></head><body><article>
      <h1>Guia de deploy</h1>
      <p>#{'Paragrafo com conteudo real o bastante para nao ser considerado magro. ' * 10}</p>
    </article></body></html>
  HTML

  setup do
    Rails.cache.clear
    # Os testes que entram pelo ExtractService passam pelo SsrfGuard, que resolve
    # DNS de verdade. Nenhum deles mede resolução — fixar o IP tira a rede do laço.
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
  end

  test "o canal do X declara orcamento de espelho separado do de timeline" do
    assert_equal "mirror", Fetcher::Channels::X.extract_budget[:scope]
    assert_equal "timeline", Fetcher::Channels::X::TIMELINE_BUDGET[:scope]
  end

  test "gastar o balde do espelho nao impede a timeline" do
    5.times { Fetcher::HostRateLimiter.exceeded?("x.com", **Fetcher::Channels::X.extract_budget) }
    assert_not Fetcher::HostRateLimiter.exceeded?("x.com", **Fetcher::Channels::X::TIMELINE_BUDGET)
  end

  # CONTROLE: gastar o balde da TIMELINE impede a timeline. Sem isto, o teste
  # acima passaria com um limitador quebrado que nunca reprova.
  test "CONTROLE: gastar o balde da timeline impede a timeline" do
    4.times { Fetcher::HostRateLimiter.exceeded?("x.com", **Fetcher::Channels::X::TIMELINE_BUDGET) }
    assert Fetcher::HostRateLimiter.exceeded?("x.com", **Fetcher::Channels::X::TIMELINE_BUDGET)
  end

  test "a mensagem de rate limit reporta o teto aplicado, nao o da casa" do
    erro = Fetcher::ExtractService::RateLimited.new("x.com", 4)
    assert_match(/4 fetches\/min/, erro.message)
    refute_match(/5 fetches\/min/, erro.message)
  end

  # O par abaixo entra PELO serviço com o limitador estourado. O teste acima só
  # constrói a exceção na mão: ele mede que a CLASSE aceita o segundo argumento,
  # não que o SERVIÇO passa o teto aplicado. Provado por mutação em 06/08 —
  # reverter a linha 112 para `raise RateLimited, host` deixava a suíte inteira
  # verde, e o reader ouviria "atingiu 5 fetches/min" num host cujo teto é 2.
  test "o erro de rate limit que sai do servico cita o teto do canal, nao o da casa" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)

    result = Fetcher::ExtractService.call("https://old.reddit.com/r/ruby/comments/1")

    assert_match(%r{2 fetches/min}, result[:error])
    refute_match(%r{5 fetches/min}, result[:error])
  end

  # CONTROLE: host sem canal nenhum reporta o teto da casa. Sem este par, um
  # `budget_for` certo com o `raise` errado passaria — bastaria o serviço citar
  # sempre um número qualquer que casasse com um dos dois casos.
  test "CONTROLE: o erro de rate limit de host sem canal cita o teto da casa" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(true)

    result = Fetcher::ExtractService.call("https://docs.test/guia")

    assert_match(%r{5 fetches/min}, result[:error])
    refute_match(%r{2 fetches/min}, result[:error])
  end

  # Os três testes abaixo entram PELO `ExtractService`, casando no mocha o
  # argumento exato que `budget_for` monta. Sem eles a metade da mudança que mora
  # no serviço não era medida por nada: provado por mutação em 06/08, trocar o
  # corpo de `budget_for` por `{ max: HostRateLimiter::MAX_PER_WINDOW }` — canal
  # ignorado por completo — deixava a suíte inteira verde, 833 runs, 0 failures.
  test "o extract do x.com gasta o balde do espelho, com escopo e tudo" do
    Fetcher::Channels::X.stubs(:call).returns(
      url: "https://x.com/jack/status/20", title: "jack", content: "conteudo do espelho",
      metadata: { "source" => "x" }
    )
    Fetcher::HostRateLimiter.expects(:exceeded?)
                            .with("x.com", **Fetcher::Channels::X.extract_budget)
                            .returns(false)

    result = Fetcher::ExtractService.call("https://x.com/jack/status/20")

    assert_nil result[:error]
    assert_equal "conteudo do espelho", result[:content]
  end

  # CONTROLE: canal SEM `extract_budget` carrega o teto dele, não o do espelho e
  # não o da casa. É este par que impede a versão neutra de `budget_for` de
  # passar — os literais são de propósito, para o teste não repetir a conta que
  # está medindo (Reddit::MAX_PER_WINDOW é 2).
  test "CONTROLE: host de canal sem orcamento proprio gasta o teto do canal" do
    Fetcher::Channels::Reddit.stubs(:call).returns(
      url: "https://old.reddit.com/r/ruby/comments/1", title: "thread", content: "conteudo do reddit",
      metadata: { "source" => "reddit" }
    )
    Fetcher::HostRateLimiter.expects(:exceeded?).with("old.reddit.com", max: 2).returns(false)

    result = Fetcher::ExtractService.call("https://old.reddit.com/r/ruby/comments/1")

    assert_nil result[:error]
    assert_equal "conteudo do reddit", result[:content]
  end

  # CONTROLE: host sem canal nenhum gasta o teto da casa (HostRateLimiter
  # ::MAX_PER_WINDOW é 5), sem `scope`. Sem este, os dois acima poderiam passar
  # com um `budget_for` que só soubesse falar de canal.
  test "CONTROLE: host sem canal nenhum gasta o teto da casa" do
    stub_request(:get, "https://docs.test/guia")
      .to_return(status: 200, body: ARTIGO, headers: { "Content-Type" => "text/html; charset=utf-8" })
    Fetcher::PageFetcher.stubs(:hard_domains).returns([])
    Fetcher::HostRateLimiter.expects(:exceeded?).with("docs.test", max: 5).returns(false)

    result = Fetcher::ExtractService.call("https://docs.test/guia")

    assert_nil result[:error]
    assert_equal "static", result[:engine]
  end

  # Achado 6: na escalada, o PageFetcher cobrava o MESMO balde de novo (5/min),
  # em cima do que o ExtractService já tinha cobrado com o teto do canal — a 3a
  # requisição do minuto levantava "atingiu 5 fetches/min" com 2,5 reais de teto.
  # O caminho do browser tem de rodar com rate_limit: false.
  test "a escalada para o Chrome nao cobra rate limit em dobro" do
    Rails.cache.clear
    stub_request(:get, %r{http://escalada\.test/\d+})
      .to_return(status: 200, body: "<html><body><div id='root'></div></body></html>",
                 headers: { "Content-Type" => "text/html" })
    Fetcher::PageFetcher.stubs(:hard_domains).returns([])
    Fetcher::PageFetcher.any_instance.stubs(:call).returns(
      title: "T", url: "http://escalada.test/1", content: "texto renderizado",
      article_html: "<h1>t</h1>", cache_age_seconds: 0
    )
    Fetcher::Channels::Registry.stubs(:for_host).returns(nil)

    # Host único: o balde de "escalada.test" não é tocado por mais ninguém, e o
    # teto da casa (5/min) comporta as 5 chamadas. Sem o rate_limit:false no
    # caminho do browser, a 3a chamada já estouraria (5 fetches contados em dobro).
    5.times do |i|
      result = Fetcher::ExtractService.call("http://escalada.test/#{i}")
      assert_nil result[:error], "chamada #{i}: #{result[:error].inspect}"
    end
  end
end
