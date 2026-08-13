# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/jobs/sqlite_backup_job'

class SqliteBackupJobTest < ActiveSupport::TestCase
  setup do
    @original_retention_days = ENV['BACKUP_RETENTION_DAYS']
  end

  teardown do
    if @original_retention_days
      ENV['BACKUP_RETENTION_DAYS'] = @original_retention_days
    else
      ENV.delete('BACKUP_RETENTION_DAYS')
    end
  end

  test 'perform chama bin/backup com sucesso' do
    SqliteBackupJob.any_instance.stubs(:system).returns(true)

    job = SqliteBackupJob.new
    job.perform
  end

  test 'perform levanta erro quando backup falha' do
    SqliteBackupJob.any_instance.stubs(:system).returns(false)

    job = SqliteBackupJob.new
    assert_raises RuntimeError do
      job.perform
    end
  end

  test 'perform usa fallback de 7 dias quando BACKUP_RETENTION_DAYS não configurado' do
    ENV.delete('BACKUP_RETENTION_DAYS')

    expected_db = Rails.root.join("storage/production.sqlite3").to_s
    expected_dir = Rails.root.join("storage/backups").to_s

    SqliteBackupJob.any_instance.expects(:system).with(
      "/bin/bash",
      Rails.root.join("bin/backup").to_s,
      expected_db,
      expected_dir,
      "7"
    ).returns(true)

    job = SqliteBackupJob.new
    job.perform
  end

  test 'perform usa BACKUP_RETENTION_DAYS quando configurado' do
    ENV['BACKUP_RETENTION_DAYS'] = '14'

    expected_db = Rails.root.join("storage/production.sqlite3").to_s
    expected_dir = Rails.root.join("storage/backups").to_s

    SqliteBackupJob.any_instance.expects(:system).with(
      "/bin/bash",
      Rails.root.join("bin/backup").to_s,
      expected_db,
      expected_dir,
      "14"
    ).returns(true)

    job = SqliteBackupJob.new
    job.perform
  end
end
