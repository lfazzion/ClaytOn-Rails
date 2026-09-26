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

    # Desfechos que `release_lock_atomically` tem de prometer na doc E emitir no
    # código. Declarado aqui para que o teste de coerência tenha uma lista
    # explícita: desfecho novo no código sem atualizar esta lista quebra a suíte.
    DESFECHOS_CONTRATADOS = %i[released released_non_atomic not_owner].freeze

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

    # ── A DOC PROMETE O QUE O CÓDIGO NÃO FAZ? (ressalva Minor do #204) ──────
    #
    # A doc de `release_lock_atomically` listava `:no_store_support` como
    # desfecho possível, e o método nunca o produzia. Doc que promete um desfecho
    # inexistente é a MESMA classe de bug que este arquivo existe para fechar: uma
    # limitação (ou capacidade) que ninguém vê.
    #
    # Este teste amarra a doc ao código: os desfechos que a DOCUMENTAÇÃO do
    # método lista têm de ser exatamente os que o método EMITE. Sem ele, voltar
    # a prometer um desfecho fantasma é uma linha de comentário e a suíte fica
    # verde.
    def test_a_doc_nao_promete_desfecho_que_o_codigo_nao_emite
      documentados = desfechos_documentados
      emitidos = desfechos_emitidos

      # (1) A DOC do método tem de listar exatamente o que o código emite.
      # Comparação por VALOR: a doc escreve `:released` e o código devolve
      # `:released`; comparar symbol contra string acusaria um defeito que não
      # existe.
      assert_equal emitidos.map(&:to_s).sort, documentados.map(&:to_s).uniq.sort,
                   "a doc do metodo lista #{documentados.inspect}, mas o codigo emite " \
                   "#{emitidos.inspect}: a documentacao nao pode prometer desfecho que o metodo nao produz"

      # (2) E a lista de contrato deste teste tem de acompanhar o código — se
      # alguém ADICIONAR um desfecho novo, este arquivo é o lugar de saber.
      assert_equal DESFECHOS_CONTRATADOS.sort, emitidos.map { |d| d.to_s.to_sym }.sort,
                   'o contrato deste teste desatualizou em relacao aos desfechos emitidos'
    end

    private

    # Desfechos nomeados no doc do método, lidos do arquivo.
    def desfechos_documentados
      doc_do_metodo
        .scan(/:(released_non_atomic|no_store_support|store_unsupported|released|not_owner)\b/)
        .flatten
        .uniq
    end

    # Desfechos que a DOC do método `release_lock_atomically` promete: o bloco de
    # comentário imediatamente acima do `def`, lido do ARQUIVO (não do que
    # lembro). É o CONTRATO do método — o que o chamador é entitled a esperar.
    #
    # Só o doc do método, e não o cabeçalho do módulo: o cabeçalho é narrativa
    # sobre a dependência e cita o `:no_store_support` fantasma justamente para
    # registrar que ele NÃO existe. Varrer o arquivo inteiro acusaria a prova
    # do conserto como se fosse a promessa.
    def doc_do_metodo
      arquivo = Fetcher.method(:release_lock_atomically).source_location&.first
      return +"" if arquivo.nil?

      linhas = File.readlines(arquivo)
      indice_def = linhas.index { |l| l =~ /^\s*def self\.release_lock_atomically/ }
      return +"" if indice_def.nil?

      # Sobe do `def` enquanto forem linhas de comentário.
      bloco = []
      cursor = indice_def - 1
      while cursor >= 0 && linhas[cursor].strip.start_with?('#')
        bloco.unshift(linhas[cursor])
        cursor -= 1
      end
      bloco.join
    end

    # Desfechos que o método REALMENTE pode devolver, medidos nos dois caminhos
    # (store com CAS e store genérico) e com token vazio.
    def desfechos_emitidos
      emitidos = []

      solido = SolidCache::Store.new(local_cache: false)
      solido.clear
      solido.write(LOCK_KEY, TOKEN, expires_in: 60)
      emitidos << Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: solido)      # dono, com CAS
      solido.write(LOCK_KEY, 'outro', expires_in: 60)
      emitidos << Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: solido)      # nao dono, com CAS
      solido.clear

      emitido_gen = PlainReadDeleteStore.new
      emitido_gen.write(LOCK_KEY, TOKEN, expires_in: 60)
      emitidos << Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: emitido_gen) # dono, generico
      emitido_gen.write(LOCK_KEY, 'outro', expires_in: 60)
      emitidos << Fetcher.release_lock_atomically(LOCK_KEY, TOKEN, cache: emitido_gen) # nao dono, generico

      emitidos << Fetcher.release_lock_atomically(LOCK_KEY, nil, cache: PlainReadDeleteStore.new) # token vazio

      emitidos.uniq
    end
  end
end
