# frozen_string_literal: true

require "json"
require "tempfile"

module Fetcher
  # Cookies de sessão por domínio, para os canais que exigem login.
  #
  # Obtenção é manual e fora deste código: exportar de uma janela anônima, porque
  # o YouTube rotaciona o cookie de aba aberta e um cookie exportado de sessão
  # viva se invalida sozinho. Conta descartável, nunca a principal — conta usada
  # por automação corre risco de ban.
  module CookieJar
    class Expired < StandardError
      attr_reader :domain

      def initialize(domain)
        @domain = domain
        super("sessão de #{domain} ausente ou expirada — renovar o cookie do domínio")
      end
    end

    # Nomes que provam sessão viva, por domínio. Existe UM registro só porque o
    # bug de 05/08 nasceu de conhecimento espalhado: o portão morava no canal do
    # YouTube, e o job novo — que persistia pelo mesmo jar — não o tinha.
    #
    # `youtube.com`: `__Secure-3PSID` NÃO entra, e a exclusão é o ponto. Medido em
    # 04/08: ao rejeitar a sessão o YouTube devolve os cookies de terceiro-domínio
    # intactos e some com os de primeira parte; usá-lo como sentinela aprova
    # sessão morta, e foi o que aconteceu.
    # `x.com`: só `auth_token`. O `ct0` é token de CSRF e existe também deslogado,
    # então serviria de sentinela para um conjunto anônimo.
    AUTH_SENTINELS = {
      "youtube.com" => %w[SID __Secure-1PSID LOGIN_INFO].freeze,
      "reddit.com"  => %w[reddit_session].freeze,
      "x.com"       => %w[auth_token].freeze
    }.freeze

    PLATFORM_DOMAINS = {
      "youtube.com" => ["youtube.com"].freeze,
      "reddit.com"  => ["reddit.com"].freeze,
      "x.com"       => ["x.com", "twitter.com"].freeze
    }.freeze

    class << self
      def platform_for(host)
        alvo = normalize(host)
        platform, _ = PLATFORM_DOMAINS.find do |dominio, list|
          alvo == dominio || alvo.end_with?(".#{dominio}") ||
            list.any? { |d| alvo == d || alvo.end_with?(".#{d}") }
        end
        platform
      end

      def allowed_domain?(host, cookie_domain)
        platform = platform_for(host)
        if platform.nil?
          Rails.logger.warn "[Fetcher::CookieJar] plataforma não cadastrada na allowlist para host '#{host}' — cookie não filtrado"
          return true
        end

        allowed_list = PLATFORM_DOMAINS[platform]
        cdom = cookie_domain.to_s.downcase.sub(/\A\./, "")
        return false if cdom.empty?

        allowed_list.any? do |allowed|
          norm_allowed = allowed.downcase.sub(/\A\./, "")
          cdom == norm_allowed || cdom.end_with?(".#{norm_allowed}")
        end
      end

      def filter_cookies(host, cookies)
        Array(cookies).select do |cookie|
          cdom = cookie["domain"] || cookie[:domain]
          allowed_domain?(host, cdom)
        end
      end

      def store!(domain:, cookies:, expires_at:)
        filtered = filter_cookies(domain, cookies)
        return false if filtered.blank?

        record = BrowserSessionCookie.find_or_initialize_by(domain: normalize(domain))
        record.payload = JSON.generate(filtered)
        record.expires_at = expires_at
        record.save!
        true
      end

      def for(domain)
        record = live_record(domain)
        return [] if record.nil?

        JSON.parse(record.payload)
      rescue JSON::ParserError
        Rails.logger.error "[Fetcher::CookieJar] payload de #{domain} não é JSON — tratando como ausente"
        []
      end

      def valid?(domain)
        !live_record(domain).nil?
      end

      def require!(domain)
        raise Expired, normalize(domain) unless valid?(domain)

        true
      end

      # Escreve os cookies do domínio num arquivo Netscape temporário e entrega o
      # caminho ao bloco. É o formato que o `yt-dlp --cookies` lê.
      #
      # Arquivo em vez de argumento porque valor de cookie em linha de comando
      # aparece em `ps` para qualquer processo da máquina. Modo 0600 antes de
      # escrever, e `unlink` no `ensure` — o arquivo não sobrevive à chamada nem
      # quando o bloco levanta.
      # `cookies:` permite injetar outra fonte — hoje a sessão viva do Chrome,
      # lida pelo CDP em `Fetcher::BrowserCookies`. Sem o parâmetro, usa o jar.
      def with_netscape_file(domain, cookies: nil)
        cookies ||= self.for(domain)
        raise Expired, normalize(domain) if cookies.empty?

        file = Tempfile.new(["jar", ".txt"])
        begin
          file.chmod(0o600)
          file.write(netscape_body(cookies))
          file.flush
          yield file.path
        ensure
          file.close
          file.unlink
        end
      end

      # Lê de volta um arquivo Netscape. O `yt-dlp` REESCREVE o arquivo que
      # recebe em `--cookies`, então depois da chamada ele contém o que o
      # servidor devolveu — que é a única evidência de que a sessão sobreviveu.
      def parse_netscape(path)
        File.readlines(path).filter_map do |linha|
          next if linha.start_with?("#") || linha.strip.empty?

          campos = linha.chomp.split("\t")
          next if campos.size < 7

          { "name" => campos[5], "value" => campos[6], "domain" => campos[0], "path" => campos[2] }
        end
      rescue Errno::ENOENT
        []
      end

      # Sobe rótulos como a leitura faz: `old.reddit.com` responde pelo de `reddit.com`.
      # Domínio não cadastrado devolve lista vazia — o portão vale para quem foi
      # declarado, senão registrar um canal novo quebraria a rotação dele em silêncio.
      def sentinels_for(host)
        alvo = normalize(host)
        _, nomes = AUTH_SENTINELS.find { |dominio, _| alvo == dominio || alvo.end_with?(".#{dominio}") }
        nomes || []
      end

      # Atualiza o registro que de fato atende este host, seguindo a mesma subida
      # de rótulos da leitura. Guardar por `old.reddit.com` criaria um segundo
      # registro ao lado de `reddit.com` e as duas cópias divergiriam na hora.
      #
      # O portão de autenticação vale AQUI também, e não só no caminho do yt-dlp:
      # quem chega por este método é `BrowserSession#persist_rotation`, e uma sessão
      # rejeitada durante a visita deixa a página com o conjunto anônimo — que não é
      # vazio e passaria pelo único guarda que existia antes.
      def refresh_for!(host, cookies, expires_at: nil)
        filtered = filter_cookies(host, cookies)
        return false if filtered.blank?

        sentinelas = sentinels_for(host)
        if sentinelas.present? && !sentinelas.intersect?(filtered.map { |c| (c["name"] || c[:name]).to_s })
          Rails.logger.warn "[Fetcher::CookieJar] rotação de #{normalize(host)} recusada: " \
                            "veio sem autenticação e sobrescreveria a sessão boa"
          return false
        end

        record = live_record(host)
        return false if record.nil?

        # Sol rodada 2 (13/08): o ciclo ler-expires_at→update! tinha TOCTOU —
        # duas rotações concorrentes podiam calcular o piso sobre o MESMO valor
        # antigo e a gravação atrasada sobrescrever o payload/prazo da outra.
        # with_lock serializa leitura + cálculo + gravação (transação no banco).
        record.with_lock do
          if expires_at
            # ACHADO C (revisão do sol, 13/08): não FORÇAR o prazo para o valor
            # solicitado — isso encurtava sessões válidas por 30 dias para 7. O
            # prazo solicitado é um PISO (max), preservando o que já existia de
            # mais longo. `record.expires_at` vem de um registro vivo, então não é nil.
            piso = [record.expires_at, expires_at].compact.max
            record.update!(payload: JSON.generate(filtered), expires_at: piso)
          else
            record.update!(payload: JSON.generate(filtered))
          end
        end
        true
      end

      # Persiste de volta o que o servidor rotacionou. Sem isto toda chamada
      # reapresenta o cookie original; o YouTube rotaciona `__Secure-*PSIDTS` a
      # cada uso e a sessão morre mais cedo do que precisaria.
      # `auth_cookies` é OBRIGATÓRIO, e é obrigatório de propósito: os nomes que
      # precisam sobreviver à rotação. Quando o servidor rejeita a sessão ele não
      # devolve arquivo vazio — devolve o conjunto ANÔNIMO, que passa por qualquer
      # teste de "veio alguma coisa" e apaga a sessão boa ao ser persistido. Foi o
      # que aconteceu em 05/08: 21 cookies viraram 12, sem autenticação, e só
      # exportação manual do dono trouxe a sessão de volta.
      #
      # O portão mora aqui, e não só no chamador, porque foi exatamente um
      # chamador novo (`RefreshSessionCookiesJob`) que esqueceu de verificar. Com
      # a chave obrigatória não há como escrever a chamada destrutiva sem declarar
      # o que se espera preservar. `[]` desliga o portão, mas aí é escolha
      # declarada no ponto da chamada, não descuido.
      #
      # `expires_at:` estende a validade do registro JUNTO da rotação. Sem isto o
      # job renovava o payload a cada 10 min mas o portão de leitura
      # (`expires_at > Time.current`) matava a sessão no prazo antigo — o job se
      # sabota em T0+7d com uma sessão viva e recém-rotacionada no banco.
      def refresh_from_netscape!(domain:, path:, auth_cookies:, expires_at: nil)
        raw_cookies = parse_netscape(path)
        cookies = filter_cookies(domain, raw_cookies)
        return false if cookies.empty?
        return false if auth_cookies.present? && !auth_cookies.intersect?(cookies.map { |c| (c["name"] || c[:name]).to_s })

        record = BrowserSessionCookie.find_by(domain: normalize(domain))
        return false if record.nil?

        attrs = { payload: JSON.generate(cookies) }
        attrs[:expires_at] = expires_at if expires_at
        record.update!(**attrs)
        true
      end

      private

      # Formato Netscape: domain, include_subdomains, path, secure, expiry, name,
      # value — separados por TAB. O `include_subdomains` segue a convenção do
      # formato: verdadeiro quando o domínio começa com ponto.
      def netscape_body(cookies)
        linhas = ["# Netscape HTTP Cookie File", "# gerado por Fetcher::CookieJar — efêmero"]
        expiry = 1.year.from_now.to_i

        Array(cookies).each do |cookie|
          domain = cookie["domain"].to_s
          next if domain.empty? || cookie["name"].to_s.empty?

          linhas << [
            domain, domain.start_with?(".") ? "TRUE" : "FALSE",
            cookie.fetch("path", "/").to_s.presence || "/",
            "TRUE", expiry, cookie["name"].to_s, cookie["value"].to_s
          ].join("\t")
        end
        "#{linhas.join("\n")}\n"
      end

      # `old.reddit.com` e `www.youtube.com` usam a sessão do domínio raiz. O
      # registro é por domínio registrável, e a busca sobe os rótulos até achar.
      def live_record(domain)
        candidates(normalize(domain)).each do |candidate|
          record = BrowserSessionCookie.find_by(domain: candidate)
          return record if record && record.expires_at > Time.current
        end
        nil
      end

      def candidates(domain)
        labels = domain.split(".")
        (0..(labels.size - 2)).map { |i| labels[i..].join(".") }
      end

      def normalize(domain)
        domain.to_s.downcase.delete_prefix("www.")
      end
    end
  end
end
