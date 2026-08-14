# frozen_string_literal: true

class AddUniqueIndexToProfileSnapshots < ActiveRecord::Migration[8.1]
  def up
    # ACHADO D (P2, sol 13/08): havia uma janela entre o DELETE de duplicatas e
    # o add_index único onde escritas concorrentes poderiam inserir outro par
    # (social_profile_id, recorded_at) repetido, quebrando o add_index unique.
    #
    # Correção: envolver dedupe + add_index NA MESMA transação. Em SQLite (banco
    # deste projeto) DDL é transacional e o banco admite UM único escritor por
    # vez — portanto a transação serializa qualquer escrita concorrente: ela
    # fica bloqueada até o COMMIT, não consegue intercalar entre o DELETE e o
    # CREATE UNIQUE INDEX. Sem janela, sem duplicata, sem falha no índice.
    #
    # Observação de deploy: mesmo com a transação, o guia de rollback da equipe
    # recomenda PAUSAR escritas durante a migração (defesa em profundidade),
    # especialmente se um dia rodar em Postgres com `add_index ... algorithm:
    # :concurrently` — caso em que transação é impossível e pausar é obrigatório.
    # Aqui usamos o algoritmo padrão (não-concorrente), seguro dentro da
    # transação em SQLite.
    transaction do
      # Dedupe ANTES do índice único: corridas anteriores (índice não-único)
      # podem ter produzido pares (social_profile_id, recorded_at) repetidos —
      # o add_index unique falharia em produção com dados reais (achado P1 do
      # sol, 13/08). Mantém o registro mais recente de cada par.
      execute <<~SQL
        DELETE FROM profile_snapshots
        WHERE id NOT IN (
          SELECT MAX(id) FROM profile_snapshots
          GROUP BY social_profile_id, recorded_at
        )
      SQL

      remove_index :profile_snapshots, name: "index_profile_snapshots_on_social_profile_id_and_recorded_at", if_exists: true
      add_index :profile_snapshots, [:social_profile_id, :recorded_at], unique: true, name: "index_profile_snapshots_on_social_profile_id_and_recorded_at"
    end
  end

  def down
    remove_index :profile_snapshots, name: "index_profile_snapshots_on_social_profile_id_and_recorded_at", if_exists: true
    add_index :profile_snapshots, [:social_profile_id, :recorded_at], name: "index_profile_snapshots_on_social_profile_id_and_recorded_at"
  end
end
