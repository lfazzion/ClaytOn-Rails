# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/event_tools'

class EventToolsTest < ActiveSupport::TestCase
  test 'upcoming_events retorna eventos futuros' do
    create(:event, title: 'Evento A', event_type: 'bgs', start_date: 1.week.from_now)
    create(:event, title: 'Evento B', event_type: 'ccxp', start_date: 2.weeks.from_now)

    tool = UpcomingEventsTool.new
    result = tool.execute
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
  end

  test 'upcoming_events com event_type filter' do
    create(:event, title: 'BGS Event', event_type: 'bgs', start_date: 1.week.from_now)
    create(:event, title: 'CCXP Event', event_type: 'ccxp', start_date: 2.weeks.from_now)

    tool = UpcomingEventsTool.new
    result = tool.execute(event_type: 'bgs')
    assert_equal :success, result[:status]
    assert_equal 1, result[:data].size
    assert_equal 'bgs', result[:data].first[:event_type]
  end

  test 'upcoming_events respeita limit exatamente e ordena por start_date' do
    base = 5.days.from_now
    create(:event, title: 'Evento 5', event_type: 'bgs', start_date: base + 4.days)
    create(:event, title: 'Evento 1', event_type: 'bgs', start_date: base + 0.days)
    create(:event, title: 'Evento 3', event_type: 'bgs', start_date: base + 2.days)
    create(:event, title: 'Evento 2', event_type: 'bgs', start_date: base + 1.days)
    create(:event, title: 'Evento 4', event_type: 'bgs', start_date: base + 3.days)

    tool = UpcomingEventsTool.new
    result = tool.execute(limit: 2)
    assert_equal :success, result[:status]
    assert_equal 2, result[:data].size
    assert_equal 'Evento 1', result[:data][0][:title]
    assert_equal 'Evento 2', result[:data][1][:title]
    dates = result[:data].map { |e| e[:start_date] }
    assert_equal dates.sort, dates
  end
end
