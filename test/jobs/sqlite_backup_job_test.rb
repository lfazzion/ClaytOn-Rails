# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/jobs/sqlite_backup_job'

class SqliteBackupJobTest < ActiveSupport::TestCase
  test 'perform chama bin/backup para os três bancos com sucesso' do
    SqliteBackupJob.any_instance.stubs(:system).returns(true)
    job = SqliteBackupJob.new
    job.perform
  end

  test 'perform levanta erro quando backup de algum banco falha' do
    SqliteBackupJob.any_instance.stubs(:system).returns(false)
    job = SqliteBackupJob.new
    assert_raises RuntimeError do
      job.perform
    end
  end

  test 'perform chama bin/backup separadamente para primary, queue e cache' do
    expected_dir = Rails.root.join("storage/backups").to_s
    expected_script = Rails.root.join("bin/backup").to_s
    expected_retention = "7"

    # Mocha 3.1.0: matcher customizado `.with do |*args|` NÃO casa (mesmo bug
    # do stub de bloco) — o system real roda e falha. Usa `.with` com args
    # concretos, API garantida: 3 expects, um por banco.
    ENV.delete('BACKUP_RETENTION_DAYS')

    targets = SqliteBackupJob::BACKUP_TARGETS
    targets.each do |t|
      SqliteBackupJob.any_instance.expects(:system).with(
        "/bin/bash",
        expected_script,
        Rails.root.join(t[:path]).to_s,
        expected_dir,
        t[:name],
        expected_retention
      ).returns(true)
    end

    job = SqliteBackupJob.new
    job.perform
  end

  test 'perform passa BACKUP_RETENTION_DAYS customizado' do
    ENV['BACKUP_RETENTION_DAYS'] = "14"
    expected_dir = Rails.root.join("storage/backups").to_s
    expected_script = Rails.root.join("bin/backup").to_s

    targets = SqliteBackupJob::BACKUP_TARGETS
    targets.each do |t|
      SqliteBackupJob.any_instance.expects(:system).with(
        "/bin/bash",
        expected_script,
        Rails.root.join(t[:path]).to_s,
        expected_dir,
        t[:name],
        "14"
      ).returns(true)
    end

    job = SqliteBackupJob.new
    job.perform
  ensure
    ENV.delete('BACKUP_RETENTION_DAYS')
  end

  test 'BACKUP_TARGETS define os três bancos distintos' do
    assert_equal 3, SqliteBackupJob::BACKUP_TARGETS.length

    paths = SqliteBackupJob::BACKUP_TARGETS.map { |t| t[:path] }
    assert_equal 3, paths.uniq.length, "os três bancos devem ter paths distintos"

    labels = SqliteBackupJob::BACKUP_TARGETS.map { |t| t[:name] }
    assert_equal ["primary", "queue", "cache"].sort, labels.sort
  end
end
