# frozen_string_literal: true

require 'test_helper'

class CollectTmdbCatalogJobTest < ActiveJob::TestCase
  test "should enqueue in default queue" do
    assert_equal 'default', CollectTmdbCatalogJob.new.queue_name
  end

  test "should create catalog from TMDB movie data" do
    ScrapingServices::TmdbClient.stubs(:fetch_upcoming_movies).returns({
      "results" => [
        {
          "id" => 1001,
          "title" => "Test Movie",
          "overview" => "A test movie",
          "release_date" => "2026-06-15",
          "popularity" => 85.5,
          "vote_average" => 7.8,
          "vote_count" => 500,
          "poster_path" => "/poster1.jpg",
          "genre_ids" => [28, 12],
          "original_language" => "en",
          "adult" => false
        }
      ]
    })
    ScrapingServices::TmdbClient.stubs(:fetch_on_the_air_tv).returns({ "results" => [] })

    assert_difference 'ExternalCatalog.count', 1 do
      CollectTmdbCatalogJob.perform_now
    end

    catalog = ExternalCatalog.find_by(source: "tmdb", external_id: "1001")
    assert_not_nil catalog
    assert_equal "Test Movie", catalog.title
    assert_equal "movie", catalog.media_type
    assert_equal "https://image.tmdb.org/t/p/w500/poster1.jpg", catalog.poster_url
  end

  test "should create catalog from TMDB TV data" do
    ScrapingServices::TmdbClient.stubs(:fetch_upcoming_movies).returns({ "results" => [] })
    ScrapingServices::TmdbClient.stubs(:fetch_on_the_air_tv).returns({
      "results" => [
        {
          "id" => 2001,
          "name" => "Test Show",
          "overview" => "A test TV show",
          "first_air_date" => "2026-01-10",
          "popularity" => 70.0,
          "vote_average" => 8.2,
          "vote_count" => 300,
          "poster_path" => nil,
          "genre_ids" => [18],
          "original_language" => "en",
          "adult" => false
        }
      ]
    })

    assert_difference 'ExternalCatalog.count', 1 do
      CollectTmdbCatalogJob.perform_now
    end

    catalog = ExternalCatalog.find_by(source: "tmdb", external_id: "2001")
    assert_not_nil catalog
    assert_equal "Test Show", catalog.title
    assert_equal "tv", catalog.media_type
    assert_nil catalog.poster_url
  end

  test "should be idempotent - not duplicate existing records" do
    create(:external_catalog, source: "tmdb", external_id: "1001", title: "Existing", updated_at: 25.hours.ago)

    ScrapingServices::TmdbClient.stubs(:fetch_upcoming_movies).returns({
      "results" => [
        { "id" => 1001, "title" => "Updated Title", "release_date" => "2026-06-15", "vote_average" => 8.0, "vote_count" => 100 }
      ]
    })
    ScrapingServices::TmdbClient.stubs(:fetch_on_the_air_tv).returns({ "results" => [] })

    catalog = ExternalCatalog.find_by(source: "tmdb", external_id: "1001")
    assert_not_nil catalog

    assert_no_difference 'ExternalCatalog.count' do
      CollectTmdbCatalogJob.perform_now
    end

    catalog.reload
    assert_equal "Updated Title", catalog.title
    assert_equal 8.0, catalog.vote_average
    assert_equal 100, catalog.vote_count
  end

  test "should skip records updated within 24 hours" do
    catalog = create(:external_catalog, source: "tmdb", external_id: "1001", title: "Old Title", updated_at: 1.hour.ago)

    ScrapingServices::TmdbClient.stubs(:fetch_upcoming_movies).returns({
      "results" => [
        { "id" => 1001, "title" => "New Title", "release_date" => "2026-06-15" }
      ]
    })
    ScrapingServices::TmdbClient.stubs(:fetch_on_the_air_tv).returns({ "results" => [] })

    CollectTmdbCatalogJob.perform_now

    catalog.reload
    assert_equal "Old Title", catalog.title
  end

  test "should not crash when client returns nil" do
    ScrapingServices::TmdbClient.stubs(:fetch_upcoming_movies).returns(nil)
    ScrapingServices::TmdbClient.stubs(:fetch_on_the_air_tv).returns(nil)

    assert_no_difference 'ExternalCatalog.count' do
      CollectTmdbCatalogJob.perform_now
    end
  end
end
