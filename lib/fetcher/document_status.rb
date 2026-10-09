# frozen_string_literal: true

module Fetcher
  # Status HTTP do DOCUMENTO PRINCIPAL de uma navegação.
  #
  # Existe porque a fonte que o código usava (`page.network.response&.status`)
  # é o ÚLTIMO exchange da sessão CDP, não o do documento: medido em produção,
  # saiu VAZIA em 53 de 65 navegações do Reddit (e reconfirmado no log vivo:
  # `status=` vazio em todas as de 15,0s). Ler o status de lá é ler o exchanges
  # errado — e o `Network.responseReceived` do tipo `Document` carrega o status
  # do documento, que é o que a regra 4 nomeia.
  #
  # MEDIDO (scripts/proofs/reddit_403_status_source_p4.rb, Chrome NOVO, mesmo
  # container/IP de produção): o evento chega com `status=403` em 0,117s contra
  # old.reddit.com, e com `status=200` nos hosts que respondem. O mesmo script
  # mediu ZERO eventos contra o Chrome de produção de 24h — a sessão
  # envenenada, não o código (o caminho cru, que é o mesmo Ferrum, voltou
  # preenchido). Por isso este módulo devolve `nil` quando o evento não chega,
  # em vez de inventar status: quem chama decide, e o padrão da casa é
  # fail-open.
  #
  # A assinatura é a MESMA do `RebindingGuard.capture_document_remote_ip` —
  # dois assinantes do mesmo evento, cada um com o que precisa.
  module DocumentStatus
    class << self
      # Assina `Network.responseReceived` ANTES de navegar, roda o bloco (o
      # `go_to` e as esperas) e devolve o status do último documento principal
      # (Integer), ou nil quando o CDP não entregou o campo/evento.
      def capture(page)
        captured = nil
        id = page.on("Network.responseReceived") do |params|
          next unless params["type"] == "Document"

          status = params.dig("response", "status")
          captured = status.to_i if status.is_a?(Numeric)
        end
        yield
        captured
      ensure
        page.off("Network.responseReceived", id) if id
      end
    end
  end
end
