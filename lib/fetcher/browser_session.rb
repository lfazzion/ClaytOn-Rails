# frozen_string_literal: true

require "timeout"
require "uri"
require_relative "cookie_jar"
require_relative "session_cookies"
require_relative "page_fetcher"

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

    class << self
      def with_page(url)
        uri = URI.parse(url.to_s)
        host = uri.host.to_s.downcase
        # Levanta `CookieJar::Expired` nomeando o domínio quando não há sessão em
        # fonte nenhuma — antes de gastar browser.
        cookies, origem = SessionCookies.for(host)

        Timeout.timeout(OVERALL_TIMEOUT) do
          browser = PageFetcher.browser
          context = browser.contexts.create
          page = nil
          begin
            page = context.create_page
            inject_cookies(page, cookies)
            page.go_to(uri.to_s)
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
      end

      private

      # `Ferrum::Cookies#set` é `def set(options)` — hash POSICIONAL, não keywords
      # (cookies.rb:118). A chamada abaixo continua válida porque o método não
      # declara keywords: em Ruby 3+/4 elas viram o hash posicional que ele espera.
      # Ele preenche `domain` com o default e despacha `Network.setCookie`.
      def inject_cookies(page, cookies)
        cookies.each do |cookie|
          page.cookies.set(
            name:   cookie["name"].to_s,
            value:  cookie["value"].to_s,
            domain: cookie["domain"].to_s,
            path:   cookie.fetch("path", "/").to_s
          )
        end
      end

      def persist_rotation(page, host)
        atuais = page.cookies.all.each_value.map do |cookie|
          {
            "name"   => cookie.name.to_s, "value" => cookie.value.to_s,
            "domain" => cookie.domain.to_s, "path" => cookie.path.to_s.presence || "/"
          }
        end
        CookieJar.refresh_for!(host, atuais)
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::BrowserSession] rotação não persistida: #{e.class}: #{e.message}"
      end

      def close_quietly(page)
        page&.close
      rescue StandardError
        nil
      end

      def dispose_quietly(context)
        context&.dispose
      rescue StandardError
        nil
      end
    end
  end
end
