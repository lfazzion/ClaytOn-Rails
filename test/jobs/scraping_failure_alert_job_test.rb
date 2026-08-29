# frozen_string_literal: true

require "test_helper"
require_relative "../../app/jobs/scraping_failure_alert_job"
require_relative "../../app/services/alert_throttler"

class ScrapingFailureAlertJobTest < ActiveJob::TestCase
  setup do
    ENV["ALERT_THROTTLE_ENABLED"] = "true"
    ENV["DISCORD_ADMIN_CHANNEL_ID"] = "123456789"
  end

  teardown do
    ENV.delete("ALERT_THROTTLE_ENABLED")
ENV.delete("DISCORD_ADMIN_CHANNEL_ID")
    bucket = Time.current.to_i / 1.hour.to_i
    Rails.cache.delete("alert_throttle:partial_collection:#{bucket}")
    Rails.cache.delete("alert_throttle:rate_limit:#{bucket}")
    Rails.cache.delete("alert_throttle:metadata_failure:#{bucket}")
    
    (1..10).each do |pid|
      AlertThrottler.resolve_incident("youtube", pid)
AlertThrottler.resolve_incident("twitter", pid)
    end
  end

  test "perform envia alerta no primeiro incidente e consolida no cache" do
    DiscordApiClient.expects(:send_message)
      .with("123456789", regexp_matches(/Plataforma: youtube.*Perfil ID:   1.*Tipo Erro:   partial_collection/m))
      .once

    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "fallback: sem dados detalhados (likes/comments nil)",
"partial_collection"
    )

    state = AlertThrottler.incident_state("youtube", 1)
    assert_not_nil state
    assert_equal "partial_collection", state[:error_type]
    assert_equal "fallback: sem dados detalhados (likes/comments nil)", state[:fingerprint]
  end

  test "perform descarta alerta repetido para o mesmo perfil e mesmo erro (dedupe por transição)" do
    # Primeiro envio
    DiscordApiClient.expects(:send_message).once
    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "fallback: sem dados detalhados (likes/comments nil)",
      "partial_collection"
    )

    # Segundo envio idêntico (ex: dia seguinte às 9h UTC) NÃO deve enviar mensagem ao Discord
    DiscordApiClient.expects(:send_message).never
    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "fallback: sem dados detalhados (likes/comments nil)",
      "partial_collection"
    )
  end

  test "perform envia novo alerta quando o tipo de erro muda para o mesmo perfil" do
    DiscordApiClient.expects(:send_message).twice

    ScrapingFailureAlertJob.perform_now(
"youtube",
      1,
      "fallback: sem dados detalhados (likes/comments nil)",
      "partial_collection"
    )

    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "ratelimit atingido",
      "rate_limit"
    )

    state = AlertThrottler.incident_state("youtube", 1)
    assert_equal "rate_limit", state[:error_type]
  end

  test "perform envia novo alerta quando a mensagem/fingerprint muda para o mesmo perfil" do
    DiscordApiClient.expects(:send_message).twice

    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "falha ao extrair canal",
      "partial_collection"
    )

ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "falha ao extrair shorts",
      "partial_collection"
    )

    state = AlertThrottler.incident_state("youtube", 1)
    assert_equal "falha ao extrair shorts", state[:fingerprint]
  end

  test "perform não envia e libera lock quando quota horária está esgotada" do
    10.times { AlertThrottler.reserve("partial_collection") }

    DiscordApiClient.expects(:send_message).never

    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "fallback: sem dados",
      "partial_collection"
    )

    # Incidente não foi consolidado (não consome o estado de erro)
    assert_nil AlertThrottler.incident_state("youtube", 1)
    # Lock foi liberado
    assert_nil Rails.cache.read(AlertThrottler.incident_lock_key("youtube", 1))
  end

  test "perform não envia e libera lock quando canal admin não está configurado" do
    ENV["DISCORD_ADMIN_CHANNEL_ID"] = nil
    DiscordApiClient.expects(:get_bot_guilds).returns([])
    DiscordApiClient.expects(:send_message).never

    ScrapingFailureAlertJob.perform_now(
      "youtube",
      1,
      "fallback: sem dados",
      "partial_collection"
    )

    assert_nil AlertThrottler.incident_state("youtube", 1)
    assert_nil Rails.cache.read(AlertThrottler.incident_lock_key("youtube", 1))
  end

  test "perform faz rollback de quota horária e lock de incidente em falha de envio ao Discord" do
    DiscordApiClient.expects(:send_message).raises(StandardError, "Discord offline")

    assert_raises(StandardError) do
      ScrapingFailureAlertJob.perform_now(
        "youtube",
        1,
        "fallback: sem dados",
        "partial_collection"
      )
    end

    # Quota horária foi liberada (está em 0, não 1)
    bucket = Time.current.to_i / 1.hour.to_i
    assert_equal 0, Rails.cache.read("alert_throttle:partial_collection:#{bucket}").to_i
    # Incidente não foi consolidado
    assert_nil AlertThrottler.incident_state("youtube", 1)
    # Lock foi liberado
    assert_nil Rails.cache.read(AlertThrottler.incident_lock_key("youtube", 1))
  end
end
