# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Fetcher::CookieJarTest < ActiveSupport::TestCase
  COOKIES = [
    { "name" => "SID", "value" => "abc123", "domain" => ".youtube.com", "path" => "/" },
    { "name" => "HSID", "value" => "def456", "domain" => ".youtube.com", "path" => "/" }
  ].freeze

  REDDIT_COOKIES = [
    { "name" => "reddit_session", "value" => "abc123", "domain" => ".reddit.com", "path" => "/" },
    { "name" => "csv", "value" => "def456", "domain" => ".reddit.com", "path" => "/" }
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
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 1.hour.ago)

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
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)

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
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)
    novos = [{ "name" => "reddit_session", "value" => "rotacionado", "domain" => ".reddit.com", "path" => "/" }]

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", novos)

    assert_equal 1, BrowserSessionCookie.where(domain: %w[reddit.com old.reddit.com]).count
    assert_equal "rotacionado", Fetcher::CookieJar.for("old.reddit.com").first["value"]
  end

  test "refresh_for! atualiza payload e expires_at atomicamente quando fornecido" do
    original_expires = 3.days.from_now.change(usec: 0)
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: original_expires)

    novos = [{ "name" => "reddit_session", "value" => "rotacionado", "domain" => ".reddit.com", "path" => "/" }]
    novo_expires = 7.days.from_now.change(usec: 0)

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", novos, expires_at: novo_expires)

    registro = BrowserSessionCookie.find_by(domain: "reddit.com")
    assert_equal "rotacionado", Fetcher::CookieJar.for("reddit.com").first["value"]
    assert_in_delta novo_expires.to_f, registro.expires_at.to_f, 1,
                     "expires_at atualizado junto do payload"
  end

  test "refresh_for! preserva expires_at quando omitido" do
    original_expires = 3.days.from_now.change(usec: 0)
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: original_expires)

    novos = [{ "name" => "reddit_session", "value" => "rotacionado", "domain" => ".reddit.com", "path" => "/" }]

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", novos)

    registro = BrowserSessionCookie.find_by(domain: "reddit.com")
    assert_equal "rotacionado", Fetcher::CookieJar.for("reddit.com").first["value"]
    assert_in_delta original_expires.to_f, registro.expires_at.to_f, 60,
                     "chamada sem expires_at não deve tocar o prazo existente"
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
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)

    refute Fetcher::CookieJar.refresh_for!("reddit.com", [])

    assert_equal 2, Fetcher::CookieJar.for("reddit.com").size
  end

  test "allowed_domain? aceita dominio exato, ponto inicial, subdominio legitimo, caixa diferente e rejeita sufixo enganoso" do
    assert Fetcher::CookieJar.allowed_domain?("reddit.com", "reddit.com")
    assert Fetcher::CookieJar.allowed_domain?("reddit.com", ".reddit.com")
    assert Fetcher::CookieJar.allowed_domain?("reddit.com", "old.reddit.com")
    assert Fetcher::CookieJar.allowed_domain?("old.reddit.com", ".reddit.com")
    assert Fetcher::CookieJar.allowed_domain?("reddit.com", "Reddit.COM")
    refute Fetcher::CookieJar.allowed_domain?("reddit.com", "notreddit.com")
    refute Fetcher::CookieJar.allowed_domain?("reddit.com", "reddit.com.attacker.com")
  end

  test "allowed_domain? trata politica do X e do Reddit corretamente" do
    assert Fetcher::CookieJar.allowed_domain?("x.com", ".twitter.com")
    assert Fetcher::CookieJar.allowed_domain?("x.com", "twitter.com")
    refute Fetcher::CookieJar.allowed_domain?("x.com", ".doubleclick.net")
    refute Fetcher::CookieJar.allowed_domain?("reddit.com", ".youtube.com")
  end

  test "allowed_domain? com plataforma nao cadastrada nao filtra e loga warn" do
    warn_emitted = false
    Rails.logger.stubs(:warn).with { |msg| warn_emitted = true if msg.to_s.include?("plataforma não cadastrada") }

    assert Fetcher::CookieJar.allowed_domain?("nao-cadastrado.test", "qualquer.com")
    assert warn_emitted
  end

  test "store! filtra cookies pelo dominio da plataforma" do
    misturados = [
      { "name" => "reddit_session", "value" => "val1", "domain" => ".reddit.com", "path" => "/" },
      { "name" => "__Secure-YNID", "value" => "val2", "domain" => ".youtube.com", "path" => "/" }
    ]
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: misturados, expires_at: 7.days.from_now)

    lidos = Fetcher::CookieJar.for("reddit.com")
    assert_equal 1, lidos.size
    assert_equal "reddit_session", lidos.first["name"]
  end

  test "refresh_for! e refresh_from_netscape! filtram cookies antes de persistir" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)
    misturados = [
      { "name" => "reddit_session", "value" => "novo", "domain" => ".reddit.com", "path" => "/" },
      { "name" => "IDE", "value" => "track", "domain" => ".doubleclick.net", "path" => "/" }
    ]

    assert Fetcher::CookieJar.refresh_for!("old.reddit.com", misturados)
    lidos = Fetcher::CookieJar.for("reddit.com")
    assert_equal 1, lidos.size
    assert_equal "novo", lidos.first["value"]

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".reddit.com", "TRUE", "/", "TRUE", 2_000_000_000, "reddit_session", "netscape_val"].join("\t")
      f.puts [".doubleclick.net", "TRUE", "/", "TRUE", 2_000_000_000, "IDE", "track"].join("\t")
      f.flush
      assert Fetcher::CookieJar.refresh_from_netscape!(
        domain: "reddit.com", path: f.path, auth_cookies: %w[reddit_session]
      )
    end

    lidos_net = Fetcher::CookieJar.for("reddit.com")
    assert_equal 1, lidos_net.size
    assert_equal "netscape_val", lidos_net.first["value"]
  end

  test "filtro executa antes do portao de sentinela (sentinela estrangeira presente + conjunto anônimo)" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)
    invalidos = [
      { "name" => "reddit_session", "value" => "foreign", "domain" => ".youtube.com", "path" => "/" },
      { "name" => "csv", "value" => "anon", "domain" => ".reddit.com", "path" => "/" }
    ]

    refute Fetcher::CookieJar.refresh_for!("old.reddit.com", invalidos)
    assert_equal "abc123", Fetcher::CookieJar.for("reddit.com").first["value"]
  end

  test "conjunto vazio apos filtro nao sobrescreve o jar" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)
    so_estrangeiros = [
      { "name" => "SID", "value" => "val", "domain" => ".youtube.com", "path" => "/" }
    ]

    refute Fetcher::CookieJar.refresh_for!("reddit.com", so_estrangeiros)
    assert_equal 2, Fetcher::CookieJar.for("reddit.com").size
    assert_equal "abc123", Fetcher::CookieJar.for("reddit.com").first["value"]
  end

  test "cookies de terceiro emitidos durante visita nao sao persistidos" do
    Fetcher::CookieJar.store!(domain: "x.com", cookies: [{ "name" => "auth_token", "value" => "x1", "domain" => ".x.com", "path" => "/" }], expires_at: 7.days.from_now)
    visita = [
      { "name" => "auth_token", "value" => "x2", "domain" => ".x.com", "path" => "/" },
      { "name" => "IDE", "value" => "track", "domain" => ".doubleclick.net", "path" => "/" }
    ]

    assert Fetcher::CookieJar.refresh_for!("x.com", visita)
    lidos = Fetcher::CookieJar.for("x.com")
    assert_equal 1, lidos.size
    assert_equal "auth_token", lidos.first["name"]
    assert_equal "x2", lidos.first["value"]
  end

  test "nenhum valor de cookie aparece em logs ou mensagens de erro" do
    segredo = "SEGREDO_SUPER_SECRETO_123"
    anonimos = [{ "name" => "csv", "value" => segredo, "domain" => ".reddit.com", "path" => "/" }]
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)

    log_capturado = ""
    Rails.logger.stubs(:warn).with { |msg| log_capturado += msg.to_s }

    refute Fetcher::CookieJar.refresh_for!("old.reddit.com", anonimos)
    refute_includes log_capturado, segredo
  end

  test "store! com lote nao vazio composto apenas de cookies proibidos recusa gravacao e preserva registro e expires_at" do
    original_expires = 7.days.from_now.change(usec: 0)
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: original_expires)
    registro_antes = BrowserSessionCookie.find_by(domain: "reddit.com")
    payload_antes = registro_antes.payload

    proibidos = [
      { "name" => "SID", "value" => "val", "domain" => ".youtube.com", "path" => "/" }
    ]
    novo_expires = 10.days.from_now.change(usec: 0)

    resultado = Fetcher::CookieJar.store!(domain: "reddit.com", cookies: proibidos, expires_at: novo_expires)

    refute resultado, "store! deve retornar false quando todo o lote e filtrado"
    registro_depois = BrowserSessionCookie.find_by(domain: "reddit.com")
    assert_equal payload_antes, registro_depois.payload
    assert_in_delta original_expires.to_f, registro_depois.expires_at.to_f, 1
  end

  test "store! inicial com conjunto totalmente proibido nao cria registro e retorna false" do
    proibidos = [
      { "name" => "SID", "value" => "val", "domain" => ".youtube.com", "path" => "/" }
    ]

    resultado = Fetcher::CookieJar.store!(domain: "reddit.com", cookies: proibidos, expires_at: 7.days.from_now)

    refute resultado
    assert_nil BrowserSessionCookie.find_by(domain: "reddit.com")
  end

  test "platform_for mapeia twitter.com para x.com" do
    assert_equal "x.com", Fetcher::CookieJar.platform_for("twitter.com")
  end

  test "refresh_from_netscape! com auth_cookies presente apenas em dominio proibido retorna false e preserva o jar anterior" do
    Fetcher::CookieJar.store!(domain: "youtube.com", cookies: COOKIES, expires_at: 7.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "PREF", "anonimo"].join("\t")
      f.puts [".doubleclick.net", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "rotacionado"].join("\t")
      f.flush

      resultado = Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: f.path, auth_cookies: %w[SID]
      )

      refute resultado
    end

    lidos = Fetcher::CookieJar.for("youtube.com")
    assert_equal 2, lidos.size
    assert_equal "abc123", lidos.find { |c| c["name"] == "SID" }&.dig("value")
  end

  test "refresh_from_netscape! com conjunto totalmente eliminado pelo filtro retorna false e preserva o jar anterior" do
    Fetcher::CookieJar.store!(domain: "reddit.com", cookies: REDDIT_COOKIES, expires_at: 7.days.from_now)

    Tempfile.create(["jar", ".txt"]) do |f|
      f.puts "# Netscape HTTP Cookie File"
      f.puts [".youtube.com", "TRUE", "/", "TRUE", 2_000_000_000, "SID", "val"].join("\t")
      f.flush

      resultado = Fetcher::CookieJar.refresh_from_netscape!(
        domain: "reddit.com", path: f.path, auth_cookies: %w[reddit_session]
      )

      refute resultado
    end

    lidos = Fetcher::CookieJar.for("reddit.com")
    assert_equal 2, lidos.size
    assert_equal "abc123", lidos.find { |c| c["name"] == "reddit_session" }&.dig("value")
  end
end
