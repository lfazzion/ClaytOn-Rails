# frozen_string_literal: true

require "timeout"
require "uri"
require_relative "cookie_jar"
require_relative "session_cookies"
require_relative "bot_detection"
require_relative "document_status"
require_relative "page_fetcher"
require_relative "ssrf_guard"
require_relative "rebinding_guard"
require_relative "channels/registry"

module Fetcher
  # Página do Chrome num contexto isolado, com os cookies do domínio já postos.
  #
  # Contexto por chamada é o que impede o cookie de um domínio de vazar para o
  # fetch seguinte — o browser é compartilhado e vive até 30min (`BROWSER_MAX_AGE`).
  #
  # O cookie entra ANTES do `go_to`: posto depois, a primeira requisição já saiu
  # anônima e a plataforma devolve a página deslogada.
  #
  # A sessão vem do `SessionCookies`, não direto do jar: se o perfil persistente do
  # Chrome já tiver login no domínio, é ELE a fonte, e o jar fica de reserva. Sem
  # isso, logar no perfil da VM não teria efeito nenhum aqui — o contexto isolado
  # nasce limpo e não herda os cookies do contexto padrão.
  #
  # A leitura de cookies (`SessionCookies.for` → `BrowserCookies.for`) roda ANTES
  # de criar o contexto isolado do fetch: o contexto do fetch nasce com
  # `disposeOnDetach: true`, ou seja, morre com a sessão de debug deste request
  # (`dispose_quietly` no ensure). Reaproveitá-lo para ler depois seria ler de um
  # jar que já foi despejado — o laudo r3 B3/Item 4: `disposeOnDetach` é do
  # REQUEST, não do default_context. O default_context do Ferrum é a fonte que
  # pereniza os cookies; o contexto do fetch é só a arena de render, descartada
  # no ensure e nunca reutilizada para leitura.
  module BrowserSession
    # Fica DENTRO de `ExtractService::CHANNEL_TIMEOUT` (40s), que por sua vez fica
    # abaixo dos 90s do plugin do reader. Mexer num exige manter a ordem.
    OVERALL_TIMEOUT = 35

    # Chrome do app é a imagem chromedp/headless-shell — anuncia UA
    # `HeadlessChrome/1xx`. O Reddit bloqueia essa assinatura (mesmos cookies,
    # mesmo IP: UA normal = resultados, UA HeadlessChrome = página "whoa there,
    # pardner"). Corrigido com `Network.setUserAgentOverride` SÓ para hosts
    # reddit — nunca no UA global, que mudaria o comportamento medido do
    # YouTube/X. O host `old.reddit.com` é o SEARCH_HOST do canal Reddit; o
    # prefixo `reddit.com` cobre URLs que o canal reescreve para old.
    # Regex: casa `reddit.com` e qualquer subdomínio (old.reddit.com,
    # www.reddit.com, br.reddit.com), rejeita youtube.com, x.com.
    REDDIT_HOSTS = /(^|\.)reddit\.com\z/i.freeze

    # UA determinístico de Chrome/Windows para o Reddit (Achado 3 do perito):
    # ANTES usava `FerumConfig.random_user_agent` que sorteava entre 4 UAs
    # (3 não-Windows) — platform fixo "Win32" contra UA macOS/Safari dava
    # fingerprint incoerente e prova não-determinística. Agora é UM só,
    # Chrome 131 no Windows, com platform Win32.
    REDDIT_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " \
                        "AppleWebKit/537.36 (KHTML, like Gecko) " \
                        "Chrome/131.0.0.0 Safari/537.36".freeze
    REDDIT_PLATFORM   = "Win32".freeze

    class RenderTimeout < Channels::Error
      def initialize(msg = nil)
        super(msg || "tempo de render excedeu #{OVERALL_TIMEOUT}s")
      end
    end

    # Regra 4 do AGENTS.md no caminho que NAVEGA. Antes estas duas condições não
    # existiam aqui, e nenhuma das duas era possível ver: o cooldown por alvo
    # (BotDetection) só era lido por `PageFetcher#call` — que o canal não usa —
    # e o 403 real chegava como RenderTimeout, que não casa com nenhum padrão de
    # backoff (medido no card t_f63b3613: 6/6 chamadas reais, cooldown nil).
    #
    # Herdam de `Channels::Error` por uma razão prática: o `ExtractService` e o
    # `PlatformSearchTool` já convertem essa raiz em campo `error`/`error(...)`
    # com a mensagem limpa. Um erro novo fora dela subiria como StandardError
    # genérico e o modelo receberia "falha inesperada" — que é convite a repetir.
    class TargetInCooldown < Channels::Error
      attr_reader :host, :entry

      def initialize(host, entry)
        @host = host
        @entry = entry
        restante = restante_em(remaining_seconds(entry))
        super("alvo #{host} está em cooldown de bloqueio (#{entry[:reason]}) — " \
              "volte em #{restante}; não repita a leitura antes disso")
      end

      private

      def remaining_seconds(entry)
        expires = entry[:expires_at]
        return 0 if expires.blank?

        [expires.to_time - Time.current, 0].max
      end

      def restante_em(segundos)
        h = (segundos / 3600).to_i
        m = ((segundos % 3600) / 60).to_i
        h.positive? ? "#{h}h#{m}m" : "#{m}m"
      end
    end

    class TargetBlocked < Channels::Error
      attr_reader :host, :status

      def initialize(host, status)
        @host = host
        @status = status
        super("alvo #{host} respondeu HTTP #{status} (bloqueio por bot/IP) — " \
              "cooldown de 6-12h gravado; não repita a leitura antes de expirar")
      end
    end

    # Status que a regra 4 nomeia como "nunca repetir". 403 é bloqueio de
    # bot/IP; 429 é o limite do próprio site. Os dois contam na tentativa, não
    # só o 403 — repetir um 429 é o que produz a escalada.
    BLOCKING_STATUSES = [403, 429].freeze

    class << self
      def remaining
        deadline = Thread.current[:fetcher_deadline]
        return Float::INFINITY unless deadline

        [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0].max
      end

      def with_page(url)
        uri = URI.parse(url.to_s)
        host = uri.host.to_s.downcase
        # Invariante enforced, não presumida: os chamadores de hoje reescrevem o
        # host para constantes públicas (old.reddit.com, x.com), mas nada no
        # código garantia isso — uma URL privada passada aqui iria direto ao
        # `go_to`, que re-resolve o hostname sozinho. Validar ANTES (inclusive
        # do lookup de cookie) fecha a porta — `resolve!` levanta Blocked se o
        # host for privado; o cheque pós-navegação garante que o Chrome não
        # conectou em IP bloqueado (rebinding).
        SsrfGuard.resolve!(url.to_s)
        # Regra 4 do AGENTS.md, lado (a): o backoff por ALVO, consultado ANTES
        # de gastar browser — e antes até de LER a sessão do domínio, que é
        # leitura de CDP. O mecanismo já existia (`BotDetection.cooldown!`, TTL
        # de 6-12h) e funcionava; só que `PageFetcher#call` era o único que o
        # lia, e o caminho de canal entra por aqui. Medido no card t_f63b3613:
        # o cooldown de old.reddit.com continuava nil depois de 6 chamadas reais
        # que receberam 403 — o backoff tinha mecanismo e não tinha caller.
        #
        # O alvo é o HOST QUE O CHROME VAI ABRIR, que é o da URL reescrita
        # (old.reddit.com na busca e na thread). Gravar e ler pela MESMA chave é
        # o que faz a segunda tentativa respeitar o backoff: o cooldown vive no
        # cache compartilhado, então vale para qualquer processo e qualquer
        # chamador do mesmo alvo.
        #
        # Ordem deliberada: SsrfGuard antes do cooldown (a URL precisa ser
        # válida para ter host) e cooldown antes de `SessionCookies.for` (que
        # gasta CDP). A porta é o que impede a navegação; o custo é o que ela
        # evita.
        check_cooldown!(host)
        # Levanta `CookieJar::Expired` nomeando o domínio quando não há sessão em
        # fonte nenhuma — antes de gastar browser. ROLANDO ANTES do contexto do
        # fetch (laudo r3 Item 4): a leitura usa o default_context do Ferrum, que
        # é o que pereniza os cookies; o contexto do fetch (disposeOnDetach) só
        # nasce depois, e é descartado no ensure sem ser reutilizado para leitura.
        cookies, origem = SessionCookies.for(host)

        PageFetcher.track_in_flight(timeout: OVERALL_TIMEOUT) do
          Thread.current[:fetcher_deadline] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + OVERALL_TIMEOUT
          begin
            Timeout.timeout(OVERALL_TIMEOUT) do
              browser = PageFetcher.browser
              context = browser.contexts.create(disposeOnDetach: true)
              page = nil
              begin
                begin
                  page = context.create_page
                  raise RenderTimeout, "falha ao criar página (target nil)" if page.nil?
                rescue NoMethodError, Ferrum::NoSuchTargetError => e
                  raise RenderTimeout, "falha ao criar página: #{e.message}"
                end

                inject_cookies(page, cookies, host)
                apply_reddit_user_agent!(page, host)

                original_timeout = (page.timeout rescue nil)
                begin
                  # Timeout de navegação reduzido para Reddit (vs geral 20s):
                  # a página de bloqueio volta rápido (< 1s) mesmo se o status
                  # real não foi medido, e com UA real a busca carrega em ~6s.
                  # O timeout é restaurado ANTES do `yield`, então a extração JS
                  # da thread (mais pesada) não fica limitada a 15s.
                  goto_limit = host.match?(REDDIT_HOSTS) ? 15 : PageFetcher::GOTO_TIMEOUT
                  page.timeout = goto_limit if page.respond_to?(:timeout=)
                  # Assinante ANTES do go_to: é o que captura o remoteIPAddress do
                  # documento principal, para o cheque de rebinding abaixo.
                  remote_ip = RebindingGuard.capture_document_remote_ip(page) do
                    # Instrumentação de diagnóstico só para Reddit (Achado 4):
                    # nos outros canais (YouTube, X) cada evaluate extra custa
                    # tempo de CDP e arrisca pendurar em página de erro.
                    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC) if host.match?(REDDIT_HOSTS)
                    if host.match?(REDDIT_HOSTS)
                      Rails.logger.info "[Fetcher::BrowserSession:diag] navegando host=#{host} " \
                                     "goto_limit=#{goto_limit}s timeout_efetivo=#{page.timeout rescue '?'}"
                    end
                    # Regra 4, lado (b): o status do DOCUMENTO, do mesmo evento que
                    # o rebinding usa. `page.network.response` é o último
                    # exchange da sessão e saiu vazio em 53 de 65 navegações
                    # medidas — ler dali era ler o exchange errado.
                    #
                    # O `goto` estourando NÃO é absorvido aqui: o `DocumentStatus`
                    # precisa devolver o status, e devolver exige que o bloco
                    # termine. Por isso o estourão vira uma BANDEIRA, avaliada
                    # logo abaixo, com o status em mãos.
                    goto_estourou = false
                    body_check = nil
                    status_documento = DocumentStatus.capture(page) do
                      begin
                        page.go_to(uri.to_s)
                      rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
                        goto_estourou = true
                        body_check = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s.strip
                      end
                    end
                    if host.match?(REDDIT_HOSTS)
                      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                      url_final = (page.current_url rescue nil) || uri.to_s
                      status_log = status_documento || (page.network.response&.status rescue nil)
                      Rails.logger.info "[Fetcher::BrowserSession:diag] navegou " \
                                     "duracao=#{(t1 - t0).round(3)}s status=#{status_log} " \
                                     "status_documento=#{status_documento.inspect} goto_estourou=#{goto_estourou} " \
                                     "url_final=#{url_final}"
                    end

                    # Ordem importa: o bloqueio é um FATO do servidor (o 403 já
                    # saiu) e o timeout é apenas a falha de quem esperou; com as
                    # duas coisas presentes, o bloqueio é a informação. Classificar
                    # depois do RenderTimeout — que é o que o código fazia — é o
                    # que mantinha a regra 4 inerte: o 403 chegava como timeout,
                    # que não casa com nenhum padrão de backoff.
                    bloquear_se_necessario!(host, status_documento)
                    raise RenderTimeout if goto_estourou && body_check.to_s.empty?
                  end
                ensure
                  if original_timeout && page.respond_to?(:timeout=)
                    begin
                      page.timeout = original_timeout
                    rescue StandardError
                      nil
                    end
                  end
                end

                assert_document_ip!(remote_ip, uri.to_s)
                resultado = yield page
                # O contexto isolado é descartado no `ensure`, e com ele o que o
                # servidor rotacionou durante a visita. Sem gravar de volta, a sessão
                # do Reddit envelheceria congelada — que é justamente o que mata
                # sessão exportada. Só quando a fonte foi o jar: se veio do navegador,
                # é ele o dono e não há o que sincronizar.
                persist_rotation(page, host) if origem == :jar
                resultado
              ensure
                close_quietly(page)
                dispose_quietly(context)
              end
            end
          rescue Timeout::Error, Ferrum::TimeoutError, Ferrum::PendingConnectionsError
            # A sessão envenenada trava o timeout inteiro (a queda de 35s
            # medida): reconstrói o browser para a próxima chamada. Sem retry
            # aqui — o chamador tem orçamento próprio (ExtractService 40s).
            PageFetcher.reset_browser!
            raise RenderTimeout
          ensure
            Thread.current[:fetcher_deadline] = nil
          end
        end
      end

      private

      # Regra 4, lado (a): recusa o alvo em cooldown ANTES de qualquer gasto. O
      # `HostInCooldown` do `PageFetcher` é irmão deste — a diferença é o tipo:
      # este herda de `Channels::Error` porque quem entra por aqui é um CANAL, e
      # o `ExtractService`/`PlatformSearchTool` convertem `Channels::Error` em
      # campo de erro limpo. Um `FetchError` novo subiria como exceção crua.
      def check_cooldown!(host)
        entry = BotDetection.cooldown_for(host)
        raise TargetInCooldown.new(host, entry) if entry
      end

      # Regra 4, lado (b): o 403 (e o 429) que o servidor devolveu é gravado como
      # cooldown do ALVO e levantado como erro nomeado.
      #
      # Gravar e levantar juntos é deliberado: levantar sem gravar deixa a
      # próxima chamada repetir (que era o defeito medido — 65 navegações), e
      # gravar sem levantar devolve ao modelo um `PageFailed` que ele lê como
      # "página ruim" e tenta de novo com outro termo.
      #
      # `status` nil (CDP sem o campo, ou sessão que não emite o evento) não
      # bloqueia: fail-open, como o resto da casa. Um bloqueio inventado a
      # partir de status desconhecido derrubaria o alvo por 6-12h sem prova.
      def bloquear_se_necessario!(host, status)
        return unless BLOCKING_STATUSES.include?(status)

        BotDetection.cooldown!(host, reason: "HTTP #{status}")
        Rails.logger.warn "[Fetcher::BrowserSession] #{host} respondeu HTTP #{status} — " \
                          "cooldown de bloqueio gravado (regra 4); leitura deste alvo suspensa"
        raise TargetBlocked.new(host, status)
      end

      # O `go_to` re-resolve o hostname sozinho. A validação pré-navegação
      # (`SsrfGuard.resolve!`) já garantiu que TODOS os IPs do host são
      # públicos, mas o Chrome pode conectar em qualquer IP público do conjunto
      # (CDN multi-registro, dual-stack A/AAAA) — exigir igualdade com
      # `resolution.ip` (= `ips.first`) derrubava tráfego legítimo. O que
      # importa: o documento principal não pode ter vindo de IP
      # privado/loopback/metadata (rebinding de verdade). Sem o campo (CDP
      # antigo, caminho Python) o cheque desliga com log, melhor que derrubar
      # o caminho.
      def assert_document_ip!(remote_ip, url)
        if remote_ip.to_s.empty?
          Rails.logger.warn "[Fetcher::BrowserSession] remoteIPAddress ausente — " \
                            "validação pós-navegação desativada (fail-open) em #{url}"
          return
        end
        return unless SsrfGuard.ip_blocked?(remote_ip)

        Rails.logger.warn "[Fetcher::BrowserSession] rebinding em #{url}: " \
                          "Chrome conectou em IP bloqueado/privado #{remote_ip}"
        raise SsrfGuard::Blocked.new(
          "DNS rebinding detectado em #{url}: Chrome conectou em IP bloqueado/privado #{remote_ip}"
        )
      end

      # `Ferrum::Cookies#set` é `def set(options)` — hash POSICIONAL, não keywords
      # (cookies.rb:118). A chamada abaixo continua válida porque o método não
      # declara keywords: em Ruby 3+/4 elas viram o hash posicional que ele espera.
      # Ele preenche `domain` com o default e despacha `Network.setCookie`.
      def inject_cookies(page, cookies, host)
        cookies.each do |cookie|
          cdom = cookie["domain"] || cookie[:domain]
          next unless CookieJar.allowed_domain?(host, cdom)

          name = cookie["name"].to_s
          if name.start_with?("__Host-")
            # Prefixo __Host- exige três condições no Chrome/Chromium:
            # Secure=true, Path=/ (exato), e AUSÊNCIA de Domain. Passar
            # `domain` (mesmo nil) faz o Chrome/CDP rejeitar o cookie.
            # `Ferrum::Cookies#set` reinsere `domain: default_domain` (que é nil
            # antes da navegação), gerando `domain: null` no CDP.
            # Por isso chamamos `Network.setCookie` diretamente via `page.command`,
            # passando `url:` e omitindo `domain`.
            resposta = page.command(
              "Network.setCookie",
              name:   name,
              value:  cookie["value"].to_s,
              url:    "https://#{host}/",
              path:   "/",
              secure: true
            )
            # O CDP responde `{ "success": false, "errorText": "..." }` sem
            # lançar exceção quando recusa o cookie (ex: prefixo __Host- com
            # atributo incompatível). Ignorar o retorno deixava a sessão seguir
            # anônima em silêncio — o bug do ACHADO A (revisão do sol, 13/08).
            if resposta.is_a?(Hash) && resposta["success"] == false
              erro = resposta["errorText"].to_s
              Rails.logger.warn "[Fetcher::BrowserSession] Network.setCookie " \
                                "recusou cookie #{name} em #{host}" \
                                "#{erro.present? ? " (CDP: #{erro})" : ''}"
              raise "Falha ao definir cookie __Host- #{name} via Network.setCookie " \
                    "(CDP success:false#{erro.present? ? " — #{erro}" : ''})"
            end
          else
            opts = {
              name:   name,
              value:  cookie["value"].to_s,
              domain: cdom.to_s,
              path:   cookie.fetch("path", "/").to_s
            }
            opts[:secure] = true if name.start_with?("__Secure-")

            page.cookies.set(opts)
          end
        end
      end

      # Override por-página, emitido ANTES do `go_to` — precisa valer já na
      # primeira requisição (a que o Reddit inspeciona). Não toca o perfil
      # persistente do Chrome nem o UA de outros canais.
      #
      # O Network.setUserAgentOverride via chamada CRUA ao CDP é a via certa
      # (Achado 2 do perito): page.user_agent= não existe no Ferrum;
      # page.headers dispara Network.setExtraHTTPHeaders como efeito
      # colateral, e o platform: do Headers é descartado por um bug em
      # ferrum-0.17.2 (headers.rb:73) — impossível setar platform por ali.
      # O Ferrum já emite Network.enable por conta própria em prepare_page
      # (sem argumentos) antes de qualquer comando; re-emitir aqui com
      # buffers zerados quebraria page.body. Por isso NÃO chamamos
      # Network.enable — só o setUserAgentOverride.
      #
      # Este override vive AQUI e não em PageFetcher#render_via_ferrum porque
      # SÓ o canal Reddit precisa dele (YouTube, X e página genérica usam o
      # UA padrão do headless-shell e funcionam). O regex REDDIT_HOSTS cobre
      # old.reddit.com (SEARCH_HOST do canal) e outros subdomínios reddit que
      # podem chegar pelo canal de thread (call/thread_comments). URLs que
      # old_reddit_url rejeita (perfil, /r/x/top) caem no ExtractService contra
      # www.reddit.com SEM o override — é uma limitação conhecida: o UA real
      # nesses casos depende de o ExtractService encaminhar para um canal
      # (hoje não) ou o Reddit não bloquear www.reddit.com sem override
      # (não testado).
      #
      # `platform:` é "Win32" (coerente com o REDDIT_USER_AGENT Windows).
      # `acceptLanguage:` pt-BR para não enviar o en-US padrão do headless-shell.
      # Se a sessão CDP morrer exatamente no setUserAgentOverride (caso raro mas
      # observado: a sonda de `alive?` não garante a vida até o próximo comando),
      # o rescue evita que a exceção crua suba — o canal cai no erro nomeado normal
      # (`RenderTimeout` ou `SsrfGuard::Blocked`) na navegação seguinte.
      def apply_reddit_user_agent!(page, host)
        return unless host.match?(REDDIT_HOSTS)

        page.command("Network.setUserAgentOverride",
          userAgent:      REDDIT_USER_AGENT,
          acceptLanguage: "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
          platform:       REDDIT_PLATFORM)
      rescue *PageFetcher::DEAD_SESSION_ERRORS, Ferrum::Error => e
        Rails.logger.warn "[Fetcher::BrowserSession] UA override falhou " \
                          "(#{e.class}: #{e.message}) — sessão CDP morreu, " \
                          "a navegação deve falhar em seguida"
      end

      def persist_rotation(page, host)
        atuais = page.cookies.all.each_value.map do |cookie|
          {
            "name"   => cookie.name.to_s, "value" => cookie.value.to_s,
            "domain" => cookie.domain.to_s, "path" => cookie.path.to_s.presence || "/"
          }
        end
        CookieJar.refresh_for!(host, atuais, expires_at: 7.days.from_now)
      # Só erros operacionais esperados da serialização são engolidos e
      # logados — não erros de programação. O `rescue StandardError` original
      # engolia NoMethodError/NameError (o bug desta PR, ACHADO B da revisão
      # do sol, 13/08); o `ArgumentError` foi removido na rodada 2 porque o
      # bug original desta PR ERA um ArgumentError de assinatura (refresh_for!
      # sem `expires_at:`) — mantê-lo no rescue recriaria o mascaramento.
      rescue JSON::GeneratorError => e
        Rails.logger.warn "[Fetcher::BrowserSession] rotação não persistida: #{e.class}: #{e.message}"
      end

      def close_quietly(page)
        page&.close
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::BrowserSession] falha ao fechar página (#{e.class}: #{e.message})"
        PageFetcher.mark_dirty!
      end

      def dispose_quietly(context)
        context&.dispose
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::BrowserSession] falha ao descartar contexto (#{e.class}: #{e.message})"
        PageFetcher.mark_dirty!
      end
    end
  end
end
