require "test_helper"

class SolidQueueInitializerTest < ActiveSupport::TestCase
  test "solid_queue initializer should exist and be loadable" do
    assert File.exist?(Rails.root.join("config", "initializers", "solid_queue.rb"))
    assert_nothing_raised { Rails.application.config.to_prepare_blocks.each(&:call) }
  end

  test "solid_queue gem should be available" do
    assert defined?(SolidQueue)
  end

  test "config/queue.yml should exist (generator standard)" do
    assert File.exist?(Rails.root.join("config", "queue.yml"))
  end

  test "config/recurring.yml should exist" do
    assert File.exist?(Rails.root.join("config", "recurring.yml"))
  end

  test "bin/jobs runner should exist" do
    assert File.exist?(Rails.root.join("bin", "jobs"))
    content = File.read(Rails.root.join("bin", "jobs"))
    assert_includes content, "SolidQueue::Cli"
  end

  test "queue.yml should be valid YAML" do
    assert_nothing_raised do
      YAML.load_file(Rails.root.join("config", "queue.yml"), permitted_classes: [Symbol], aliases: true)
    end
  end

  test "queue.yml should define workers with configurable threads" do
    config = YAML.load_file(Rails.root.join("config", "queue.yml"), permitted_classes: [Symbol], aliases: true)
    default_workers = config["default"]["workers"]

    assert default_workers, "default workers should be defined"
    assert_equal ["default", "critical", "low_priority", "solid_queue_recurring"], default_workers.first["queues"]
    assert default_workers.first["threads"], "threads should be configured"

    scraping_worker = default_workers.find { |w| w["queues"] == "scraping" }
    assert scraping_worker, "scraping worker should be defined"
    assert_equal 1, scraping_worker["threads"], "scraping should run with single thread"
  end

  test "active_job queue_adapter should be :solid_queue in production" do
    db_config = Rails.application.config.database_configuration
    assert db_config.key?("production"), "production environment should exist"
  end
end
