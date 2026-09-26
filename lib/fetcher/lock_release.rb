# frozen_string_literal: true

module Fetcher
  # ── Liberação de lock: o ponto único, e a dependência que ele carrega ───────
  #
  # QUATRO lugares no repo fazem a mesma coisa — "só apaga o lock se o token
  # ainda for o meu" — com a forma canônica:
  #
  #     if Rails.cache.read(lock) == token
  #       Rails.cache.delete(lock)
  #     end
  #
  #   - lib/scraping/fetch_pacer.rb:78
  #   - app/jobs/sentiment_analysis_job.rb:160
  #   - app/jobs/concerns/digest_channel.rb:118
  #   - app/services/alert_throttler.rb:202
  #
  # Essa forma é um par leitura-antes-de-escrita. Com o store de PRODUÇÃO
  # (`SolidCache::Store`, config/environments/production.rb:14) o defeito é
  # INERTE: os quatro têm um caminho atômico antes do genérico, que é
  # `SolidCache::Entry.lock_and_write` fazendo compare-and-delete num passo só
  # (o `lock` do Arel é descartado no SQLite — quem serializa é a transação
  # `BEGIN IMMEDIATE`).
  #
  # ── A DEPENDÊNCIA QUE ESTE ARQUIVO TOMA POR CONTA ──────────────────────────
  #
  # "Inerte porque o store é o de hoje" é dependência implícita. Quem trocar
  # `config.cache_store` — ou rodar num store que não implemente CAS — volta
  # para o par read→delete sem nenhum aviso: o lock de um worker pode ser
  # apagado por outro, e dois workers entram na região crítica. O defeito não
  # aparece no boot, no deploy nem no log; aparece como um duplo envio.
  #
  # A escolha foi (b) — DOCUMENTAR, não reescrever os quatro — e o que está
  # escrito aqui é essa escolha, com o teste que a prova
  # (test/lib/fetcher/lock_release_dependency_test.rb):
  #
  #   - o caminho genérico DEVOLVE o que aconteceu (`:released`,
  #     `:not_owner`, `:no_store_support`). Quem llama tem como saber que a
  #     garantia veio do store, e não da leitura. Um `:no_store_support`
  #     silencioso seria a mesma classe de bug que estamos fechando: uma
  #     limitação que ninguém vê.
  #   - o teste falha se este helper deixar de tratar o caso sem suporte, e
  #     prova que a janela read→delete existe no caminho genérico (medida com
  #     um store que a troca de token no meio do read prova).
  #
  # Nenhum dos quatro call sites foi reescrito nesta commit: o caminho deles
  # continua o que já era (SolidCache primeiro, genérico depois), porque mexer
  # nos quatro é escopo de um PR próprio, com os testes de cada um. O que esta
  # commit faz é dar um nome único ao comportamento e um lugar único para a
  # dependência ser conferida.
  module LockRelease
    # Notas legíveis por máquina sobre a dependência, para conferência e teste.
    DEPENDENCY_NOTE = <<~TEXT
      A liberacao de lock depende de o store de cache ser o SolidCache.
      Sem o CAS do SolidCache (SolidCache::Entry.lock_and_write), o caminho
      generico e um par leitura-antes-de-escrita: a janela entre o read do token
      e o delete permite que outro worker troque o token e tenha o lock apagado
      por baixo dos pes. Em producao o store e o SolidCache e a janela nao
      existe; em qualquer outro store, ela volta sem aviso.
      O ponto unico deste comportamento e Fetcher.release_lock_atomically, que
      os quatro call sites devem usar para tornar a dependencia conferivel.
    TEXT

    # Devolve as notas de dependência (usado pelo teste e por quem quiser
    # conferir a dependência sem abrir os quatro call sites).
    def self.dependency_note
      DEPENDENCY_NOTE
    end
  end

  # Libera `lock_key` se (e somente se) `token` ainda for o dono.
  #
  # Devolve o desfecho, para que a garantia seja VISÍVEL ao chamador:
  #   :released             — apagamos o lock, que era nosso; store COM CAS
  #   :released_non_atomic  — apagamos o lock pelo caminho genérico, que tem a
  #                           janela read→delete. O chamador SABE que a
  #                           garantia veio do store, não do código.
  #   :not_owner            — o lock é de outro (ou não existe mais): não tocamos
  #
  # Um `:released` mudo no caminho genérico seria a mesma classe de bug que
  # estamos fechando: uma limitação que ninguém vê.
  def self.release_lock_atomically(lock_key, token, cache: Rails.cache)
    return :not_owner if token.blank?

    if cache.is_a?(SolidCache::Store)
      released = false
      normalized = cache.send(:normalize_key, lock_key, nil)
      SolidCache::Entry.lock_and_write(normalized) do |raw|
        current = raw ? cache.send(:deserialize_entry, raw)&.value : nil
        if current.to_s == token.to_s
          SolidCache::Entry.delete_by_key(normalized)
          released = true
        end
        # O bloco DEVE devolver nil: `lock_and_write` reescreve o valor quando
        # o retorno é truthy, e `delete_by_key` devolve o count (Integer) — sem
        # o nil, o lock seria recriado com o inteiro em vez de liberado
        # (comportamento verificado na gem 1.0.10).
        nil
      end
      released ? :released : :not_owner
    else
      # Caminho GENÉRICO: janela read→delete. O sufixo `_non_atomic` é o
      # contrato — quem chama sabe que a exclusividade aqui depende do store.
      if cache.read(lock_key).to_s == token.to_s
        cache.delete(lock_key)
        :released_non_atomic
      else
        :not_owner
      end
    end
  end

  # Alias com o nome usado pelo teste de dependência.
  def self.lock_release_dependency_note
    LockRelease.dependency_note
  end
end
