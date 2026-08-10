# frozen_string_literal: true

class AddMonitoringAndScoring < ActiveRecord::Migration[8.1]
  def change
    add_column :social_profiles, :monitoring_status, :string, default: "active", null: false
    add_column :social_profiles, :archived_at, :datetime
    add_column :social_profiles, :blocked_until, :datetime

    add_column :social_posts, :performance_score, :float
    add_column :social_posts, :performance_band, :string
    add_column :social_posts, :scored_at, :datetime
    add_column :social_posts, :baseline_n, :integer
    add_column :social_posts, :views_at_scoring, :bigint

    create_table :post_snapshots do |t|
      t.bigint :social_post_id, null: false
      t.datetime :recorded_at, null: false
      t.bigint :views_count
      t.bigint :likes_count
      t.bigint :comments_count
      t.timestamps

      t.index [:social_post_id, :recorded_at], unique: true
      t.index [:social_post_id]
    end

    add_foreign_key :post_snapshots, :social_posts

    add_index :social_posts, [:social_profile_id, :posted_at]
    add_index :profile_snapshots, [:social_profile_id, :recorded_at]
    add_index :social_profiles, [:platform, :platform_username], unique: true
  end
end
