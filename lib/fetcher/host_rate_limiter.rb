# frozen_string_literal: true

module Fetcher
  # Contador por host compartilhado entre PageFetcher (Chrome) e ExtractService
  # (fetch estático). Mesma chave de cache nos dois: o teto é de educação com o
  # site alvo, não com o caminho de código que fez a requisição.
  #
  # `scope` existe porque um host pode ser alcançado por caminhos de custo
  # diferente. No x.com, ler permalink pelo espelho não toca a conta de ninguém,
  # enquanto abrir a timeline gasta a sessão pessoal do dono — um balde só fazia
  # o barato derrubar o caro, medido em 06/08.
  #
  # `per_hour` limita VOLUME, que a janela de minuto não limita: 4/min deixa
  # passar 240/h. As duas janelas incrementam na TENTATIVA, não no sucesso;
  # numa cota que protege conta pessoal, contar a mais é o erro seguro.
  module HostRateLimiter
    MAX_PER_WINDOW = 5
    WINDOW_SECONDS = 60
    HOUR_SECONDS   = 3600
    KEY_PREFIX     = "page_fetch:rl"

    class << self
      def exceeded?(host, max: MAX_PER_WINDOW, scope: nil, per_hour: nil)
        estourou_hora = per_hour && over?(key(host, scope, "hora"), per_hour, HOUR_SECONDS)
        estourou_minuto = over?(key(host, scope), max, WINDOW_SECONDS)
        estourou_hora || estourou_minuto
      end

      private

      def key(host, scope, sufixo = nil)
        [KEY_PREFIX, host, scope, sufixo].compact.join(":")
      end

      def over?(chave, teto, janela)
        count = Rails.cache.increment(chave, 1, expires_in: janela)
        !count.nil? && count > teto
      end
    end
  end
end
