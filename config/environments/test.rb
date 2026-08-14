Rails.application.configure do
  config.eager_load = false
  config.log_level = :debug
  config.cache_store = :file_store, Rails.root.join("tmp", "cache")

  # Chaves de criptografia de TESTE para ActiveRecord::Encryption (campanha
  # laguna-fix, 13/08): o modelo BrowserSessionCookie usa `encrypts :payload`
  # (migration 20260812000001). O Rails 8.1 lê essas chaves de
  # `app.credentials` (railtie: active_record_encryption.configuration) e NÃO
  # das ENV diretas — sem credenciais no repo, toda a suíte do CookieJar morre
  # com "Missing encryption credential". Aqui mapeamos as ENV (opcionais,
  # definidas no compose de teste) com fallback fixo de teste — nunca usadas
  # em produção (lá as credenciais vêm do master.key/ENV de produção).
  config.active_record.encryption.primary_key =
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", "test-primary-key-QHPi2qXwoQDy93Vk")
  config.active_record.encryption.deterministic_key =
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", "test-deterministic-zA88ZTnHms1QvOVP")
  config.active_record.encryption.key_derivation_salt =
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "test-salt-Af7tSdX0dqlrQVKRvZF")
end
