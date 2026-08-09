require 'test_helper'

class Phase3InfrastructureTest < ActiveSupport::TestCase
  test 'all Phase 3 models should exist' do
    assert defined?(DiscoveredProfile), 'DiscoveredProfile model not found'
  end

  test 'all Phase 3 services should exist' do
    assert defined?(AiRouter), 'AiRouter service not found'
    assert defined?(Discovery::SocialGraphAnalyzer), 'SocialGraphAnalyzer not found'
    assert defined?(Discovery::ProfileClassifier), 'ProfileClassifier not found'
  end

  test 'all Phase 3 LLM clients should exist' do
    assert defined?(Llm::BaseClient), 'Llm::BaseClient not found'
    assert defined?(Llm::GeminiBackgroundClient), 'Llm::GeminiBackgroundClient not found'
    assert defined?(Llm::GeminiInteractiveClient), 'Llm::GeminiInteractiveClient not found'
    assert defined?(Llm::OpenrouterClient), 'Llm::OpenrouterClient not found'
    assert defined?(Llm::PromptLoader), 'Llm::PromptLoader not found'
  end

  test 'DiscoveryJob should exist and be an ApplicationJob' do
    assert defined?(DiscoveryJob), 'DiscoveryJob not found'
    assert DiscoveryJob < ApplicationJob, 'DiscoveryJob should inherit from ApplicationJob'
  end

  test 'discovered_profiles table should exist' do
    assert ActiveRecord::Base.connection.table_exists?(:discovered_profiles),
           'Table discovered_profiles should exist'
  end

  test 'discovered_profiles should have expected columns' do
    columns = ActiveRecord::Base.connection.columns(:discovered_profiles)
    column_names = columns.map(&:name)

    %w[id platform username bio profile_url classification classification_reason
       source_profile_id classified_at created_at updated_at].each do |col|
      assert_includes column_names, col, "Column #{col} missing from discovered_profiles"
    end
  end

  test 'discovered_profiles classification should have no default zero' do
    col = ActiveRecord::Base.connection.columns(:discovered_profiles)
                            .find { |c| c.name == 'classification' }
    assert_nil col.default, 'classification should have no default (nil means unclassified)'
  end

  test 'prompt files should exist' do
    %w[base discovery analysis].each do |name|
      file = Rails.root.join("config/prompts/system/#{name}.yml")
      assert file.exist?, "Prompt file #{name}.yml not found"
    end

    %w[rules time_injection].each do |name|
      file = Rails.root.join("config/prompts/partials/_#{name}.yml")
      assert file.exist?, "Partial file _#{name}.yml not found"
    end
  end

  test 'recurring.yml should contain discovery_job entry' do
    recurring = YAML.safe_load_file(Rails.root.join('config/recurring.yml'))
    production = recurring['production']

    assert production.key?('discovery_job'), 'discovery_job not found in recurring.yml'
    assert_equal 'DiscoveryJob', production['discovery_job']['class']
  end

  test 'ruby_llm initializer should exist' do
    file = Rails.root.join('config/initializers/ruby_llm.rb')
    assert file.exist?, 'ruby_llm initializer not found'
  end

  test 'scraping_modules initializer should require LLM modules' do
    content = File.read(Rails.root.join('config/initializers/scraping_modules.rb'))

    assert_includes content, 'llm/base_client'
    assert_includes content, 'llm/gemini_background_client'
    assert_includes content, 'llm/gemini_interactive_client'
    assert_includes content, 'llm/openrouter_client'
    assert_includes content, 'llm/prompt_loader'
  end

  test 'application.rb should ignore llm in autoload' do
    content = File.read(Rails.root.join('config/application.rb'))

    assert_includes content, 'llm'
  end
end
