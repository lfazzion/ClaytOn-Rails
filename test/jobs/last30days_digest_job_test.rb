# frozen_string_literal: true

require "test_helper"
require_relative "../../app/jobs/last30days_digest_job"
require_relative "../../app/jobs/last30days_topic_job"
require_relative "../../app/models/topic"

class Last30DaysDigestJobTest < ActiveSupport::TestCase
  setup do
    ENV["DISCORD_DIGEST_CHANNEL_ID"] = "digest-chan-99"
  end

  teardown do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")
  end

  test "perform enfileira 1 job por topico ativo com wait deterministico e channel_id" do
    topic1 = Topic.create!(name: "AI Agents", active: true)
    topic2 = Topic.create!(name: "Elixir", active: true)
    _topic_inactive = Topic.create!(name: "Old Tech", active: false)

    wait1 = ((topic1.id * 37) % 45).minutes
    wait2 = ((topic2.id * 37) % 45).minutes

    job_proxy1 = mock("job_proxy1")
    job_proxy2 = mock("job_proxy2")

    # Achado 8: perform_later deve receber (topic_id, channel_id)
    Last30DaysTopicJob.expects(:set).with(wait: wait1).returns(job_proxy1)
    job_proxy1.expects(:perform_later).with(topic1.id, "digest-chan-99")

    Last30DaysTopicJob.expects(:set).with(wait: wait2).returns(job_proxy2)
    job_proxy2.expects(:perform_later).with(topic2.id, "digest-chan-99")

    digest_job = Last30DaysDigestJob.new
    digest_job.perform
  end

  # Achado 8: sem channel_id (nil), DigestJob nao escala nenhum TopicJob
  test "perform sem channel_id nao escalona nenhum topic job" do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")
    # Sem guilds → ensure_digest_channel retorna nil
    DiscordApiClient.stubs(:get_bot_guilds).returns([])

    _topic1 = Topic.create!(name: "Topic Sem Canal", active: true)

    Last30DaysTopicJob.expects(:set).never

    digest_job = Last30DaysDigestJob.new
    digest_job.perform
  end
end
