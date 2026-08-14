# frozen_string_literal: true

require "test_helper"

# Valida que a migration 20260812000001 marca a coluna `payload` como
# `encrypt: true` no schema — requisito para que `encrypts :payload` no modelo
# funcione sem TypedColumnNotInTable em runtime. Sem esse change_column, o
# modelo crasha ao ser carregado em produção.
class EncryptBrowserSessionCookiePayloadsTest < ActiveSupport::TestCase
  MIGRATION_NAME = "20260812000001_encrypt_browser_session_cookie_payloads"

  setup do
    @migration_context = ActiveRecord::MigrationContext.new(
      Rails.root.join("db/migrate"),
      ActiveRecord::SchemaMigration.new(ActiveRecord::Base.connection_pool)
    )
    @original_schema_migration = @migration_context.get_all_versions.include?(MIGRATION_NAME.to_i)
    # Remove a marcação da migration para poder re-executá-la — delete_version
    # recebe o VERSION inteiro (20260812000001), não o nome completo
    # (medido 13/08: string longa não casa com o integer armazenado).
    @migration_context.schema_migration.delete_version(MIGRATION_NAME.to_i)
    # Banco de teste persiste entre runs: domínios de runs anteriores colidem
    # com a validação de unicidade no re-save da migration.
    BrowserSessionCookie.delete_all
  end

  teardown do
    # Reverte manualmente: remove a marca encryption e restaura texto
    ActiveRecord::Base.connection.change_column(
      :browser_session_cookies, :payload, :text
    )
    @migration_context.schema_migration.delete_version(MIGRATION_NAME.to_i)
  end

  test "migration exists e é carregável" do
    # Garante que o arquivo da migration está presente no load path padrão.
    files = Dir[Rails.root.join("db/migrate", "#{MIGRATION_NAME}.rb")]
    assert files.one?, "deveria existir exatamente uma migration para #{MIGRATION_NAME}"
  end

  test "up migra payload para tipo compatível com AR Encryption" do
    # Simula produção com payload em plaintext: insere direto no DB, sem
    # passar pelo `encrypts` (legacy).
    legacy = JSON.generate([{ "name" => "SID", "value" => "secret_token", "domain" => ".yt.com", "path" => "/" }])
    BrowserSessionCookie.connection.execute(
      "INSERT INTO browser_session_cookies (domain, payload, expires_at, created_at, updated_at) " \
      "VALUES ('legacy.com', '#{legacy}', '#{7.days.from_now}', '#{Time.current}', '#{Time.current}')"
    )

    # Executa a migration via MigrationContext (API do Rails 8.1 — não existe
    # connection.migration_context nem ActiveRecord::Migration.run).
    assert_nothing_raised do
      @migration_context.up(MIGRATION_NAME.to_i)
    end

    # Após a migration, ler via modelo deve devolver o payload descriptografado
    # (round-trip) e a coluna raw não deve mais conter o token plaintext.
    # support_unencrypted_data: o registro foi inserido como PLAINTEXT (legacy)
    # — sem isso o encrypts tenta descriptografar o texto puro e falha.
    previous_support = ActiveRecord::Encryption.config.support_unencrypted_data
    ActiveRecord::Encryption.config.support_unencrypted_data = true
    begin
      record = BrowserSessionCookie.find_by!(domain: "legacy.com")
      assert_kind_of String, record.payload
      parsed = nil
      assert_nothing_raised { parsed = JSON.parse(record.payload) }
      assert_equal "secret_token", parsed.first["value"]
    ensure
      ActiveRecord::Encryption.config.support_unencrypted_data = previous_support
    end

    raw = BrowserSessionCookie.connection.execute(
      "SELECT payload FROM browser_session_cookies WHERE domain = '#{record.domain}'"
    ).first["payload"]
    assert_not_includes raw, "secret_token"
  end
end
