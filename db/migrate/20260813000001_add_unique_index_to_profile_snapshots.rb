# frozen_string_literal: true

class AddUniqueIndexToProfileSnapshots < ActiveRecord::Migration[8.1]
  def up
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

  def down
    remove_index :profile_snapshots, name: "index_profile_snapshots_on_social_profile_id_and_recorded_at", if_exists: true
    add_index :profile_snapshots, [:social_profile_id, :recorded_at], name: "index_profile_snapshots_on_social_profile_id_and_recorded_at"
  end
end
