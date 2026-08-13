# frozen_string_literal: true

require 'test_helper'

class ScrapeInstagramJobTest < ActiveJob::TestCase
  setup do
    Scraping::FetchPacer.stubs(:wait)
    @profile = create(:social_profile, :instagram, platform_username: 'test_user')
    @scraper_data = {
      user_id: '12345',
      username: 'test_user',
      full_name: 'Test User',
      biography: 'A bio',
      followers_count: 10_000,
      following_count: 500,
      posts_count: 200,
      is_private: false,
      is_verified: true,
      profile_pic_url: 'https://example.com/pic.jpg'
    }
  end

  test 'should enqueue in scraping queue' do
    assert_equal 'scraping', ScrapeInstagramJob.new.queue_name
  end

  test 'should update profile and create snapshot on success' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'Test User', @profile.display_name
    assert_equal 10_000, @profile.followers_count
    assert_equal 'success', @profile.collection_status
    assert_not_nil @profile.last_collected_at
    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
  end

  test 'should mark profile as degraded when scraper returns nil' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(nil)
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_not_nil @profile.last_collected_at
    snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_not_nil snapshot
    assert snapshot.source_degraded
  end

  test 'should update profile with NodriverRunner (Python scraper)' do
    ENV['USE_NODRIVER'] = 'true'
    ScrapingServices::NodriverRunner.stubs(:scrape_instagram_profile).returns(@scraper_data)

    ScrapeInstagramJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'Test User', @profile.display_name
    assert_equal 10_000, @profile.followers_count
    assert_equal 'success', @profile.collection_status
  ensure
    ENV.delete('USE_NODRIVER')
  end

  test 'should skip when profile was recently collected' do
    @profile.update!(last_collected_at: 3.hours.ago)
    ScrapingServices::InstagramScraper.expects(:new).never

    ScrapeInstagramJob.perform_now(@profile.id)
  end

  test 'should be idempotent for snapshots within same hour' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)
    first_count = ProfileSnapshot.where(social_profile: @profile).count
    first_snapshot = ProfileSnapshot.where(social_profile: @profile).last

    # Reset last_collected_at so the second run is not blocked by rate-limit,
    # but keep within the same hour so create_snapshot reuses the same record
    @profile.update!(last_collected_at: nil)

    ScrapeInstagramJob.perform_now(@profile.id)

    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
    second_snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_equal first_snapshot.id, second_snapshot.id
    assert_equal 10_000, second_snapshot.followers_count
    assert_equal false, second_snapshot.source_degraded
  end

  test 'should complete without raising, mark degraded, and enqueue ScrapingFailureAlertJob on StandardError' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).raises(StandardError.new('timeout'))
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)
    ScrapingFailureAlertJob.expects(:perform_later).with('instagram', @profile.id, 'timeout', 'scrape_error')

    assert_nothing_raised do
      ScrapeInstagramJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_not_nil @profile.last_collected_at
  end

  test 'should mark snapshot as not source_degraded on successful collection' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)

    snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_equal false, snapshot.source_degraded
  end

  test 'good retry overwrites degraded snapshot created in same hour' do
    ProfileSnapshot.create!(
      social_profile: @profile,
      recorded_at: Time.current.beginning_of_hour,
      source_degraded: true,
      followers_count: nil,
      following_count: nil,
      posts_count: nil
    )

    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)

    snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_equal false, snapshot.source_degraded
    assert_equal 10_000, snapshot.followers_count
    assert_equal 500, snapshot.following_count
    assert_equal 200, snapshot.posts_count
  end

  test 'should set rate_limited status and blocked_until on RateLimitError' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).raises(ScrapingServices::RateLimitError.new('429'))
    mock_scraper.stubs(:close)
    ScrapingServices::InstagramScraper.stubs(:new).returns(mock_scraper)

    ScrapeInstagramJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'rate_limited', @profile.collection_status
    assert_not_nil @profile.blocked_until
  end
end
