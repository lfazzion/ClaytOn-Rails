# frozen_string_literal: true

class AddDeliveredAtToSentimentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :sentiment_runs, :delivered_at, :datetime
  end
end
