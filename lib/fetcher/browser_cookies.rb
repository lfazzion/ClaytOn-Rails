# frozen_string_literal: true

require_relative "page_fetcher"

module Fetcher
  # Cookies da sessão viva do Chrome, lidos pelo CDP.
  #
  # É a fonte preferida, à frente do jar no banco, porque o perfil do Chrome é
  # quem de fato conversa com a plataforma: quando o servidor manda rotacionar, é
  # ele que rotaciona, e ler dali nunca fica dessincronizado. Foi exatamente a
  # dessincronização entre uma cópia exportada e a sessão viva no navegador do
  # dono que invalidou a primeira sessão de YouTube desta construção.
  #
  # NÃO se usa o `--cookies-from-browser` do yt-dlp de propósito: aquele caminho
  # lê o SQLite do perfil, que navegadores Chromium mantêm travado enquanto rodam
  # — e o nosso roda sempre. Existe até plugin de terceiro só para destravar. Pelo
  # CDP o próprio navegador entrega os cookies em claro, sem tocar no arquivo,
  # sem depender de keyring e sem acoplar caminho de perfil.
  module BrowserCookies
    # O Cookie-Editor usa os nomes da extensão; o CDP quer os do padrão.
    SAME_SITE = {
      "no_restriction" => "None", "lax" => "Lax", "strict" => "Strict",
      "None" => "None", "Lax" => "Lax", "Strict" => "Strict"
    }.freeze

    class << self
      # Devolve [] quando não há sessão (ou nem browser) — quem decide se isso é
      # erro é o canal, que ainda pode cair no jar.
      def for(domain)
        alvo = normalize(domain)

        PageFetcher.browser.cookies.all.each_value.filter_map do |cookie|
          next unless matches?(cookie.domain, alvo)

          {
            "name"   => cookie.name.to_s,
            "value"  => cookie.value.to_s,
            "domain" => cookie.domain.to_s,
            "path"   => cookie.path.to_s.presence || "/"
          }
        end
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::BrowserCookies] sessão do Chrome indisponível: #{e.class}: #{e.message}"
        []
      end

      # Injeta cookies no contexto PADRÃO do Chrome em execução.
      #
      # LIMITE MEDIDO EM 04/08, COM CONTROLE: o `chromedp/headless-shell` NÃO grava
      # cookie em disco, nem com `--user-data-dir`, nem após navegação real, nem
      # com parada graciosa — nenhum arquivo `Cookies` chega a existir no perfil.
      # Logo, o que se injeta aqui vive apenas enquanto o processo do Chrome viver.
      # O armazém durável continua sendo o jar (`Fetcher::CookieJar`); isto é a
      # cópia de trabalho, útil enquanto o navegador está de pé.
      #
      # Recebe o export cru do Cookie-Editor (com `expirationDate`, `secure`,
      # `httpOnly`, `sameSite`), não os quatro campos reduzidos do jar. O motivo é
      # o `expires`: cookie injetado sem prazo é cookie de SESSÃO e o Chrome o
      # descarta no próximo restart — o perfil persistiria vazio, que é
      # exatamente o problema que ele deveria resolver.
      #
      # Devolve quantos cookies do lote são lidos de volta, para a carga poder ser
      # conferida sem imprimir valor nenhum.
      def load!(cookies)
        postos = Array(cookies).filter_map do |cookie|
          nome = cookie["name"].to_s
          next if nome.empty?

          PageFetcher.browser.cookies.set(**atributos(cookie))
          nome
        end

        dominios = Array(cookies).filter_map { |c| c["domain"].to_s.presence }.uniq
        lidos = dominios.flat_map { |d| self.for(d) }.map { |c| c["name"] }.uniq
        { postos: postos.size, confirmados: (postos & lidos).size }
      end

      private

      def atributos(cookie)
        base = {
          name:   cookie["name"].to_s,
          value:  cookie["value"].to_s,
          domain: cookie["domain"].to_s,
          path:   cookie["path"].to_s.presence || "/",
          secure: !cookie["secure"].nil? && cookie["secure"] != false
        }
        base[:httponly] = true if cookie["httpOnly"]
        base[:samesite] = SAME_SITE[cookie["sameSite"].to_s] if SAME_SITE.key?(cookie["sameSite"].to_s)
        # `Ferrum::Cookies#set` faz `expires.to_i` e só o usa quando positivo
        # (cookies.rb:128) — sem isto o cookie vira de sessão e morre no restart.
        base[:expires] = cookie["expirationDate"].to_i if cookie["expirationDate"].to_f.positive?
        base
      end

      # `.youtube.com`, `youtube.com` e `www.youtube.com` são a mesma sessão.
      def matches?(cookie_domain, alvo)
        atual = normalize(cookie_domain)
        atual == alvo || atual.end_with?(".#{alvo}")
      end

      def normalize(domain)
        domain.to_s.downcase.delete_prefix(".").delete_prefix("www.")
      end
    end
  end
end
