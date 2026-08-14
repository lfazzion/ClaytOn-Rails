# frozen_string_literal: true

require "test_helper"

class EventFactoryTest < ActiveSupport::TestCase
  test "base factory generates end_date after start_date" do
    event = build(:event)

    assert event.end_date > event.start_date,
           "expected end_date (#{event.end_date}) to be after start_date (#{event.start_date})"
  end

  test "trait :upcoming generates start_date in the future and end_date after start_date" do
    event = build(:event, :upcoming)

    assert event.start_date > Date.current,
           "expected start_date (#{event.start_date}) to be after today (#{Date.current})"
    assert event.end_date > event.start_date,
           "expected end_date (#{event.end_date}) to be after start_date (#{event.start_date})"
  end

  test "trait :past generates end_date in the past and start_date before end_date" do
    event = build(:event, :past)

    assert event.end_date < Date.current,
           "expected end_date (#{event.end_date}) to be before today (#{Date.current})"
    assert event.start_date < event.end_date,
           "expected start_date (#{event.start_date}) to be before end_date (#{event.end_date})"
  end
end
