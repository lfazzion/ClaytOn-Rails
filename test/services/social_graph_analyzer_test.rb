require 'test_helper'

class SocialGraphAnalyzerTest < ActiveSupport::TestCase
  setup do
    @profile = create(:social_profile, platform: 'instagram', platform_username: 'influencer')
  end

  test 'should extract handles from post content' do
    create(:social_post, social_profile: @profile, content: 'Check out @maria and @joao today!', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@maria' })
    assert(handles.any? { |h| h[:username] == '@joao' })
  end

  test 'should return empty array when no handles found' do
    create(:social_post, social_profile: @profile, content: 'No mentions here', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert_empty handles
  end

  test 'should deduplicate handles' do
    create(:social_post, social_profile: @profile, content: 'Hey @maria!', posted_at: 2.days.ago)
    create(:social_post, social_profile: @profile, content: '@maria is great', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    maria_handles = handles.select { |h| h[:username] == '@maria' }
    assert_equal 1, maria_handles.size
  end

  test 'should skip handles that already exist as SocialProfile' do
    create(:social_profile, platform: 'instagram', platform_username: 'existing_user')
    create(:social_post, social_profile: @profile, content: 'Hey @existing_user and @new_user', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    refute(handles.any? { |h| h[:username] == '@existing_user' })
    assert(handles.any? { |h| h[:username] == '@new_user' })
  end

  test 'should skip recently classified handles' do
    create(:discovered_profile, platform: 'instagram', username: 'classified_user', classified_at: 1.day.ago)
    create(:social_post, social_profile: @profile, content: 'Hey @classified_user and @fresh_user',
                         posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    refute(handles.any? { |h| h[:username] == '@classified_user' })
    assert(handles.any? { |h| h[:username] == '@fresh_user' })
  end

  test 'should re-include stale classified handles (>7 days)' do
    create(:discovered_profile, platform: 'instagram', username: 'stale_user', classified_at: 10.days.ago)
    create(:social_post, social_profile: @profile, content: 'Hey @stale_user', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@stale_user' })
  end

  test 'should handle posts with nil content' do
    create(:social_post, social_profile: @profile, content: nil, posted_at: 1.day.ago)
    create(:social_post, social_profile: @profile, content: '@valid_handle', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@valid_handle' })
  end

  test 'should only look at posts within the days window' do
    create(:social_post, social_profile: @profile, content: '@old_handle', posted_at: 20.days.ago)
    create(:social_post, social_profile: @profile, content: '@recent_handle', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    refute(handles.any? { |h| h[:username] == '@old_handle' })
    assert(handles.any? { |h| h[:username] == '@recent_handle' })
  end

  test 'HANDLE_REGEX should match valid handles' do
    regex = Discovery::SocialGraphAnalyzer::HANDLE_REGEX

    assert '@joao_silva'.match?(regex)
    assert '@user.name'.match?(regex)
    assert '@a1'.match?(regex)
    assert_not '@a'.match?(regex) # too short
    assert_not '@'.match?(regex)
  end

  test 'result hash should have expected keys' do
    create(:social_post, social_profile: @profile, content: '@someone', posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert handles.first.key?(:platform)
    assert handles.first.key?(:username)
    assert handles.first.key?(:bio)
  end

  test 'should strip trailing periods from handles' do
    create(:social_post, social_profile: @profile, content: 'Check this out @usuario.',
                         posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@usuario' })
    refute(handles.any? { |h| h[:username] == '@usuario.' })
  end

  test 'should strip multiple trailing periods from handles' do
    create(:social_post, social_profile: @profile, content: 'See @usuario.. and @teste...',
                         posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@usuario' })
    assert(handles.any? { |h| h[:username] == '@teste' })
  end

  test 'should preserve internal dots in handles' do
    create(:social_post, social_profile: @profile, content: 'Check @user.name out',
                         posted_at: 1.day.ago)

    handles = Discovery::SocialGraphAnalyzer.extract_handles(@profile, days: 15)

    assert(handles.any? { |h| h[:username] == '@user.name' })
  end
end
