require 'test_helper'

class ProfileClassifierTest < ActiveSupport::TestCase
  setup do
    @source_profile = create(:social_profile, platform: 'instagram')
  end

  test 'should return empty array for empty handles' do
    result = Discovery::ProfileClassifier.classify([], source_profile: @source_profile)
    assert_empty result
  end

  test 'should clamp batch to MAX_BATCH_SIZE' do
    assert_equal 30, Discovery::ProfileClassifier::MAX_BATCH_SIZE
  end

  test 'should call AiRouter with discovery prompt' do
    handles = [{ platform: 'instagram', username: '@test', bio: nil }]

    mock_response = stub(content: '[{"handle":"@test","platform":"instagram","categoria":"IGNORAR","razao":"bot"}]')
    expected_prompt = Llm::PromptLoader.load('discovery', handles: handles)
    AiRouter.expects(:complete).with(expected_prompt, context: :background).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_equal 1, result.size
    assert_equal '@test', result.first[:handle]
  end

  test 'should handle markdown-wrapped JSON response' do
    handles = [{ platform: 'twitter', username: '@user1', bio: 'Brand manager' }]

    mock_response = stub(content: "```json\n[{\"handle\":\"@user1\",\"categoria\":\"PATROCINADOR_PROSPECTO\"}]\n```")
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_equal 1, result.size
    assert_equal 'PATROCINADOR_PROSPECTO', result.first[:categoria]
  end

  test 'should return empty array on invalid JSON' do
    handles = [{ platform: 'twitter', username: '@user1', bio: nil }]

    mock_response = stub(content: 'This is not JSON at all')
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_empty result
  end

  test 'should return empty array on QuotaExceededError' do
    handles = [{ platform: 'twitter', username: '@user1', bio: nil }]

    AiRouter.expects(:complete).raises(Llm::BaseClient::QuotaExceededError.new('quota'))

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_empty result
  end

  test 'should return empty array when response content is nil' do
    handles = [{ platform: 'twitter', username: '@user1', bio: nil }]

    mock_response = stub(content: nil)
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_empty result
  end

  test 'should symbolize keys in parsed JSON' do
    handles = [{ platform: 'instagram', username: '@someone', bio: 'Influencer' }]

    mock_response = stub(content: '[{"handle":"@someone","platform":"instagram","categoria":"CONCORRENTE","razao":"same niche"}]')
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert result.first.key?(:handle)
    assert result.first.key?(:categoria)
    assert_not result.first.key?('handle')
  end

  test 'should handlenull response from LLM as empty array' do
    handles = [{platform: 'twitter', username: '@user1', bio: nil }]

    mock_response = stub(content: 'null')
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_empty result
  end

  test 'shouldextract list when response is an object wrapping results' do
    handles = [{ platform: 'twitter', username: '@user1', bio: 'Developer' }]

    mock_response = stub(content: '{"results": [{"handle":"@user1","categoria":"PATROCINADOR_PROSPECTO"}]}')
AiRouter.expects(:complete).returns(mock_response)

result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_equal 1, result.size
    assert_equal 'PATROCINADOR_PROSPECTO', result.first[:categoria]
  end

  test 'should return empty array and log warning when response is a loose object' do
    handles = [{ platform: 'twitter', username: '@user1', bio: nil }]

    mock_response = stub(content: '{"error": "not found", "status": 404}')
    AiRouter.expects(:complete).returns(mock_response)

    result = Discovery::ProfileClassifier.classify(handles, source_profile: @source_profile)

    assert_empty result
  end
end
