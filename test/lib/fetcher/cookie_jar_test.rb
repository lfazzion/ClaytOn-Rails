# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Fetcher::CookieJarTest < ActiveSupport::TestCase
  COOKIES = [
    { "name" => "SID", "value" => "abc123", "domain" => ".youtube.com", "path" => "/" },
    { "name" => "HSID", "value" => "def456", "domain" => ".youtube.com", "path" => "/" }
  ].freeze

  test "grava e le por dominio" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    lidos = Fetcher::CookieJar.for("youtube.com")

    assert_equal 2, lidos.size
    assert_equal "SID", lidos.first["name"]
    assert_equal "abc123", lidos.first["value"]
  end

  test "dominio sem cookie devolve lista vazia e nao e valido" do
    assert_empty Fetcher::CookieJar.for("naoexiste.test")
    refute Fetcher::CookieJar.valid?("naoexiste.test")
  end

  test "cookie expirado nao e valido e nao e servido" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: COOKIES, expires_at: 1.hour.ago)

    refute Fetcher::CookieJar.valid?("reddit.com")
    assert_empty Fetcher::CookieJar.for("reddit.com")
  end

  test "regravar o mesmo dominio substitui, nao acumula" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)
    Fetcher::CookieJar.store!(
      domain: "youtube.com",
      cookies: [{ "name" => "SID", "value" => "novo", "domain" => ".youtube.com", "path" => "/" }],
      expires_at: 7.days.from_now
    )

    lidos = Fetcher::CookieJar.for("youtube.com")

    assert_equal 1, lidos.size
    assert_equal "novo", lidos.first["value"]
  end

  test "subdominio casa o registro do dominio raiz" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: COOKIES, expires_at: 7.days.from_now)

    assert Fetcher::CookieJar.valid?("old.reddit.com")
    refute_empty Fetcher::CookieJar.for("old.reddit.com")
  end

  test "require! levanta Expired nomeando o dominio" do
    erro = assert_raises(Fetcher::CookieJar::Expired) { Fetcher::CookieJar.require!("youtube.com") }

    assert_equal "youtube.com", erro.domain
    assert_includes erro.message, "youtube.com"
  end

  test "o valor do cookie nunca aparece em inspect do modelo" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    registro = BrowserSessionCookie.find_by(domain: "youtube.com")

    refute_includes registro.inspect, "abc123"
  end

  test "with_netscape_file escreve o formato que o yt-dlp le" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    linhas = nil
    Fetcher::CookieJar.with_netscape_file("youtube.com") { |path| linhas = File.read(path).lines }

    assert_equal "# Netscape HTTP Cookie File\n", linhas.first
    campos = linhas.find { |l| l.include?("\tSID\t") }.split("\t")
    assert_equal ".youtube.com", campos[0]
    assert_equal "TRUE", campos[1], "dominio com ponto vale para subdominios"
    assert_equal "/", campos[2]
    assert_equal "SID", campos[5]
    assert_equal "abc123", campos[6].strip
  end

  test "with_netscape_file apaga o arquivo mesmo quando o bloco levanta" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    visto = nil
    assert_raises(RuntimeError) do
      Fetcher::CookieJar.with_netscape_file("youtube.com") do |path|
        visto = path
        raise "erro do bloco"
      end
    end

    refute File.exist?(visto), "cookie de sessao nao pode sobreviver a chamada"
  end

  test "with_netscape_file sem sessao levanta Expired e nao cria arquivo" do
    assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::CookieJar.with_netscape_file("naoexiste.test") { |_p| flunk("nao devia chegar aqui") }
    end
  end
  test "parse_netscape le de volta o que with_netscape_file escreveu" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    lidos = nil
    Fetcher::CookieJar.with_netscape_file("youtube.com") { |p| lidos = Fetcher::CookieJar.parse_netscape(p) }

    assert_equal 2, lidos.size
    assert_equal %w[SID HSID], lidos.map { |c| c["name"] }
    assert_equal "abc123", lidos.first["value"]
    assert_equal ".youtube.com", lidos.first["domain"]
  end

  test "refresh_from_netscape! substitui o payload pelo que o servidor devolveu" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "rotacionado"].join("\t")
      f.flush
      assert Fetcher::CookieJar.refresh_from_netscape!(domain: "youtube.com", path: f.path, auth_cookies: %w[SID])
    end

    lidos = Fetcher::CookieJar.for("youtube.com")
    assert_equal 1, lidos.size
    assert_equal "rotacionado", lidos.first["value"]
  end

  # O bug de 05/08 nasceu de um chamador NOVO que esqueceu o portao. Um portao que
  # so existe no chamador se perde no proximo chamador; este vive na unica funcao
  # que persiste, entao nao ha como escrever a chamada destrutiva sem declarar o
  # que precisa sobreviver.
  test "refresh_from_netscape! recusa apagar a autenticacao com o conjunto anonimo" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "PREF", "anonimo"].join("\t")
      f.flush
      recusou = Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: f.path, auth_cookies: %w[SID __Secure-1PSID LOGIN_INFO]
      )
      assert_not recusou, "persistir conjunto sem autenticacao destroi a sessao"
    end

    assert_equal "abc123", Fetcher::CookieJar.for("youtube.com").find { |c| c["name"] == "SID" }&.dig("value")
  end

  test "refresh_from_netscape! persiste quando a autenticacao sobreviveu" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "rotacionado"].join("\t")
      f.flush
      assert Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: f.path, auth_cookies: %w[SID __Secure-1PSID LOGIN_INFO]
      )
    end

    assert_equal "rotacionado", Fetcher::CookieJar.for("youtube.com").first["value"]
  end

  # O conserto do auto-sabotagem do RefreshSessionCookiesJob: renovar o payload
  # sem estender o prazo deixava o portão de leitura (`expires_at > Time.current`)
  # matar a sessão em T0+7d mesmo com ela viva e recém-rotacionada no banco.
  test "refresh_from_netscape! estende expires_at junto da rotacao quando recebido" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 1.hour.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "rotacionado"].join("\t")
      f.flush
      assert Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: f.path, auth_cookies: %w[SID], expires_at: 7.days.from_now
      )
    end

    registro = BrowserSessionCookie.find_by(domain: "youtube.com")
    assert_operator registro.expires_at, :>, 2.days.from_now, "o prazo foi estendido junto da rotação"
    assert_equal "rotacionado", Fetcher::CookieJar.for("youtube.com").first["value"]
  end

  test "refresh_from_netscape! sem expires_at nao mexe no prazo existente" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 3.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "rotacionado"].join("\t")
      f.flush
      assert Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: f.path, auth_cookies: %w[SID]
      )
    end

    registro = BrowserSessionCookie.find_by(domain: "youtube.com")
    assert_in_delta 3.days.from_now.to_f, registro.expires_at.to_f, 60,
                    "chamada antiga (sem o argumento) continua só rotacionando o payload"
  end

  # A armadilha: gravar por `old.reddit.com` criaria um SEGUNDO registro ao lado
  # de `reddit.com`, e as duas copias divergiriam a partir da proxima chamada.
  test "refresh_for! atualiza o registro do dominio raiz, nao cria um por subdominio" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: COOKIES, expires_at: 7.days.from_now)
    novos = [{ "name" => "reddit_session", "value" => "rotacionado", "domain" => ".reddit.com", "path" => "/" }]

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", novos)

    assert_equal 1, BrowserSessionCookie.where(domain: %w[reddit.com old.reddit.com]).count
    assert_equal "rotacionado", Fetcher::CookieJar.for("old.reddit.com").first["value"]
  end

  # O MESMO bug do `RefreshSessionCookiesJob`, no caminho do NAVEGADOR. Se a sessao
  # e rejeitada durante a visita, os cookies da pagina viram o conjunto anonimo, e
  # `persist_rotation` os grava por cima do jar bom. Nao e vazio, entao o unico
  # guarda que existia (`cookies.blank?`) deixa passar.
  test "refresh_for! recusa apagar a autenticacao de um dominio conhecido" do
    autenticado = [{ "name" => "reddit_session", "value" => "bom", "domain" => ".reddit.com", "path" => "/" }]
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: autenticado, expires_at: 7.days.from_now)
    anonimos = [{ "name" => "csv", "value" => "x", "domain" => ".reddit.com", "path" => "/" }]

    refute Fetcher::CookieJar.refresh_for!("old.reddit.com", anonimos)
    assert_equal "bom", Fetcher::CookieJar.for("reddit.com").find { |c| c["name"] == "reddit_session" }&.dig("value")
  end

  test "refresh_for! persiste quando a autenticacao sobreviveu a rotacao" do
    Fetcher::CookieJar.store!(
      domain: "reddit.com",
      cookies: [{ "name" => "reddit_session", "value" => "antigo", "domain" => ".reddit.com", "path" => "/" }],
      expires_at: 7.days.from_now
    )
    girados = [{ "name" => "reddit_session", "value" => "rotacionado", "domain" => ".reddit.com", "path" => "/" }]

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", girados)
    assert_equal "rotacionado", Fetcher::CookieJar.for("reddit.com").first["value"]
  end

  # Dominio sem sentinela cadastrada nao pode ficar bloqueado: o portao so vale
  # para quem foi declarado, senao adicionar um canal novo quebraria a rotacao dele.
  test "refresh_for! deixa passar dominio sem sentinela declarada" do
    Fetcher::CookieJar.store!(domain: "exemplo.test", cookies: COOKIES, expires_at: 7.days.from_now)
    novos = [{ "name" => "qualquer", "value" => "coisa", "domain" => ".exemplo.test", "path" => "/" }]

    assert Fetcher::CookieJar.refresh_for!("exemplo.test", novos)
  end

  test "refresh_for! nao inventa registro para dominio sem sessao" do
    refute Fetcher::CookieJar.refresh_for!("naoexiste.test", [{ "name" => "a", "value" => "b" }])
    assert_nil BrowserSessionCookie.find_by(domain: "naoexiste.test")
  end

  test "refresh_for! ignora lista vazia em vez de apagar a sessao" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: COOKIES, expires_at: 7.days.from_now)

    refute Fetcher::CookieJar.refresh_for!("reddit.com", [])

    assert_equal 2, Fetcher::CookieJar.for("reddit.com").size
  end
end
