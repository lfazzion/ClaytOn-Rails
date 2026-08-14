Rails.application.configure do
  # ── Logging ────────────────────────────────────────────────────────────────
  config.log_level = :info
  config.log_tags = [ :request_id ]

  if ENV["RAILS_LOG_TO_STDOUT"].present?
    logger = ActiveSupport::Logger.new($stdout)
    logger.formatter = ::Logger::Formatter.new
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end

  # ── Cache ───────────────────────────────────────────────────────────────────
  # Solid Cache persiste no shard `cache` do SQLite (storage/production_cache.sqlite3)
  config.cache_store = :solid_cache_store

  # ── Active Job / Solid Queue ────────────────────────────────────────────────
  # Solid Queue persiste no shard `queue` do SQLite (storage/production_queue.sqlite3)
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # ── Criptografia (Active Record Encryption) ─────────────────────────────────
  # O Rails 8.1 NÃO lê ACTIVE_RECORD_ENCRYPTION_* automaticamente — precisa do
  # mapeamento explícito (medido 13/08: sem isto, produção falha com Missing
  # encryption credential ao ler/gravar BrowserSessionCookie). As chaves vêm
  # do .env do deploy (docker-compose env_file) — geradas via
  # `rails db:encryption:init` e NUNCA commitadas. Sem elas o boot falha de
  # propósito (fail-closed): melhor morrer que gravar payload em claro.
  config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
  config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
  config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")

  # ── Health Check ────────────────────────────────────────────────────────────
  config.silence_healthcheck = "/up"

  # ── Miscelânea ───────────────────────────────────────────────────────────────
  config.eager_load = true
  config.consider_all_requests_local = false
end
