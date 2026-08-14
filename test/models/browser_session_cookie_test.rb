# frozen_string_literal: true

require "test_helper"
require "json"

class BrowserSessionCookieTest < ActiveSupport::TestCase
  test "payload is encrypted at rest — raw column does not contain token" do
    cookie = "abc123"
    record = BrowserSessionCookie.create!(
      domain: "youtube.com",
      payload: JSON.generate([{ "name" => "SID", "value" => cookie, "domain" => ".youtube.com", "path" => "/" }]),
      expires_at: 7.days.from_now
    )

    # The decrypted payload round-trips to the original JSON.
    parsed = JSON.parse(record.payload)
    assert_equal cookie, parsed.first["value"]

    # The raw column in SQLite must NOT contain the plaintext token.
    # `connection.execute(sql, binds)` no Rails 8.1 trata o 2º arg como NOME
    # da query — usar exec_query com binds para de fato passar parâmetros.
    raw = BrowserSessionCookie.connection.exec_query(
      "SELECT payload FROM browser_session_cookies WHERE id = ?",
      "select-payload",
      [ActiveRecord::Relation::QueryAttribute.new("id", record.id, ActiveRecord::Type::Integer.new)]
    ).first["payload"]

    assert_not_includes raw, cookie
    assert_not_includes record.inspect, cookie
  end

  test "legacy plaintext payload is migrated by re-saving through encrypted type" do
    # Simulate a legacy record: insert a plaintext JSON row directly,
    # bypassing AR so the encrypts callback does NOT run.
    legacy_payload = JSON.generate([{ "name" => "SID", "value" => "legacy123", "domain" => ".youtube.com", "path" => "/" }])
    legacy_id = BrowserSessionCookie.connection.exec_query(
      "INSERT INTO browser_session_cookies (domain, payload, expires_at, created_at, updated_at) " \
      "VALUES ('reddit.com', '#{legacy_payload.gsub("'", "''")}', '#{7.days.from_now.to_fs(:db)}', '#{Time.current.to_fs(:db)}', '#{Time.current.to_fs(:db)}') " \
      "RETURNING id",
      "insert-legacy"
    ).first["id"]

    # Read raw — should be plaintext before save (legacy state).
    raw_before = BrowserSessionCookie.connection.exec_query(
      "SELECT payload FROM browser_session_cookies WHERE id = ?",
      "select-payload",
      [ActiveRecord::Relation::QueryAttribute.new("id", legacy_id, ActiveRecord::Type::Integer.new)]
    ).first["payload"]
    assert_equal legacy_payload, raw_before

    # Re-save through the model → triggers encryption.
    previous_support = ActiveRecord::Encryption.config.support_unencrypted_data
    ActiveRecord::Encryption.config.support_unencrypted_data = true
    begin
      record = BrowserSessionCookie.find(legacy_id)
      # encrypts :payload é STRING (não JSON-serializado): passa a string JSON,
      # nunca JSON.parse (Array viraria to_s Ruby inválido — 13/08, medido).
      record.payload = legacy_payload
      # payload_will_change!: valor lido (plaintext) == valor atribuído → sem
      # isso o save NÃO re-criptografa (mesmo bug da migration, medido 13/08).
      record.payload_will_change!
      record.save!
    ensure
      ActiveRecord::Encryption.config.support_unencrypted_data = previous_support
    end

    # After save, raw column should no longer contain the token.
    raw_after = BrowserSessionCookie.connection.exec_query(
      "SELECT payload FROM browser_session_cookies WHERE id = ?",
      "select-payload",
      [ActiveRecord::Relation::QueryAttribute.new("id", legacy_id, ActiveRecord::Type::Integer.new)]
    ).first["payload"]
    assert_not_includes raw_after, "legacy123"

    # And reading through the model still returns the original JSON.
    reloaded = BrowserSessionCookie.find(legacy_id)
    parsed = JSON.parse(reloaded.payload)
    assert_equal "legacy123", parsed.first["value"]
  end
end
