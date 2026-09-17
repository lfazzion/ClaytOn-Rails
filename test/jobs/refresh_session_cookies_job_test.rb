# frozen_string_literal: true

require "test_helper"
require_relative "../../app/jobs/scraping_failure_alert_job"
require_relative "../../app/services/alert_throttler"

class RefreshSessionCookiesJobTest < ActiveSupport::TestCase
  COOKIES = [
    { "name" => "SID", "value" => "abc", "domain" => ".youtube.com", "path" => "/" },
    { "name" => "__Secure-1PSIDTS", "value" => "sidts-ANTIGO", "domain" => ".youtube.com", "path" => "/" }
  ].freeze

  setup do
    ENV["ALERT_THROTTLE_ENABLED"] = "true"
    ENV["DISCORD_ADMIN_CHANNEL_ID"] = "123456789"
    Rails.cache.delete("discord:admin_channel_id")
    Rails.cache.delete("discord:admin_channel_lock")
    # O job enfileira o alerta via `perform_later`; capturar em @alertas prova
    # que ele ENQUEUEOU sem executar o corpo (o teste de dedupe executa o corpo
    # de verdade e conta as chamadas no DiscordApiClient).
    @alertas = []
    ScrapingFailureAlertJob.stubs(:perform_later)
                              .with { |scraper, perfil, msg, tipo| @alertas << [scraper, perfil, msg, tipo]; true }
  end

  teardown do
    ENV.delete("ALERT_THROTTLE_ENABLED")
    ENV.delete("DISCORD_ADMIN_CHANNEL_ID")
    Rails.cache.delete("discord:admin_channel_id")
    Rails.cache.delete("discord:admin_channel_lock")
    bucket = Time.current.to_i / 1.hour.to_i
    Rails.cache.delete("alert_throttle:session_rejected:#{bucket}")
    AlertThrottler.resolve_incident("youtube", "jar")
  end

  def carregar!
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 3.days.from_now)
  end

  # O servidor devolve SÓ os anônimos — o mesmo sinal objetivo de sessão morta
  # que os testes originais codificavam: `verify_session!` levanta `Expired`, o
  # job converte em `SessaoRejeitada`.
  def rejeitar_no_stub!
    ok = Struct.new(:success?).new(true)
    Open3.stubs(:capture3).with do |*args|
      caminho = args[args.index("--cookies") + 1]
      File.write(caminho, "# Netscape HTTP Cookie File\n" \
                          "#{['.youtube.com', 'TRUE', '/', 'TRUE', 2_000_000_000, 'PREF', 'x'].join("\t")}\n")
      true
    end.returns(["", "", ok])
  end

  # Roda o job com uma rotação bem-sucedida (o servidor devolve a sessão viva).
  def rotacionar_no_stub!
    ok = Struct.new(:success?).new(true)
    Open3.stubs(:capture3).with do |*args|
      caminho = args[args.index("--cookies") + 1]
      File.write(caminho, [
        "# Netscape HTTP Cookie File",
        [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "abc"].join("\t"),
        [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "__Secure-1PSIDTS", "sidts-NOVO"].join("\t")
      ].join("\n"))
      true
    end.returns(["x", "", ok])
  end

  test "sem sessao no jar nao gasta processo" do
    Open3.expects(:capture3).never

    assert_nothing_raised { RefreshSessionCookiesJob.perform_now }
  end

  # O ponto do job: o yt-dlp reescreve o arquivo com o que o servidor devolveu, e
  # e isso que precisa chegar ao jar. Sem persistir, a renovacao nao serve pra nada.
  test "persiste no jar o token que o servidor rotacionou" do
    carregar!
    rotacionar_no_stub!

    RefreshSessionCookiesJob.perform_now

    token = Fetcher::CookieJar.for("youtube.com").find { |c| c["name"] == "__Secure-1PSIDTS" }
    assert_equal "sidts-NOVO", token["value"]
  end

  # COOKIE-1 (defeito 1): rejeição do servidor NÃO pode deixar o jar "vivo" —
  # era exatamente o estado em que o sistema ficou 5,7 dias sem perceber:
  # `valid?` devolvia true, `for` servia o payload, e os jobs de coleta
  # gastavam chamada num cookie morto.
  test "sessao rejeitada durante a renovacao invalida o jar (valid? vira false)" do
    carregar!
    rejeitar_no_stub!

    RefreshSessionCookiesJob.perform_now

    refute Fetcher::CookieJar.valid?("youtube.com"),
           "após rejeição do servidor o jar não pode continuar reportado como vivo"
    assert_raises(Fetcher::CookieJar::Expired) { Fetcher::CookieJar.require!("youtube.com") }
    assert_empty Fetcher::CookieJar.for("youtube.com"),
                 "o portão de leitura (expires_at) tem que estourar — não servir o payload morto"
  end

  # O payload é preservado para diagnóstico: a exportação antiga continua no
  # banco cifrada, para o dono enxergar O QUE o servidor rejeitou — mas o
  # caminho público `for` devolve `[]` porque a sessão morreu do lado dele.
  # O teste original ("sessao rejeitada nao apaga o jar") codificava o defeito:
  # ele assergia `CookieJar.for` devolvendo o payload, que era o exato sinal de
  # que o jar continuava sendo servido a quem não sabe que ele está morto.
  # O novo comportamento é o correto: o que o teste protegia de VERDADEDERA
  # (não sobrescrever a exportação com o conjunto anônimo) continua protegido —
  # aqui por assertiva no BANCO, não no caminho de leitura.
  test "sessao rejeitada nao sobrescreve o payload e preserva o registro para diagnostico" do
    carregar!
    rejeitar_no_stub!

    RefreshSessionCookiesJob.perform_now

    registro = BrowserSessionCookie.find_by(domain: "youtube.com")
    assert_not_nil registro, "o registro não pode sumir — o payload serve para diagnóstico"
    payload = JSON.parse(registro.payload)
    assert_equal "abc", payload.find { |c| c["name"] == "SID" }&.dig("value"),
                 "o conjunto anônimo do servidor NÃO pode ter sobrescrito a exportação (bug de 05/08)"
    assert_equal "sidts-ANTIGO", payload.find { |c| c["name"] == "__Secure-1PSIDTS" }&.dig("value")
  end

  # COOKIE-1 (defeito 2): rejeição precisa de ALERTA, não de linha de log.
  # Canal de alerta é o MESMO do repo (`ScrapingFailureAlertJob` →
  # `DiscordApiClient`); primeira rejeição enfileira exatamente um alerta.
  test "rejeicao enfileira alerta de sessao rejeitada via ScrapingFailureAlertJob" do
    carregar!
    rejeitar_no_stub!

    RefreshSessionCookiesJob.perform_now

    assert_equal 1, @alertas.size, "primeira rejeição tem que alertar exatamente uma vez"
    scraper, perfil, msg, tipo = @alertas.first
    assert_equal "youtube", scraper
    assert_equal "jar", perfil, "incidente é do jar do domínio, não de um perfil"
    assert_equal "session_rejected", tipo, "tipo de erro nomeado, não genérico"
    assert_match(/rejeitou/i, msg)
  end

  # A rejeição seguinte (a cada 10 min, loop do job) NÃO repete o alerta:
  # (a) com o jar já invalidado o job sai no guard `valid?` — sem sonda, sem
  # alerta; (b) se o jar volta a ser servido e o servidor rejeita DE NOVO, o
  # corpo do `ScrapingFailureAlertJob` deduplica pelo AlertThrottler (o padrão
  # do repo) e a mensagem NÃO chega ao Discord.
  test "rejeicao repetida nao repete o alerta (guard do job + dedupe do AlertThrottler)" do
    carregar!
    rejeitar_no_stub!
    RefreshSessionCookiesJob.perform_now
    assert_equal 1, @alertas.size, "primeira rejeição já alertou"

    # (a) rodada seguinte do loop, jar já invalidado: o guard sai no inicio,
    # nem gasta sonda, e NÃO re-enfileira alerta.
    Open3.expects(:capture3).never
    @alertas.clear
    RefreshSessionCookiesJob.perform_now
    assert_empty @alertas, "com o jar invalidado o job não enfileira alerta de novo"

    # (b) o corpo do alerta em si (o loop a cada 10 min é exatamente isto, se
    # o jar estivesse vivo de novo): a segunda transição idêntica não chega
    # ao Discord — dedupe por incidente, o mesmo padrão do ScrapingFailureAlertJob.
    mandou = 0
    DiscordApiClient.stubs(:send_message).with { |_canal, _texto| mandou += 1; true }
    AlertThrottler.resolve_incident("youtube", "jar")
    ScrapingFailureAlertJob.perform_now("youtube", "jar", "rejeitou a sessao durante a renovacao", "session_rejected")
    ScrapingFailureAlertJob.perform_now("youtube", "jar", "rejeitou a sessao durante a renovacao", "session_rejected")
    assert_equal 1, mandou,
                 "a rejeição repetida não reenvia o alerta — segue o dedupe por incidente do repo"
  end

  # O caminho de recuperação: exportação nova reescreve o jar (mesmo
  # `store!` do fluxo manual do dono), `valid?` volta a true E a renovação
  # bem-sucedida resolve o incidente — a PRÓXIMA rejeição alerta de novo.
  test "exportacao nova devolve valid? a true e a renovacao bem-sucedida resolve o incidente" do
    carregar!
    rejeitar_no_stub!
    RefreshSessionCookiesJob.perform_now
    refute Fetcher::CookieJar.valid?("youtube.com")

    # O dono refaz a exportação — exatamente o caminho que o `store!` cobre.
    carregar!
    assert Fetcher::CookieJar.valid?("youtube.com"),
           "uma exportação nova tem que deixar o jar vivo de novo"

    # Renovação bem-sucedida: o jar continua vivo E o incidente de rejeição
    # que estava consolidado é resolvido (transição de estado — a próxima
    # rejeição alerta de novo, como o teste de dedupe do repo exige).
    # O stub de rejeição acima continua ativo e, sendo seu constraint
    # sempre-verdadeiro, re-escreveria o arquivo como anônimo na fase de
    # rotação — o job casaria com o stub errado e `verify_session!`
    # levantaria de novo (rejeição onde a rotação deveria ter sucesso).
    # Limpar o método deixa só o stub da rotação ativo.
    Open3.unstub(:capture3)
    rotacionar_no_stub!
    @alertas.clear
    # Recuperação é comprovada por COMPORTAMENTO, não por estado de cache: o
    # stub do setup impede o corpo real do alerta, então `incident_state`
    # nunca foi populado aqui — a asserção correta é que a rotação bem-sucedida
    # dispare a resolução do incidente no ponto de recuperação. Asseriona logo
    # após o `perform_now` (antes do `teardown`, que chama o MESMO método
    # para limpar o estado entre testes — por isso captura em vez de `.once`,
    # que contaria a chamada de limpeza e inverteria o teste).
    @resolveu = []
    AlertThrottler.stubs(:resolve_incident)
                        .with { |s, p| @resolveu << [s, p]; true }
    RefreshSessionCookiesJob.perform_now
    assert_equal [["youtube", "jar"]], @resolveu,
                 "rotação bem-sucedida tem que resolver o incidente"
    assert_empty @alertas, "rotação bem-sucedida não gera alerta de rejeição"
    assert Fetcher::CookieJar.valid?("youtube.com")
  end

  # O log continua o canal de leitura para o dono; agora a mensagem DIZ que o
  # jar foi invalidado, e continua ensinando o procedimento.
  test "sessao rejeitada e logada como rejeicao com invalidacao, nao como exportacao velha" do
    carregar!
    rejeitar_no_stub!

    linhas = []
    Rails.logger.stubs(:info).with { |m| linhas << m.to_s; true }

    RefreshSessionCookiesJob.perform_now

    texto = linhas.join("\n")
    assert_match(/rejeitou/i, texto)
    assert_match(/invalidado/i, texto, "o log tem que dizer que o jar foi invalidado")
    assert_no_match(/já estava expirada/i, texto)
    assert_match(/anônima/i, texto, "a mensagem tem que citar a janela anônima")
    assert_match(/robots\.txt/, texto, "tem que citar a aba única")
    assert_match(/fech/i, texto, "tem que mandar fechar a janela")
  end

  test "falha de rede nao derruba o job" do
    carregar!
    Open3.stubs(:capture3).raises(Timeout::Error)
    Rails.logger.stubs(:error)

    assert_nothing_raised { RefreshSessionCookiesJob.perform_now }
    assert_equal 2, Fetcher::CookieJar.for("youtube.com").size
  end

  test "erro inesperado e registrado e relançado" do
    carregar!
    Open3.stubs(:capture3).raises(NoMethodError, "undefined method")
    linhas = []
    Rails.logger.stubs(:error).with { |m| linhas << m.to_s; true }

    assert_raises(NoMethodError) { RefreshSessionCookiesJob.perform_now }
    assert linhas.any? { |l| l.include?("NoMethodError") },
           "erro inesperado deve ser registrado no log: #{linhas.inspect}"
  end

  # O portao de leitura do jar e `expires_at > Time.current`; o job estende o
  # prazo JUNTO da rotacao (`expires_at: 7.days.from_now`) porque acabou de
  # provar a sessao viva.
  test "renovacao estende o expires_at do registro (portao de leitura vivo)" do
    carregar! # expires_at: 3.days.from_now
    rotacionar_no_stub!

    RefreshSessionCookiesJob.perform_now

    registro = BrowserSessionCookie.all.find { |r| r.domain.include?("youtube") }
    assert_not_nil registro, "rotacao deveria ter persistido o registro"
    assert_operator registro.expires_at, :>, 5.days.from_now,
                   "o job tem que estender o prazo (7d) junto da rotacao — o carregar! usou 3d"
  end
end
