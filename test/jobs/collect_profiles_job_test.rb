# frozen_string_literal: true

require "test_helper"

class CollectProfilesJobTest < ActiveJob::TestCase
  test "enqueues scraping jobs for youtube, twitter, and instagram with deterministic jitter" do
    profile_yt = create(:social_profile, :youtube, platform_username: "yt_user")
    profile_yt.stubs(:id).returns(1)

    profile_tw = create(:social_profile, :twitter, platform_username: "tw_user")
    profile_tw.stubs(:id).returns(2)

    profile_ig = create(:social_profile, :instagram, platform_username: "ig_user")
    profile_ig.stubs(:id).returns(3)

    SocialProfile.stubs(:monitored).returns([profile_yt, profile_tw, profile_ig])

    CollectProfilesJob.perform_now

    assert_equal 3, enqueued_jobs.size
    assert_empty performed_jobs

    job_yt = enqueued_jobs.find { |j| j[:job] == ScrapeYoutubeJob }
    assert_not_nil job_yt
    assert_equal [1], job_yt[:args]
    # (1 * 37) % 45 = 37 minutes
    expected_at_yt = (Time.current + 37.minutes).to_i
    assert_in_delta expected_at_yt, job_yt[:at].to_i, 5

    job_tw = enqueued_jobs.find { |j| j[:job] == ScrapeTwitterJob }
    assert_not_nil job_tw
    assert_equal [2], job_tw[:args]
    # (2 * 37) % 45 = 29 minutes
    expected_at_tw = (Time.current + 29.minutes).to_i
    assert_in_delta expected_at_tw, job_tw[:at].to_i, 5

    job_ig = enqueued_jobs.find { |j| j[:job] == ScrapeInstagramJob }
    assert_not_nil job_ig
    assert_equal [3], job_ig[:args]
    # (3 * 37) % 45 = 21 minutes
    expected_at_ig = (Time.current + 21.minutes).to_i
    assert_in_delta expected_at_ig, job_ig[:at].to_i, 5
  end

  test "marks tiktok profile as unsupported without enqueuing" do
    profile_tt = create(:social_profile, :tiktok, platform_username: "tt_user", collection_status: "pending")

    SocialProfile.stubs(:monitored).returns([profile_tt])

    assert_no_enqueued_jobs do
      CollectProfilesJob.perform_now
    end

    assert_empty performed_jobs
    assert_equal "unsupported", profile_tt.reload.collection_status
  end

  test "does not enqueue profile with future blocked_until" do
    profile_blocked = create(:social_profile, :youtube, platform_username: "blocked_user")
    profile_blocked.stubs(:blocked_until).returns(1.hour.from_now)

    SocialProfile.stubs(:monitored).returns([profile_blocked])

    assert_no_enqueued_jobs do
      CollectProfilesJob.perform_now
    end

    assert_empty performed_jobs
  end

  test "filters profiles using real monitored scope, blocked_until check, and handles unsupported tiktok" do
    active_yt = create(:social_profile, :youtube, platform_username: "active_yt", monitoring_status: "active", archived_at: nil, blocked_until: nil)
    _paused_yt = create(:social_profile, :youtube, platform_username: "paused_yt", monitoring_status: "paused", archived_at: nil)
    _archived_yt = create(:social_profile, :youtube, platform_username: "archived_yt", monitoring_status: "active", archived_at: Time.current)
    _blocked_yt = create(:social_profile, :youtube, platform_username: "blocked_yt", monitoring_status: "active", archived_at: nil, blocked_until: 1.hour.from_now)
    active_tt = create(:social_profile, :tiktok, platform_username: "active_tt", monitoring_status: "active", archived_at: nil, collection_status: "pending")

    CollectProfilesJob.perform_now

    assert_equal 1, enqueued_jobs.size
    job = enqueued_jobs.first
    assert_equal ScrapeYoutubeJob, job[:job]
    assert_equal [active_yt.id], job[:args]
    assert_equal "unsupported", active_tt.reload.collection_status
  end

  test "logs and skips profiles with unknown platform" do
    profile_unknown = create(:social_profile, :youtube, platform_username: "unknown_user")
    profile_unknown.stubs(:platform).returns("myspace")

    SocialProfile.stubs(:monitored).returns([profile_unknown])

    assert_no_enqueued_jobs do
      CollectProfilesJob.perform_now
    end

    assert_empty performed_jobs
  end
end
