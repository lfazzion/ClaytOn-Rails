# frozen_string_literal: true

class CreateSentimentChunkDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :sentiment_chunk_deliveries do |t|
      t.references :run, null: false, foreign_key: { to_table: :sentiment_runs }
      t.integer :chunk_index, null: false
      t.datetime :delivered_at, null: false

      t.timestamps
    end
    add_index :sentiment_chunk_deliveries, [:run_id, :chunk_index], unique: true
  end
end
