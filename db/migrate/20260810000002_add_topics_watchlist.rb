# frozen_string_literal: true

class AddTopicsWatchlist < ActiveRecord::Migration[8.1]
  def change
    create_table :topics do |t|
      t.string :name, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :topics, :name, unique: true

    create_table :topic_deliveries do |t|
      t.bigint :topic_id, null: false
      t.string :url_key, null: false
      t.datetime :sent_at, null: false
      t.timestamps
    end
    add_foreign_key :topic_deliveries, :topics
    add_index :topic_deliveries, [:topic_id, :url_key], unique: true
    add_index :topic_deliveries, [:topic_id]
  end
end
