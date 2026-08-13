require 'test_helper'

class DiscoveryJobTest < ActiveJob::TestCase
  setup do
    @profile = create(:social_profile,
                      platform: 'twitter',
                      platform_username: 'influencer',
                      last_collected_at: 1.hour.ago)
  end

  test 'should enqueue in default queue' do
    assert_equal 'default', DiscoveryJob.new.queue_name
  end

  test 'should skip profiles with no last_collected_at' do
    create(:social_profile, last_collected_at: nil)

    # Stub @profile so it doesn't trigger extract_handles
    Discovery::SocialGraphAnalyzer.stubs(:extract_handles).with(@profile, anything).returns([])

    # The nil-profile should never be processed
    nil_profile = SocialProfile.where(last_collected_at: nil).first
    Discovery::SocialGraphAnalyzer.expects(:extract_handles).with(nil_profile, anything).never

    DiscoveryJob.perform_now
  end

  test 'should process profiles regardless of collection age' do
    old_profile = create(:social_profile, platform: 'instagram', platform_username: 'oldie',
                                          last_collected_at: 5.days.ago)

    # Stub @profile to return empty
    Discovery::SocialGraphAnalyzer.stubs(:extract_handles).with(@profile, anything).returns([])

    # Old profile should be processed (has last_collected_at != nil)
    Discovery::SocialGraphAnalyzer.expects(:extract_handles).with(old_profile, anything).returns([])

    DiscoveryJob.perform_now
  end

  test 'should process profiles with recent collection' do
    create(:social_post, social_profile: @profile, content: '@new_handle', posted_at: 1.day.ago)

    mock_response = stub(content: '[{"handle":"@new_handle","platform":"twitter","categoria":"IGNORAR","razao":"bot"}]')
    AiRouter.expects(:complete).returns(mock_response)

    assert_difference 'DiscoveredProfile.count', 1 do
      DiscoveryJob.perform_now
    end
  end

  test 'should be idempotent - running twice should not create duplicates' do
    create(:social_post, social_profile: @profile, content: '@duplicate_handle', posted_at: 1.day.ago)

    mock_response = stub(content: '[{"handle":"@duplicate_handle","platform":"twitter","categoria":"IGNORAR","razao":"bot"}]')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscoveryJob.perform_now
    first_count = DiscoveredProfile.count

    DiscoveryJob.perform_now

    assert_equal first_count, DiscoveredProfile.count
  end

  test 'should save PATROCINADOR_PROSPECTO with correct classification' do
    create(:social_post, social_profile: @profile, content: '@brand_co', posted_at: 1.day.ago)

    mock_response = stub(content: '[{"handle":"@brand_co","platform":"twitter","categoria":"PATROCINADOR_PROSPECTO","razao":"relevant brand"}]')
    AiRouter.expects(:complete).returns(mock_response)

    DiscoveryJob.perform_now

    dp = DiscoveredProfile.find_by(username: 'brand_co')
    assert_not_nil dp
    assert_equal 'PATROCINADOR_PROSPECTO', dp.classification
    assert_not_nil dp.classified_at
  end

  test 'should normalize classification case' do
    job = DiscoveryJob.new

    assert_equal 'CONCORRENTE', job.send(:normalize_classification, 'concorrente')
    assert_equal 'CONCORRENTE', job.send(:normalize_classification, 'CONCORRENTE ')
    assert_equal 'IGNORAR', job.send(:normalize_classification, 'unknown_value')
    assert_nil job.send(:normalize_classification, nil)
  end

  test 'should handle QuotaExceededError gracefully without crashing' do
    create(:social_post, social_profile: @profile, content: '@someone', posted_at: 1.day.ago)

    AiRouter.expects(:complete).raises(Llm::BaseClient::QuotaExceededError.new('quota'))

    assert_nothing_raised do
      DiscoveryJob.perform_now
    end
  end

  test 'should propagate NoMethodError from process_profile' do
    create(:social_post, social_profile: @profile, content: '@someone', posted_at: 1.day.ago)

    Discovery::SocialGraphAnalyzer.expects(:extract_handles).with(@profile, anything).raises(NoMethodError.new('undefined method'))

    assert_raises(NoMethodError) do
      DiscoveryJob.perform_now
    end
  end

  test 'should propagate persistence error from process_profile' do
    create(:social_post, social_profile: @profile, content: '@someone', posted_at: 1.day.ago)

    mock_response = stub(content: '[{"handle":"@someone","platform":"twitter","categoria":"IGNORAR","razao":"bot"}]')
    AiRouter.stubs(:complete).returns(mock_response)

    DiscoveryJob.any_instance.stubs(:save_discovered_profile).raises(ActiveRecord::StatementInvalid, 'DB error')

    assert_raises(ActiveRecord::StatementInvalid) do
      DiscoveryJob.perform_now
    end
  end

  test 'should not create DiscoveredProfile for blank handles' do
    job = DiscoveryJob.new

    assert_no_difference 'DiscoveredProfile.count' do
      job.send(:save_discovered_profile, { handle: '', platform: 'twitter', categoria: 'IGNORAR' }, @profile)
    end
  end

  test 'should set source_profile on discovered profile' do
    create(:social_post, social_profile: @profile, content: '@linked_handle', posted_at: 1.day.ago)

    mock_response = stub(content: '[{"handle":"@linked_handle","platform":"twitter","categoria":"CONCORRENTE","razao":"competitor"}]')
    AiRouter.expects(:complete).returns(mock_response)

    DiscoveryJob.perform_now

    dp = DiscoveredProfile.find_by(username: 'linked_handle')
    assert_equal @profile, dp.source_profile
  end
end
