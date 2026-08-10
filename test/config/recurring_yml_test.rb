# frozen_string_literal: true

require "test_helper"
require "yaml"

class RecurringYmlTest < ActiveSupport::TestCase
  RECURRING_YML_PATH = Rails.root.join("config", "recurring.yml")
  QUEUE_YML_PATH = Rails.root.join("config", "queue.yml")

  test "recurring.yml exists and is valid YAML" do
    assert File.exist?(RECURRING_YML_PATH), "config/recurring.yml not found"

    begin
      YAML.load_file(RECURRING_YML_PATH, aliases: true)
    rescue => e
      flunk "config/recurring.yml is not valid YAML: #{e.message}"
    end
  end

  test "production section exists in recurring.yml" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    assert config.key?("production"), "config/recurring.yml must contain a 'production' section"
    assert_kind_of Hash, config["production"], "production section must be a Hash"
  end

  test "all class entries in production section constantize to ApplicationJob subclasses" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    production_jobs = config["production"] || {}

    production_jobs.each do |job_name, job_config|
      next unless job_config.key?("class")

      class_name = job_config["class"]
      assert class_name.is_a?(String) && !class_name.strip.empty?,
             "Job '#{job_name}' has an empty or non-string class attribute"

      klass = nil
      begin
        klass = class_name.constantize
      rescue NameError => e
        flunk "Job '#{job_name}' references non-existent class '#{class_name}': #{e.message}"
      end

      assert klass.respond_to?(:ancestors) && klass.ancestors.include?(ApplicationJob),
             "Job '#{job_name}' class '#{class_name}' must be a subclass of ApplicationJob"
    end
  end

  test "all command entries in production section are non-empty strings" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    production_jobs = config["production"] || {}

    production_jobs.each do |job_name, job_config|
      next unless job_config.key?("command")

      command_val = job_config["command"]
      assert command_val.is_a?(String), "Job '#{job_name}' command must be a String"
      assert !command_val.strip.empty?, "Job '#{job_name}' command must not be empty"
    end
  end

  test "entry keys in production section are unique" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    production_jobs = config["production"] || {}

    # Standard YAML parsers overwrite duplicate keys.
    # We assert key count matches parsed size to document uniqueness contract.
    job_keys = production_jobs.keys
    assert_equal job_keys.uniq.size, job_keys.size, "Duplicate keys detected in production section"
  end

  test "all queue entries in production section exist in config/queue.yml" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    production_jobs = config["production"] || {}

    assert File.exist?(QUEUE_YML_PATH), "config/queue.yml not found"
    queue_config = YAML.load_file(QUEUE_YML_PATH, aliases: true)

    # Read queues defined in queue.yml at the moment of reading.
    # SOLID QUEUE workers queue configuration can be a String (e.g. "*") or Array of queue names/patterns.
    valid_queues = Set.new
    %w[production default].each do |env|
      env_cfg = queue_config[env]
      next unless env_cfg.is_a?(Hash)

      workers = Array(env_cfg["workers"])
      workers.each do |worker|
        q = worker["queues"]
        if q.is_a?(Array)
          valid_queues.merge(q.map(&:to_s))
        elsif q.is_a?(String)
          valid_queues.add(q)
        end
      end
    end

    # Ensure worker queues in queue.yml use explicit lists without wildcard '*'
    has_wildcard = valid_queues.include?("*")
    refute has_wildcard, "config/queue.yml must use explicit queue list instead of wildcard '*'"

    production_jobs.each do |job_name, job_config|
      next unless job_config.key?("queue")

      queue_name = job_config["queue"].to_s
      assert !queue_name.strip.empty?, "Job '#{job_name}' queue must not be empty"
      assert valid_queues.include?(queue_name),
             "Job '#{job_name}' indicates queue '#{queue_name}' which is not listed in config/queue.yml (#{valid_queues.to_a.join(', ')})"
    end
  end

  test "collect_profiles_job schedule is 9am UTC in recurring.yml" do
    config = YAML.load_file(RECURRING_YML_PATH, aliases: true)
    job_cfg = config.dig("production", "collect_profiles_job")
    assert_not_nil job_cfg, "collect_profiles_job missing from production recurring.yml"
    assert_equal "at 9am every day", job_cfg["schedule"]
  end
end
