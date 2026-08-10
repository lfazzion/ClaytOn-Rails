# frozen_string_literal: true

class CreateSentimentDailyQuotas < ActiveRecord::Migration[8.0]
  def change
    create_table :sentiment_daily_quotas do |t|
      t.date :day, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end
    add_index :sentiment_daily_quotas, :day, unique: true
  end
end
