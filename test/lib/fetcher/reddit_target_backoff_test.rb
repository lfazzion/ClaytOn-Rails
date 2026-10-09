# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/browser_session"
require_relative "../../../lib/fetcher/channels/reddit"
require_relative "../../../lib/fetcher/extract_service"

# Regra 4 do AGENTS.md (nunca repetir scraping em 403/429/captcha, backoff
# 6-12h) no caminho que de fato NAVEGA o alvo.
#
# Teste no NÍVEL DO CHAMADOR, e não na camada de mapeamento: a lição do #205 é
# que teste que só exercita o mapeamento deixa a regressão passar. Aqui quem
# chama é o canal (`Reddit.call`, `Reddit.search`) e o serviço de topo
# (`ExtractService`, que é o `/internal/extract` do MCP) — a mesma cadeia que
# produziu as 65 navegações medidas no card t_f63b3613.
#
# O dublê reproduz o que o Chrome de PRODUÇÃO fez, medido naquele card:
#   - o documento principal responde 403 (ou 429) no primeiro instante;
#   - o `go_to` estoura no `goto_limit` (15s no Reddit) — M7: body_check = "";
#   - por isso o `EXTRACT_JS` nunca roda e o 403 nunca chega ao canal.
class Fetcher::RedditTargetBackoffTest < ActiveSupport::TestCase
  THREAD = "https://www.reddit.com/r/ruby/comments/abc123/titulo/"

  PAYLOAD = {
    "title" => "Titulo real", "subreddit" => "ruby", "author" => "alguem",
    "score" => 412, "selftext" => "Corpo do post.",
    "comments" => [{ "author" => "a", "score" => 90, "depth" => 0, "body" => "Comentario raiz." }]
  }.freeze

  # Hash que o EXTRACT_JS devolve na página de bloqueio: title vazio e
  # comments vazio — indistinguível de thread sem conteúdo.
  PAYLOAD_BLOQUEADO = {
    "title" => "", "subreddit" => "", "author" => "",
    "score" => nil, "selftext" => "", "comments" => []
  }.freeze

  class FakeCookies
    def set(_options) = true
    def all = {}
  end

  class FakePage
    attr_reader :go_to_calls, :navegado, :fechada, :comandos, :listeners
    attr_accessor :timeout

    def initialize(status:, goto_error: nil, payload: nil)
      @status = status
      @goto_error = goto_error
      @payload = payload
      @go_to_calls = 0
      @navegado = []
      @fechada = false
      @comandos = []
      @listeners = Hash.new { |hash, key| hash[key] = [] }
      @timeout = 12
    end

    def cookies = @cookies ||= FakeCookies.new

    # Emite o documento principal (é o que o CDP entrega) e só DEPOIS estoura o
    # goto — a ordem importa: o 403 estava no ar antes do estouro.
    def go_to(url)
      @go_to_calls += 1
      @navegado << url
      @listeners["Network.responseReceived"].each do |blk|
        blk.call("type" => "Document",
                 "response" => { "url" => url, "status" => @status,
                                 "remoteIPAddress" => "93.184.216.34" })
      end
      raise @goto_error if @goto_error

      nil
    end

    def evaluate(js)
      return @payload if js.to_s.include?("querySelector")

      ""
    end

    def command(name, params = {})
      @comandos << [name, params]
      true
    end

    def on(event, &block)
      @listeners[event] << block
      @listeners[event].size - 1
    end

    def off(event, id)
      @listeners[event].delete_at(id)
      true
    end

    def current_url = @navegado.last
    def close = (@fechada = true)
    # `page.network.response` é o ÚLTIMO exchange da sessão CDP: foi exatamente
    # por isso que ele saía vazio no log real (M11: 53 de 65). O dublê devolve
    # nil para provar que a classificação NÃO pode depender dele.
    def network = Struct.new(:response).new(nil)
  end

  class FakeContext
    attr_reader :descartado

    def initialize(page)
      @page = page
      @descartado = false
    end

    def create_page = @page
    def dispose = (@descartado = true)
  end

  class FakeContexts
    def initialize(context) = @context = context
    def create(**_options) = @context
  end

  class FakeBrowser
    attr_reader :contexts

    def initialize(context) = @contexts = FakeContexts.new(context)
  end

  setup do
    # O cooldown é ESTADO DE PRODUÇÃO (cache compartilhado): sem esta limpeza, o
    # `old.reddit.com` bloqueado por um teste vaza para o teste seguinte — e o
    # arquivo vizinho morre com `TargetInCooldown` em testes que nada tem a ver
    # com bloqueio. Mesma classe de vazamento que o `test_helper` resolve para
    # o estado de busca (MEMORY 02/09/2026); aqui o isolamento é por chave.
    Rails.cache.clear
    Fetcher::SsrfGuard.stubs(:resolve_all).returns(["93.184.216.34"])
    Fetcher::SessionCookies.stubs(:for).returns([[], :jar])
    # O balde de 2/min tem suíte própria (host_rate_limiter_test). Aqui o que
    # está em jogo é o COOLDOWN: isolar o outro portão é o que faz a asserção
    # valer alguma coisa.
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    @page = FakePage.new(status: 403,
                         goto_error: Ferrum::TimeoutError.new("goto_limit de 15s estourou"),
                         payload: JSON.generate(PAYLOAD))
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))
  end

  teardown do
    # O cooldown que a regra 4 gravou é ESTADO DE PRODUÇÃO, não lixo de teste: o
    # teardown garante que ele não vaza para o próximo arquivo da suíte.
    Rails.cache.clear
  end

  def com_pagina(status:, goto_error: nil, payload: PAYLOAD)
    @page = FakePage.new(status: status, goto_error: goto_error, payload: JSON.generate(payload))
    @context = FakeContext.new(@page)
    Fetcher::PageFetcher.stubs(:browser).returns(FakeBrowser.new(@context))
    @page
  end

  test "403 no documento vira bloqueio nomeado e grava o cooldown do ALVO (regra 4)" do
    erro = assert_raises(Fetcher::BrowserSession::TargetBlocked) do
      Fetcher::Channels::Reddit.call(url: THREAD)
    end

    assert_includes erro.message, "old.reddit.com"
    assert_includes erro.message, "403"
    assert_kind_of Fetcher::Channels::Error, erro,
                   "precisa ser erro de CANAL: é o que o ExtractService e o PlatformSearchTool convertem em campo"

    entrada = Fetcher::BotDetection.cooldown_for("old.reddit.com")
    assert_not_nil entrada, "sem cooldown gravado a regra 4 continua inerte — é o defeito medido"
    assert_equal "HTTP 403", entrada[:reason]
    assert_operator entrada[:expires_at] - Time.current, :>, 5.hours
    # O ALVO é o host que o Chrome realmente abre. O canônico é outra chave, e
    # o cooldown do host navegado não pode vazar para ele nem para o contrário.
    assert_nil Fetcher::BotDetection.cooldown_for("www.reddit.com")
  end

  test "a segunda tentativa no mesmo alvo, por outro chamador, NÃO navega (prova do backoff)" do
    assert_raises(Fetcher::BrowserSession::TargetBlocked) do
      Fetcher::Channels::Reddit.call(url: THREAD)
    end
    navegacoes_da_primeira = @page.go_to_calls

    erro = assert_raises(Fetcher::BrowserSession::TargetInCooldown) do
      Fetcher::Channels::Reddit.search(query: "ruby on rails")
    end

    assert_equal navegacoes_da_primeira, @page.go_to_calls,
                 "o backoff tem de barrar ANTES do go_to — é esta a prova que a 2a tentativa respeita o cooldown"
    assert_equal 1, @page.go_to_calls
    assert_includes erro.message, "old.reddit.com"
    assert_includes erro.message, "cooldown",
                    "o desfecho da segunda tentativa é o cooldown, e a mensagem diz isso"
    refute_includes erro.message, "tempo de render",
                    "a mensagem de timeout convida o modelo a repetir — é o que a regra 4 proíbe"
  end

  test "o cooldown recusa antes de gastar browser e antes de ler a sessão" do
    Fetcher::BotDetection.cooldown!("old.reddit.com", reason: "HTTP 403")
    Fetcher::SessionCookies.expects(:for).never
    Fetcher::PageFetcher.expects(:browser).never

    erro = assert_raises(Fetcher::BrowserSession::TargetInCooldown) do
      Fetcher::Channels::Reddit.call(url: THREAD)
    end

    assert_includes erro.message, "old.reddit.com"
    assert_equal 0, @page.go_to_calls, "nenhuma navegação pode ter saído com o alvo em cooldown"
  end

  test "cooldown de um host não barra outro host (o cooldown é por ALVO)" do
    Fetcher::BotDetection.cooldown!("old.reddit.com", reason: "HTTP 403")
    pagina_do_reddit = @page

    pagina = com_pagina(status: 200)
    resultado = Fetcher::BrowserSession.with_page("https://www.youtube.com/watch?v=x") { :ok }

    assert_equal :ok, resultado, "o cooldown do old.reddit.com não pode barrar o YouTube"
    assert_equal 1, pagina.go_to_calls, "o outro host navega normalmente"
    assert_equal 0, pagina_do_reddit.go_to_calls, "e o host em cooldown não foi navegado"
  end

  # O 403 também pode vir SEM estouro de goto (a folha de estilo do tracker às
  # vezes volta). O destino tem de ser o mesmo: classificar no post-navegação
  # é o que fecha o segundo caminho de entrada do bloqueio.
  test "403 que o goto nao estoura tambem vira bloqueio e nunca chega ao yield" do
    com_pagina(status: 403, payload: PAYLOAD_BLOQUEADO)

    assert_raises(Fetcher::BrowserSession::TargetBlocked) do
      Fetcher::Channels::Reddit.call(url: THREAD)
    end

    assert Fetcher::BotDetection.cooldown?("old.reddit.com")
    assert @page.fechada
    assert @context.descartado
  end

  test "429 tambem e bloqueio (a regra nomeia os dois)" do
    com_pagina(status: 429, goto_error: Ferrum::TimeoutError.new("goto estourou"))

    erro = assert_raises(Fetcher::BrowserSession::TargetBlocked) do
      Fetcher::Channels::Reddit.search(query: "ruby")
    end

    assert_includes erro.message, "429"
    assert_equal "HTTP 429", Fetcher::BotDetection.cooldown_for("old.reddit.com")[:reason]
  end

  # O goto de produção levanta PendingConnections (o tracker do <title>Blocked>
  # nunca volta do IP bloqueado) — o mesmo rescue trata as duas classes, e o
  # teste fixa isso.
  test "PendingConnectionsError no goto tambem vira bloqueio, nao RenderTimeout" do
    com_pagina(status: 403, goto_error: Ferrum::PendingConnectionsError.new("pending"))

    erro = assert_raises(Fetcher::BrowserSession::TargetBlocked) do
      Fetcher::Channels::Reddit.call(url: THREAD)
    end

    assert_includes erro.message, "403"
    assert Fetcher::BotDetection.cooldown?("old.reddit.com")
  end

  # CONTROLE: o caminho saudável não pode virar bloqueio. Um 200 tem de chegar
  # ao yield, devolver a thread e NÃO armar cooldown.
  test "resposta 200 nao arma cooldown e a thread e lida" do
    com_pagina(status: 200)

    resultado = Fetcher::Channels::Reddit.call(url: THREAD)

    assert_equal "Titulo real", resultado[:title]
    assert_includes resultado[:content], "Comentario raiz."
    assert_nil Fetcher::BotDetection.cooldown_for("old.reddit.com")
  end

  # CONTROLE 2: status ausente (CDP sem o campo) não pode ser lido como
  # bloqueio — fail-open, como o resto da casa. Nem 200, nem 403 inventado.
  test "sem status do documento o caminho segue igual (fail-open, sem cooldown)" do
    com_pagina(status: nil)

    resultado = Fetcher::Channels::Reddit.call(url: THREAD)

    assert_equal "Titulo real", resultado[:title]
    assert_nil Fetcher::BotDetection.cooldown_for("old.reddit.com")
  end

  # Nível de topo: o que o MCP /internal/extract devolve. A mensagem antiga era
  # "tempo de render excedeu 35s", que é convite para repetir.
  test "o ExtractService devolve o bloqueio nomeado, sem esperar os 35s" do
    com_pagina(status: 403, goto_error: Ferrum::TimeoutError.new("goto_limit de 15s estourou"))

    inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resultado = Fetcher::ExtractService.call(THREAD)
    decorrido = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inicio

    assert_nil resultado[:content]
    assert_not_nil resultado[:error]
    assert_includes resultado[:error], "403"
    refute_includes resultado[:error], "tempo de render",
                    "a mensagem de timeout convida o modelo a repetir — é o que a regra 4 proíbe"
    assert_operator decorrido, :<, 2.0,
                    "a classificação tem que ser no go_to, não depois de estourar o teto de 35s"
  end
end
