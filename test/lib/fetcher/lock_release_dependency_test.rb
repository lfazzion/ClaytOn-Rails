# frozen_string_literal: true

require "test_helper"
require "solid_cache"
# `lib/fetcher` é autoloadado por constante (Zeigernomics), e um arquivo que
# só define métodos de módulo (`Fetcher.release_lock_atomically`) não tem
# constante que o trigger encontre. Require explícito, como já é feito com
# `fetcher/x_query_id_resolver` nos outros testes do diretório.
require "fetcher/lock_release"

module Fetcher
  # ── RESSALVA DO PR #203: 4 check-then-act INERTES na liberação de lock ────────
  #
  # A varredura da revisão achou quatro pares leitura-antes-de-escrita na
  # LIBERAÇÃO de lock, todos com a mesma forma:
  #
  #   if Rails.cache.read(lock) == token      # <-- leitura
  #     Rails.cache.delete(lock)              # <-- escrita
  #   end
  #
  # Em produção o store é o SolidCache e o caminho genérico nunca roda: os quatro
  # têm um caminho atômico antes dele (`SolidCache::Entry.lock_and_write`,
  # compare-and-delete num passo só). Então o defeito é INERTE — hoje.
  # "Inerte porque o store é o de hoje" é dependência implícita: quem trocar
  # `config.cache_store`, ou rodar num store sem esse caminho, reintroduz a
  # janela read→delete sem nenhum aviso.
  #
  # Este arquivo não conserta os quatro. Ele prova que a janela EXISTE no caminho
  # genérico, medindo com um store que se comporta como qualquer ActiveSupport
  # cache e NÃO tem o atômico do SolidCache. É a prova de que a dependência é
  # CONHECIDA — e o teste falha se o helper deixar de tratar o caso sem o
  # atômico, porque nesse caso ele passa a enxergar a janela em vez de confiar
  # nela em silêncio.
  #
  # A escolha (documentar em vez de reescrever os quatro, e por quê) está escrita
  # em lib/fetcher/lock_release.rb, o ponto único de código.
  class LockReleaseDependencyTest < ActiveSupport::TestCase
    LOCK_KEY = "lock:test"
    TOKEN = "meu-token"

    # Store COMO QUALQUER ActiveSupport::Cache: `read` e `delete` são operações
    # separadas. Representa o FileStore do ambiente de teste e qualquer store
    # futuro que não implemente CAS.
    class PlainReadDeleteStore < ActiveSupport::Cache::MemoryStore
      # Mede a janela read→delete: entre as duas operações este hook roda, que é
      # a chance de outro worker trocar o token por baixo.
      attr_accessor :on_between, :between_calls

      def delete(key, options = nil)
        @between_calls = @between_calls.to_i + 1
        @on_between&.call
        super
      end
    end

    def test_o_caminho_generico_de_release_declara_a_janela
      store = PlainReadDeleteStore.new
      store.write(LOCK_KEY, TOKEN, expires_in: 60)

      # O "outro worker" que TROCA o token entre o read e o delete: é a janela.
      store.on_between = -> { store.write(LOCK_KEY, 'token-de-outro-worker', expires_in: 60) }

      release = Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: store)

      assert_equal :released_non_atomic, release,
                   'sem o atomico do SolidCache, o release tem de DECLARAR que foi pelo caminho com janela'
      refute_nil store.between_calls, 'o teste precisa ter exercitado o caminho generico'
    end

    def test_o_caminho_generico_nao_apaga_lock_de_outro_dono
      store = PlainReadDeleteStore.new
      store.write(LOCK_KEY, 'token-de-outro-worker', expires_in: 60)

      release = Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: store)

      assert_equal :not_owner, release
      assert_equal 'token-de-outro-worker', store.read(LOCK_KEY),
                   'o lock de outro dono nao pode ser removido'
    end

    def test_o_store_real_de_producao_faz_o_release_atomico
      store = SolidCache::Store.new(local_cache: false)
      store.clear
      store.write(LOCK_KEY, TOKEN, expires_in: 60)

      release = Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: store)

      assert_equal :released, release
      assert_nil store.read(LOCK_KEY), 'o lock do dono deveria ter sumido'
    ensure
      store&.clear
    end

    def test_o_store_real_nao_apaga_lock_de_outro_dono
      store = SolidCache::Store.new(local_cache: false)
      store.clear
      store.write(LOCK_KEY, 'token-de-outro-worker', expires_in: 60)

      release = Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: store)

      assert_equal :not_owner, release
      assert_equal 'token-de-outro-worker', store.read(LOCK_KEY),
                   'o lock de outro dono nao pode ser removido'
    ensure
      store&.clear
    end

    # A dependência implícita que este arquivo existe para tornar VISÍVEL: se
    # alguém trocar o store de produção, o caminho genérico volta a ter janela e
    # ninguém é avisado no boot, no deploy ou no log. Este teste falha se o
    # helper deixar de tratar o caso sem suporte — não se o store mudar.
    def test_a_dependencia_do_store_de_producao_e_explicita_no_codigo
      source = Fetcher.lock_release_dependency_note

      assert_match(/SolidCache/, source, 'a dependencia tem de nomear o store de producao')
      assert_match(/janela/i, source, 'a dependencia tem de nomear a janela que o store atomico evita')
      assert_match(/release_lock_atomically/, source,
                   'a dependencia tem de apontar o ponto unico onde os quatro chamam')
    end
  end
end
