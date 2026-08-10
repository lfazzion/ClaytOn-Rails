# frozen_string_literal: true

require "test_helper"

class SocialProfileTest < ActiveSupport::TestCase
  setup do
    @profile = build(:social_profile)
  end

  test "should be valid with valid attributes" do
    assert @profile.valid?
  end

  test "platform should be present" do
    @profile.platform = nil
    assert_not @profile.valid?
    assert_includes @profile.errors[:platform], "can't be blank"
  end

  test "platform should be in allowed list" do
    @profile.platform = "invalid_platform"
    assert_not @profile.valid?
    assert_includes @profile.errors[:platform], "is not included in the list"
  end

  test "platform_username should be present" do
    @profile.platform_username = nil
    assert_not @profile.valid?
    assert_includes @profile.errors[:platform_username], "can't be blank"
  end

  test "platform_user_id should be present" do
    @profile.platform_user_id = nil
    assert_not @profile.valid?
    assert_includes @profile.errors[:platform_user_id], "can't be blank"
  end

  test "should normalize platform_username before validation" do
    profile = build(:social_profile, platform_username: " @TeGeCe ")
    profile.valid?
    assert_equal "tegece", profile.platform_username
  end

  test "should preserve case of youtube channel ID in platform_username" do
    channel_id = "UCn8SzhX6Z1qW9_123456789"

    profile = build(:social_profile, :youtube, platform_username: channel_id)
    profile.valid?

    assert_equal channel_id, profile.platform_username
  end

  test "youtube channel ID should build canonical /channel/ platform_url" do
    channel_id = "UCn8SzhX6Z1qW9_123456789"

    profile = create(:social_profile, :youtube, platform_username: channel_id, platform_user_id: channel_id)

    assert_equal "https://www.youtube.com/channel/#{channel_id}", profile.platform_url
    assert_equal "https://www.youtube.com/channel/#{channel_id}", profile[:platform_url], 'coluna platform_url deve ser gravada com a URL canônica'
  end

  test "should be unique per platform and platform_user_id" do
    create(:social_profile, platform: "twitter", platform_user_id: "12345")
    duplicate = build(:social_profile, platform: "twitter", platform_user_id: "12345")
    assert_not duplicate.valid?
  end

  test "should allow same user_id on different platforms" do
    create(:social_profile, platform: "twitter", platform_user_id: "12345")
    different_platform = build(:social_profile, platform: "instagram", platform_user_id: "12345")
    assert different_platform.valid?
  end

  test "verified scope should return only verified profiles" do
    verified_profile = create(:social_profile, verified: true)
    unverified_profile = create(:social_profile, verified: false)

    assert_includes SocialProfile.verified, verified_profile
    assert_not_includes SocialProfile.verified, unverified_profile
  end

  test "by_platform scope should filter correctly" do
    twitter_profile = create(:social_profile, platform: "twitter")
    instagram_profile = create(:social_profile, platform: "instagram")

    assert_includes SocialProfile.by_platform("twitter"), twitter_profile
    assert_not_includes SocialProfile.by_platform("twitter"), instagram_profile
  end

  test "monitored scope should include active unarchived profiles and exclude archived or paused profiles" do
    active_profile = create(:social_profile, monitoring_status: "active", archived_at: nil)
    archived_profile = create(:social_profile, monitoring_status: "active", archived_at: Time.current)
    paused_profile = create(:social_profile, monitoring_status: "paused", archived_at: nil)

    assert_includes SocialProfile.monitored, active_profile
    assert_not_includes SocialProfile.monitored, archived_profile
    assert_not_includes SocialProfile.monitored, paused_profile
  end

  test "archived scope should return only archived profiles" do
    active_profile = create(:social_profile, archived_at: nil)
    archived_profile = create(:social_profile, archived_at: Time.current)

    assert_includes SocialProfile.archived, archived_profile
    assert_not_includes SocialProfile.archived, active_profile
  end

  test "needs_collection scope should respect blocked_until in the future" do
    profile_due = create(:social_profile, last_collected_at: 3.hours.ago, blocked_until: nil, monitoring_status: "active", archived_at: nil)
    profile_blocked = create(:social_profile, last_collected_at: 3.hours.ago, blocked_until: 1.hour.from_now, monitoring_status: "active", archived_at: nil)
    profile_past_block = create(:social_profile, last_collected_at: 3.hours.ago, blocked_until: 1.hour.ago, monitoring_status: "active", archived_at: nil)

    assert_includes SocialProfile.needs_collection, profile_due
    assert_includes SocialProfile.needs_collection, profile_past_block
    assert_not_includes SocialProfile.needs_collection, profile_blocked
  end

  test "engagement_rate should return nil for zero followers" do
    @profile.followers_count = 0
    @profile.save!
    create(:social_post, social_profile: @profile, likes_count: 100)

    assert_nil @profile.engagement_rate
  end

  test "engagement_rate should return nil when followers_count is nil" do
    @profile.followers_count = nil
    @profile.save!
    create(:social_post, social_profile: @profile, likes_count: 100)

    assert_nil @profile.engagement_rate
  end

  test "engagement_rate should calculate correctly" do
    @profile.followers_count = 1000
    @profile.save!
    create_list(:social_post, 3, social_profile: @profile, likes_count: 100, comments_count: 10, shares_count: 5)

    rate = @profile.engagement_rate
    assert_not_nil rate
    assert rate > 0
  end

  test "should handle nil metrics correctly (null vs zero)" do
    profile_with_nil = create(:social_profile, followers_count: nil, following_count: nil)

    assert_nil profile_with_nil.followers_count
    assert_nil profile_with_nil.following_count
    assert_not_equal 0, profile_with_nil.followers_count
    assert_not_equal 0, profile_with_nil.following_count
  end

  test "should have many social_posts" do
    profile = create(:social_profile)
    create_list(:social_post, 3, social_profile: profile)

    assert_equal 3, profile.social_posts.count
  end

  test "should have many profile_snapshots" do
    profile = create(:social_profile)
    create_list(:profile_snapshot, 3, social_profile: profile)

    assert_equal 3, profile.profile_snapshots.count
  end
end

