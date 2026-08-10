# frozen_string_literal: true

class CreateSentimentPipeline < ActiveRecord::Migration[8.0]
  def change
    create_table :sentiment_targets do |t|
      t.string :name, null: false
      t.string :query, null: false
      t.string :sources, null: false, default: "reddit,x"
      t.integer :window_days, null: false, default: 30
      t.string :bucket, null: false, default: "week"
      t.integer :max_phrases, null: false, default: 600
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :sentiment_targets, :name, unique: true

    create_table :sentiment_runs do |t|
      t.references :target, null: false, foreign_key: { to_table: :sentiment_targets }
      t.string :status, null: false, default: "pending"
      t.json :frozen_spec, null: false
      t.datetime :window_start
      t.datetime :window_end
      t.string :model_id
      t.string :prompt_version
      t.boolean :snapshot_pinned, null: false, default: true
      t.integer :collected_count, null: false, default: 0
      t.integer :rejected_count, null: false, default: 0
      t.integer :classified_count, null: false, default: 0
      t.integer :unparsed_count, null: false, default: 0
      t.float :tara
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error

      t.timestamps
    end

    create_table :sentiment_phrases do |t|
      t.references :run, null: false, foreign_key: { to_table: :sentiment_runs }
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :permalink
      t.string :author
      t.text :text, null: false
      t.datetime :posted_at
      t.datetime :collected_at, null: false

      t.timestamps
    end
    add_index :sentiment_phrases, [:run_id, :external_id], unique: true

    create_table :sentiment_labels do |t|
      t.references :phrase, null: false, foreign_key: { to_table: :sentiment_phrases }
      t.references :run, null: false, foreign_key: { to_table: :sentiment_runs }
      t.integer :pass, null: false, default: 1
      t.integer :attempt, null: false, default: 1
      t.string :label, null: false
      t.float :confidence
      t.string :model_id
      t.string :prompt_version
      t.integer :batch_index

      t.timestamps
    end
    add_index :sentiment_labels, [:phrase_id, :pass, :attempt], unique: true
  end
end
