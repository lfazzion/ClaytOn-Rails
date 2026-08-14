# frozen_string_literal: true

class SqliteBackupJob < ApplicationJob
  queue_as :critical

  # Os três bancos de produção — cada um em seu próprio arquivo, com
  # migrations_paths declarado em config/database.yml.
  BACKUP_TARGETS = [
    { name: "primary", path: "storage/production.sqlite3" },
    { name: "queue",   path: "storage/production_queue.sqlite3" },
    { name: "cache",   path: "storage/production_cache.sqlite3" },
  ].freeze

  def perform
    Rails.logger.info "[SqliteBackupJob] Iniciando backup do SQLite"

    backup_dir = Rails.root.join("storage/backups").to_s
    retention = ENV["BACKUP_RETENTION_DAYS"] || "7"
    backup_script = Rails.root.join("bin/backup").to_s

    failures = []

    BACKUP_TARGETS.each do |target|
      db_path = Rails.root.join(target[:path]).to_s
      label = target[:name]

      result = system(
        "/bin/bash",
        backup_script,
        db_path,
        backup_dir,
        label,
        retention
      )

      if result
        Rails.logger.info "[SqliteBackupJob] Backup '#{label}' realizado com sucesso"
      else
        status = $CHILD_STATUS&.exitstatus
        Rails.logger.error "[SqliteBackupJob] Backup '#{label}' falhou com código #{status}"
        failures << label
      end
    end

    if failures.any?
      raise "Backup do SQLite falhou para: #{failures.join(', ')}"
    end
  end
end
