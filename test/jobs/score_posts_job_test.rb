# frozen_string_literal: true

require "test_helper"
require_relative "../../app/jobs/score_posts_job"
require_relative "../../app/services/analytics/post_scorer"

class ScorePostsJobTest < ActiveJob::TestCase
  test "score_posts_job scores monitored profiles and handles single profile failure" do
    profile1 = create(:social_profile, :youtube, monitoring_status: "active")
    profile2 = create(:social_profile, :twitter, monitoring_status: "active")

    Analytics::PostScorer.expects(:score_posts).with(profile: profile1).raises(StandardError.new("Scoring failed"))
    Analytics::PostScorer.expects(:score_posts).with(profile: profile2).returns(true)

    assert_nothing_raised do
      ScorePostsJob.perform_now
    end
  end
end
