# frozen_string_literal: true

require "test_helper"

class SocialPostTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile)
    @post = build(:social_post, social_profile: @profile)
  end

  test "should be valid with valid attributes" do
    assert @post.valid?
  end

  test "platform_post_id should be present" do
    @post.platform_post_id = nil
    assert_not @post.valid?
    assert_includes @post.errors[:platform_post_id], "can't be blank"
  end

  test "post_type should be present" do
    @post.post_type = nil
    assert_not @post.valid?
    assert_includes @post.errors[:post_type], "can't be blank"
  end

  test "post_type should be in allowed list" do
    @post.post_type = "invalid_type"
    assert_not @post.valid?
    assert_includes @post.errors[:post_type], "is not included in the list"
  end

  test "performance_band should allow valid bands and nil" do
    @post.performance_band = "excelente"
    assert @post.valid?

    @post.performance_band = nil
    assert @post.valid?

    @post.performance_band = "invalid_band"
    assert_not @post.valid?
    assert_includes @post.errors[:performance_band], "is not included in the list"
  end

  test "should be unique per profile" do
    create(:social_post, social_profile: @profile, platform_post_id: "12345")
    duplicate = build(:social_post, social_profile: @profile, platform_post_id: "12345")
    assert_not duplicate.valid?
  end

  test "should allow same post_id on different profiles" do
    profile2 = create(:social_profile)
    create(:social_post, social_profile: @profile, platform_post_id: "12345")
    other_profile_post = build(:social_post, social_profile: profile2, platform_post_id: "12345")
    assert other_profile_post.valid?
  end

  test "engagement_count should sum all engagement metrics" do
    @post.likes_count = 100
    @post.comments_count = 50
    @post.shares_count = 25
    @post.save!

    assert_equal 175, @post.engagement_count
  end

  test "engagement_count should handle nil values" do
    @post.likes_count = 100
    @post.comments_count = nil
    @post.shares_count = nil
    @post.save!

    assert_equal 100, @post.engagement_count
  end

  test "engagement_count should return nil when all metrics are nil" do
    @post.likes_count = nil
    @post.comments_count = nil
    @post.shares_count = nil

    assert_nil @post.engagement_count
  end

  test "engagement_count should sum correctly when metrics are zero" do
    @post.likes_count = 0
    @post.comments_count = 0
    @post.shares_count = 0

    assert_equal 0, @post.engagement_count
  end

  test "recent scope should return posts from last N days" do
    recent_post = create(:social_post, posted_at: 1.day.ago)
    old_post = create(:social_post, posted_at: 31.days.ago)

    assert_includes SocialPost.recent(30), recent_post
    assert_not_includes SocialPost.recent(30), old_post
  end

  test "by_type scope should filter by post type" do
    video_post = create(:social_post, post_type: "video")
    image_post = create(:social_post, post_type: "image")

    assert_includes SocialPost.by_type("video"), video_post
    assert_not_includes SocialPost.by_type("video"), image_post
  end

  test "should belong to social_profile" do
    assert_respond_to @post, :social_profile
  end

  test "should have many post_snapshots" do
    assert_respond_to @post, :post_snapshots
  end
end

