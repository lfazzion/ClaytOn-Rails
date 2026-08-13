# frozen_string_literal: true

require 'test_helper'

class CollectEventsRssJobTest < ActiveJob::TestCase
  test "should enqueue in default queue" do
    assert_equal 'default', CollectEventsRssJob.new.queue_name
  end

  test "should create event from RSS data" do
    ScrapingServices::EventsRssParser.stubs(:fetch_events).returns([
      {
        title: "BGS 2026: Brasil Game Show",
        source_url: "https://example.com/bgs2026",
        description: "Evento de games",
        event_type: "bgs"
      }
    ])

    assert_difference 'Event.count', 1 do
      CollectEventsRssJob.perform_now
    end

    event = Event.find_by(source_url: "https://example.com/bgs2026")
    assert_not_nil event
    assert_equal "BGS 2026: Brasil Game Show", event.title
    assert_equal "rss", event.source
    assert_equal "bgs", event.event_type
    # pubDate must not be written as start_date for RSS-sourced events
    assert_nil event.start_date
  end

  test "should not overwrite previously corrected start_date on RSS update" do
    ScrapingServices::EventsRssParser.stubs(:fetch_events).returns([
      {
        title: "Updated Title",
        source_url: "https://example.com/bgs2026",
        description: "Updated",
        event_type: "bgs"
      }
    ])

    existing = create(:event,
      source_url: "https://example.com/bgs2026",
      title: "Old Title",
      start_date: Date.new(2026, 10, 15),
      updated_at: 13.hours.ago
    )

    CollectEventsRssJob.perform_now

    existing.reload
    assert_equal "Updated Title", existing.title
    assert_equal Date.new(2026, 10, 15), existing.start_date
  end

  test "should be idempotent by source_url" do
    create(:event, source_url: "https://example.com/bgs2026", title: "Old Title", updated_at: 13.hours.ago)

    ScrapingServices::EventsRssParser.stubs(:fetch_events).returns([
      {
        title: "Updated Title",
        source_url: "https://example.com/bgs2026",
        description: "Updated",
        event_type: "bgs"
      }
    ])

    assert_no_difference 'Event.count' do
      CollectEventsRssJob.perform_now
    end

    event = Event.find_by(source_url: "https://example.com/bgs2026")
    assert_equal "Updated Title", event.title
  end

  test "should skip events updated within 12 hours" do
    create(:event, source_url: "https://example.com/bgs2026", title: "Old Title", updated_at: 1.hour.ago)

    ScrapingServices::EventsRssParser.stubs(:fetch_events).returns([
      {
        title: "New Title",
        source_url: "https://example.com/bgs2026",
        event_type: "bgs"
      }
    ])

    CollectEventsRssJob.perform_now

    event = Event.find_by(source_url: "https://example.com/bgs2026")
    assert_equal "Old Title", event.title
  end

  test "should not crash when parser returns empty array" do
    ScrapingServices::EventsRssParser.stubs(:fetch_events).returns([])

    assert_no_difference 'Event.count' do
      CollectEventsRssJob.perform_now
    end
  end
end
