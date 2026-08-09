# frozen_string_literal: true

class CreateBrowserSessionCookies < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_session_cookies do |t|
      t.string   :domain,     null: false
      t.text     :payload,    null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :browser_session_cookies, :domain, unique: true
  end
end
