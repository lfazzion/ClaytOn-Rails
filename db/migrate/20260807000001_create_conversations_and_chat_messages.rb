# frozen_string_literal: true

class CreateConversationsAndChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.string   :scope,                  null: false
      t.string   :discord_channel_id,     null: false
      t.string   :discord_user_id
      t.boolean  :shared,                 null: false, default: false
      t.string   :title
      t.text     :summary
      t.integer  :summary_covers_upto_id
      t.datetime :summary_failed_at
      t.datetime :last_active_at,         null: false
      t.boolean  :active,                 null: false, default: true
      t.timestamps
    end

    add_index :conversations, %i[scope last_active_at]
    # Índice parcial: garante no máximo UMA conversa ativa por escopo.
    # SQLite suporta `where:` desde a 3.8 — é a trava real do ciclo de vida.
    add_index :conversations, :scope, unique: true, where: "active = 1",
                                      name: "index_conversations_on_active_scope"

    create_table :chat_messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string     :role,         null: false
      t.text       :content,      null: false
      t.string     :discord_user_id
      t.string     :discord_username
      t.timestamps
    end

    add_index :chat_messages, %i[conversation_id id]
  end
end
