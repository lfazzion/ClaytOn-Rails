# frozen_string_literal: true

class AddLastSentAtToExternalCatalogs < ActiveRecord::Migration[8.1]
  def change
    add_column :external_catalogs, :last_sent_at, :datetime
    add_index :external_catalogs, :last_sent_at
  end
end
