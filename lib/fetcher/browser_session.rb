# frozen_string_literal: true

require "timeout"
require "uri"
require_relative "cookie_jar"
require_relative "session_cookies"
require_relative "page_fetcher"
require_relative "ssrf_guard"
require_relative "rebinding_guard"
require_relative "channels/registry"

module Fetcher
  # Página do Chrome num contexto isolado, com os cookies do domínio já postos.
  #
  # Contexto por chamada é o que impede o cookie de um domínio de vazar para o
  # fetch seguinte — o browser é compartilhado e vive até 24h (`BROWSER_MAX_AGE`).
  #
  # O cookie entra ANTES do `go_to`: posto depois, a primeira requisição já saiu
  # anônima e a plataforma devolve a página deslogada.
  #
  # A sessão vem do `SessionCookies`, não direto do jar: se o perfil persistente do
  # Chrome já tiver login no domínio, é ELE a fonte, e o jar fica de reserva. Sem
  # isso, logar no perfil da VM não teria efeito nenhum aqui — o contexto isolado
  # nasce limpo e não herda os cookies do contexto padrão.
  module BrowserSession
    # Fica DENTRO de `ExtractService::CHANNEL_TIMEOUT` (40s), que por sua vez fica
    # abaixo dos 90s do plugin do reader. Mexer num exige manter a ordem.
    OVERALL_TIMEOUT = 35

    class RenderTimeout < Channels::Error
      def initialize(msg = nil)
        super(msg || "tempo de render excedeu #{OVERALL_TIMEOUT}s")
      end
    end

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
        # Levanta `CookieJar::Expired` nomeando o domínio quando não há sessão em
        # fonte nenhuma — antes de gastar browser.
        cookies, origem = SessionCookies.for(host)

        PageFetcher.track_in_flight do
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

                original_timeout = (page.timeout rescue nil)
                begin
                  page.timeout = PageFetcher::GOTO_TIMEOUT if page.respond_to?(:timeout=)
                  # Assinante ANTES do go_to: é o que captura o remoteIPAddress do
                  # documento principal, para o cheque de rebinding abaixo.
                  remote_ip = RebindingGuard.capture_document_remote_ip(page) do
                    begin
                      page.go_to(uri.to_s)
                    rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
                      body_check = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s.strip
                      raise RenderTimeout if body_check.empty?
                    end
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
            raise RenderTimeout
          ensure
            Thread.current[:fetcher_deadline] = nil
          end
        end
      end

      private

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
