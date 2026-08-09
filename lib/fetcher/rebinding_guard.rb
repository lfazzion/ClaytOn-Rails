# frozen_string_literal: true

module Fetcher
  # Fecha a janela de DNS rebinding no caminho do Chrome, onde o navegador
  # re-resolve o hostname sozinho. No caminho estático o `SafeHttpClient` pinou
  # o IP no socket; aqui o máximo que dá para fazer é conferir DEPOIS: o
  # `remoteIPAddress` do documento principal é o IP que o Chrome usou de fato, e
  # o chamador o compara com o IP que o `SsrfGuard` fixou na validação.
  #
  # Funciona com a Page de verdade (Ferrum 0.17) e com dublê que implemente
  # `on`/`off` — os testes entram pelo dublê.
  module RebindingGuard
    class << self
      # Assina `Network.responseReceived` ANTES de navegar, roda o bloco (o
      # `go_to` e as esperas) e devolve o `remoteIPAddress` do último documento
      # principal. nil quando o CDP não expõe o campo — o chamador decide o
      # que fazer (hoje: loga e segue, para não derrubar o caminho inteiro).
      def capture_document_remote_ip(page)
        captured = nil
        id = page.on("Network.responseReceived") do |params|
          next unless params["type"] == "Document"

          ip = params.dig("response", "remoteIPAddress").to_s
          captured = ip if ip.present?
        end
        yield
        captured
      ensure
        page.off("Network.responseReceived", id) if id
      end
    end
  end
end
