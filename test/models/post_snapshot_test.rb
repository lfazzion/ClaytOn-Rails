# frozen_string_literal: true

require "test_helper"

class PostSnapshotTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile)
    @post = create(:social_post, social_profile: @profile)
    @recorded_at = Time.current
    @snapshot = PostSnapshot.new(
      social_post: @post,
      recorded_at: @recorded_at,
      views_count: 1000,
      likes_count: 100,
      comments_count: 10
    )
  end

  test "should be valid with valid attributes" do
    assert @snapshot.valid?
  end

  test "social_post_id should be present" do
    @snapshot.social_post = nil
    assert_not @snapshot.valid?
    assert_includes @snapshot.errors[:social_post_id], "can't be blank"
  end

  test "recorded_at should be present" do
    @snapshot.recorded_at = nil
    assert_not @snapshot.valid?
    assert_includes @snapshot.errors[:recorded_at], "can't be blank"
  end

  test "should enforce uniqueness of social_post_id and recorded_at" do
    @snapshot.save!
    duplicate = PostSnapshot.new(
      social_post: @post,
      recorded_at: @recorded_at,
      views_count: 2000
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save(validate: false)
    end
  end
end
