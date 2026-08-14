# frozen_string_literal: true

require "test_helper"

class RefreshSessionCookiesJobTest < ActiveSupport::TestCase
  COOKIES = [
    { "name" => "SID", "value" => "abc", "domain" => ".youtube.com", "path" => "/" },
    { "name" => "__Secure-1PSIDTS", "value" => "sidts-ANTIGO", "domain" => ".youtube.com", "path" => "/" }
  ].freeze

  def carregar!
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 3.days.from_now)
  end

  test "sem sessao no jar nao gasta processo" do
    Open3.expects(:capture3).never

    assert_nothing_raised { RefreshSessionCookiesJob.perform_now }
  end

  # O ponto do job: o yt-dlp reescreve o arquivo com o que o servidor devolveu, e
  # e isso que precisa chegar ao jar. Sem persistir, a renovacao nao serve pra nada.
  test "persiste no jar o token que o servidor rotacionou" do
    carregar!
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

    RefreshSessionCookiesJob.perform_now

    token = Fetcher::CookieJar.for("youtube.com").find { |c| c["name"] == "__Secure-1PSIDTS" }
    assert_equal "sidts-NOVO", token["value"]
  end

  test "sessao rejeitada durante a renovacao nao apaga o jar" do
    carregar!
    ok = Struct.new(:success?).new(true)
    # Servidor devolve so os anonimos — o mesmo sinal de sessao morta.
    Open3.stubs(:capture3).with do |*args|
      caminho = args[args.index("--cookies") + 1]
      File.write(caminho, "# Netscape HTTP Cookie File\n" \
                          "#{['.youtube.com', 'TRUE', '/', 'TRUE', 2_000_000_000, 'PREF', 'x'].join("\t")}\n")
      true
    end.returns(["", "", ok])

    RefreshSessionCookiesJob.perform_now

    # `assert_not_empty` nao serve aqui, e essa fraqueza deixou o bug passar: o
    # conjunto anonimo NAO e vazio, entao o jar destruido aprovava. O que precisa
    # sobreviver e a AUTENTICACAO — sem ela o jar nao vale nada.
    jar = Fetcher::CookieJar.for("youtube.com")
    sobreviveu = jar.any? { |c| Fetcher::Channels::Youtube::AUTH_COOKIES.include?(c["name"]) }
    assert sobreviveu, "renovacao rejeitada sobrescreveu a sessao boa com o conjunto anonimo: #{jar.map { |c| c['name'] }}"
    assert_equal "abc", jar.find { |c| c["name"] == "SID" }&.dig("value")
  end

  # O log e o unico canal entre este job e o dono. Dizer "ja estava expirada"
  # quando o servidor REJEITOU no meio da renovacao manda o dono auditar a propria
  # exportacao — que estava certa. A causa e do lado do servidor e o log tem que
  # dizer isso.
  test "sessao rejeitada no meio da renovacao e logada como rejeicao, nao como exportacao velha" do
    carregar!
    ok = Struct.new(:success?).new(true)
    Open3.stubs(:capture3).with do |*args|
      caminho = args[args.index("--cookies") + 1]
      File.write(caminho, "# Netscape HTTP Cookie File\n" \
                          "#{['.youtube.com', 'TRUE', '/', 'TRUE', 2_000_000_000, 'PREF', 'x'].join("\t")}\n")
      true
    end.returns(["", "", ok])

    linhas = []
    Rails.logger.stubs(:info).with { |m| linhas << m.to_s; true }

    RefreshSessionCookiesJob.perform_now

    assert_match(/rejeitou/i, linhas.join("\n"))
    assert_no_match(/já estava expirada/i, linhas.join("\n"))
  end

  # A mensagem tem que ENSINAR, não só avisar. Em 05-06/08 a sessão foi perdida
  # quatro vezes pela MESMA causa — export feito de janela com o app aberto, duas
  # cópias rotacionando em paralelo — e quem lia o log via "precisa de exportação
  # nova" sem saber o que fazer diferente. O procedimento mora na mensagem porque
  # é lá que o dono está quando descobre o problema.
  test "o erro de rejeicao ensina o procedimento que evita a reincidencia" do
    carregar!
    ok = Struct.new(:success?).new(true)
    Open3.stubs(:capture3).with do |*args|
      File.write(args[args.index("--cookies") + 1],
                 "# Netscape HTTP Cookie File\n" \
                 "#{['.youtube.com', 'TRUE', '/', 'TRUE', 2_000_000_000, 'PREF', 'x'].join("\t")}\n")
      true
    end.returns(["", "", ok])

    linhas = []
    Rails.logger.stubs(:info).with { |m| linhas << m.to_s; true }

    RefreshSessionCookiesJob.perform_now

    texto = linhas.join("\n")
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
    # expects + matcher de bloco no logger QUEBRA no Mocha 3.1.0 quando o
    # ActiveJob LogSubscriber também chama error (matcher recebe nil →
    # include? for nil). Usa stubs + captura + assert posterior.
    linhas = []
    Rails.logger.stubs(:error).with { |m| linhas << m.to_s; true }

    assert_raises(NoMethodError) { RefreshSessionCookiesJob.perform_now }
    assert linhas.any? { |l| l.include?("NoMethodError") },
           "erro inesperado deve ser registrado no log: #{linhas.inspect}"
  end

  # O portao de leitura do jar e `expires_at > Time.current`; o job estende o
  # prazo JUNTO da rotacao (`expires_at: 7.days.from_now`) porque acabou de
  # provar a sessao viva. Sem esta assercao, tirar o `expires_at:` do job deixa
  # a suite verde e a sessao morre em T0+7d com o payload recém-rotacionado.
  test "renovacao estende o expires_at do registro (portao de leitura vivo)" do
    carregar! # expires_at: 3.days.from_now
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

    RefreshSessionCookiesJob.perform_now

    registro = BrowserSessionCookie.all.find { |r| r.domain.include?("youtube") }
    assert_not_nil registro, "rotacao deveria ter persistido o registro"
    assert_operator registro.expires_at, :>, 5.days.from_now,
                   "o job tem que estender o prazo (7d) junto da rotacao — o carregar! usou 3d"
  end
end
