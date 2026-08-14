# frozen_string_literal: true

require 'test_helper'

class ScrapeTwitterJobTest < ActiveJob::TestCase
  setup do
    Scraping::FetchPacer.stubs(:wait)
    @profile = create(:social_profile, :twitter, platform_username: 'test_user')
    @scraper_data = {
      user_id: '12345',
      username: 'test_user',
      display_name: 'Test User',
      bio: 'A bio',
      followers_count: 10_000,
      following_count: 500,
      posts_count: 200,
      is_verified: true,
      profile_image_url: 'https://example.com/pic.jpg'
    }
  end

  test 'should enqueue in scraping queue' do
    assert_equal 'scraping', ScrapeTwitterJob.new.queue_name
  end

  test 'concurrency key should differ by profile' do
    other_profile = create(:social_profile, :twitter, platform_username: 'other_user')
    key_profile_a = ScrapeTwitterJob.new(@profile.id).concurrency_key
    key_profile_b = ScrapeTwitterJob.new(other_profile.id).concurrency_key
    assert_not_equal key_profile_a, key_profile_b
  end

  test 'serializes two executions for the same profile' do
    job_a = ScrapeTwitterJob.new(@profile.id)
    job_b = ScrapeTwitterJob.new(@profile.id)
    assert_equal job_a.concurrency_key, job_b.concurrency_key
    assert job_a.concurrency_limited?, "expected concurrency limiting to be enabled"
  end

  test 'should update profile and create snapshot on success' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'Test User', @profile.display_name
    assert_equal 'A bio', @profile.bio
    assert_equal 10_000, @profile.followers_count
    assert_equal 'success', @profile.collection_status
    assert_not_nil @profile.last_collected_at
    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
  end

  test 'should mark profile as degraded when scraper returns nil' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(nil)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_not_nil @profile.last_collected_at
    snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_not_nil snapshot
    assert snapshot.source_degraded
  end

  test 'should update profile with NodriverRunner (Python scraper)' do
    ENV['USE_NODRIVER'] = 'true'
    ScrapingServices::NodriverRunner.stubs(:scrape_twitter_profile).returns(@scraper_data)

    ScrapeTwitterJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'Test User', @profile.display_name
    assert_equal 10_000, @profile.followers_count
    assert_equal 'success', @profile.collection_status
  ensure
    ENV.delete('USE_NODRIVER')
  end

  test 'should skip when profile was recently collected' do
    @profile.update!(last_collected_at: 3.hours.ago)
    ScrapingServices::TwitterScraper.expects(:new).never

    ScrapeTwitterJob.perform_now(@profile.id)
  end

  test 'should be idempotent for snapshots within same hour' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)
    first_count = ProfileSnapshot.where(social_profile: @profile).count
    first_snapshot = ProfileSnapshot.where(social_profile: @profile).last

    # Reset last_collected_at so the second run is not blocked by rate-limit,
    # but keep within the same hour so create_snapshot reuses the same record
    @profile.update!(last_collected_at: nil)

    ScrapeTwitterJob.perform_now(@profile.id)

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
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)
    ScrapingFailureAlertJob.expects(:perform_later).with('twitter', @profile.id, 'timeout', 'scrape_error')

    assert_nothing_raised do
      ScrapeTwitterJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_not_nil @profile.last_collected_at
  end

  test 'should mark snapshot as not source_degraded on successful collection' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(@scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)

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
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)

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
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'rate_limited', @profile.collection_status
    assert_not_nil @profile.blocked_until
  end

  test 'scraping error from DOM change goes to degraded, not rate_limited' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).raises(ScrapingServices::TwitterScraper::ScrapingError.new('DOM changed'))
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)
    ScrapingFailureAlertJob.expects(:perform_later).with('twitter', @profile.id, 'DOM changed', 'scrape_error')

    assert_nothing_raised do
      ScrapeTwitterJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_nil @profile.blocked_until
    refute_equal 'rate_limited', @profile.collection_status
  end

  test 'argument error from invalid handle is rescued and marked degraded' do
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).raises(ArgumentError.new('Invalid Twitter handle'))
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    assert_nothing_raised do
      ScrapeTwitterJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_nil @profile.blocked_until
  end

  test 'should persist is_verified false (transition from true to false)' do
    initially_verified_profile = create(:social_profile, :twitter, platform_username: 'verified_user', verified: true)
    scraper_data = @scraper_data.merge(is_verified: false)
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(initially_verified_profile.id)

    initially_verified_profile.reload
    assert_equal false, initially_verified_profile.verified
  end

  test 'should preserve is_verified when scraper does not return the key' do
    initially_verified_profile = create(:social_profile, :twitter, platform_username: 'verified_user', verified: true)
    scraper_data = @scraper_data.dup
    scraper_data = scraper_data.reject { |k, _| k == :is_verified }
    mock_scraper = mock('scraper')
    mock_scraper.stubs(:scrape_profile).returns(scraper_data)
    mock_scraper.stubs(:close)
    ScrapingServices::TwitterScraper.stubs(:new).returns(mock_scraper)

    ScrapeTwitterJob.perform_now(initially_verified_profile.id)

    initially_verified_profile.reload
    assert_equal true, initially_verified_profile.verified
  end
end
