# frozen_string_literal: true

require_relative "browser_cookies"
require_relative "cookie_jar"

module Fetcher
  # Precedência de fonte de sessão, compartilhada por todos os canais autenticados.
  #
  # Existe para que YouTube e Reddit não divirjam: os dois precisam da mesma
  # resposta para "de onde vem a sessão deste domínio". Antes o canal de YouTube
  # já preferia a sessão viva do Chrome enquanto o Reddit só olhava o jar — quem
  # logasse no perfil da VM via o Reddit continuar pedindo cookie.
  #
  # 1. A sessão viva do perfil do Chrome, lida por CDP. É a fonte boa: o navegador
  #    é quem rotaciona quando o servidor manda, então nunca está desatualizada.
  # 2. O jar no banco, para quando o perfil ainda não tem login.
  #
  # A origem volta junto porque só o jar pode ser reescrito depois da chamada — o
  # perfil se atualiza sozinho, e gravar por cima recriaria a cópia
  # dessincronizada que este desenho existe para evitar.
  module SessionCookies
    class << self
      def for(domain)
        vivos = BrowserCookies.for(domain)
        return [vivos, :browser] if vivos.any?

        guardados = CookieJar.for(domain)
        raise CookieJar::Expired, domain if guardados.empty?

        [guardados, :jar]
      end
    end
  end
end
