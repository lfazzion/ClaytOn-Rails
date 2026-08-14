require "test_helper"

class SQLiteWALTest < ActiveSupport::TestCase
  test "WAL initializer should exist" do
    assert File.exist?(Rails.root.join("config", "initializers", "sqlite_wal.rb"))
  end

  test "WAL initializer should define configure_connection override" do
    initializer_content = File.read(Rails.root.join("config", "initializers", "sqlite_wal.rb"))
    assert_includes initializer_content, "journal_mode=WAL"
    assert_includes initializer_content, "synchronous=NORMAL"
    assert_includes initializer_content, "busy_timeout"
  end

  test "database.yml should configure WAL for production" do
    db_config = Rails.application.config.database_configuration["production"]
    assert db_config, "Production database config not found"

    primary = db_config["primary"]
    assert primary, "primary shard should be configured (database.yml uses multi-db structure)"
    assert_equal "wal", primary["pragmas"]["journal_mode"], "Primary DB should use WAL mode"

    queue = db_config["queue"]
    assert queue, "queue shard should be configured"
    assert_equal "wal", queue["pragmas"]["journal_mode"], "Queue DB should use WAL mode"
    assert queue["pool"], "Queue DB should have explicit pool size"

    cache = db_config["cache"]
    assert cache, "cache shard should be configured"
    assert_equal "wal", cache["pragmas"]["journal_mode"], "Cache DB should use WAL mode"
  end

  test "production primary, queue e cache devem apontar para arquivos distintos" do
    db_config = Rails.application.config.database_configuration["production"]
    assert db_config, "Production database config not found"

    primary = db_config["primary"]
    queue = db_config["queue"]
    cache = db_config["cache"]
    assert primary, "primary shard should be configured"
    assert queue, "queue shard should be configured"
    assert cache, "cache shard should be configured"

    primary_path = primary["database"]
    queue_path = queue["database"]
    cache_path = cache["database"]

    assert_equal "storage/production.sqlite3", primary_path,
                 "Primary deve apontar para storage/production.sqlite3"
    assert_equal "storage/production_queue.sqlite3", queue_path,
                 "Queue deve apontar para storage/production_queue.sqlite3"
    assert_equal "storage/production_cache.sqlite3", cache_path,
                 "Cache deve apontar para storage/production_cache.sqlite3"

    # Regressão: queue e cache não devem apontar para o mesmo arquivo do primary.
    assert_not_equal primary_path, queue_path,
                     "Primary e Queue não devem compartilhar o mesmo arquivo SQLite"
    assert_not_equal primary_path, cache_path,
                     "Primary e Cache não devem compartilhar o mesmo arquivo SQLite"
    assert_not_equal queue_path, cache_path,
                     "Queue e Cache não devem compartilhar o mesmo arquivo SQLite"
  end

  test "production migrations_paths devem estar corretos por shard" do
    db_config = Rails.application.config.database_configuration["production"]
    assert db_config, "Production database config not found"

    primary = db_config["primary"]
    queue = db_config["queue"]
    cache = db_config["cache"]
    assert primary, "primary shard should be configured"
    assert queue, "queue shard should be configured"
    assert cache, "cache shard should be configured"

    assert_equal ["db/migrate"], primary["migrations_paths"],
                 "Primary deve declarar db/migrate como migrations_paths"
    assert_equal ["db/queue_migrate"], queue["migrations_paths"],
                 "Queue deve declarar db/queue_migrate como migrations_paths"
    assert_equal ["db/cache_migrate"], cache["migrations_paths"],
                 "Cache deve declarar db/cache_migrate como migrations_paths"
  end

  test "numeric columns should NOT have default: 0 (null safety)" do
    profile_columns = ActiveRecord::Base.connection.columns(:social_profiles)
    post_columns = ActiveRecord::Base.connection.columns(:social_posts)
    snapshot_columns = ActiveRecord::Base.connection.columns(:profile_snapshots)

    followers = profile_columns.find { |c| c.name == "followers_count" }
    following = profile_columns.find { |c| c.name == "following_count" }
    likes = post_columns.find { |c| c.name == "likes_count" }
    views = post_columns.find { |c| c.name == "views_count" }

    assert followers.nil? || followers.default.nil? || followers.default == false,
           "followers_count should NOT have default: 0"
    assert following.nil? || following.default.nil? || following.default == false,
           "following_count should NOT have default: 0"
    assert likes.nil? || likes.default.nil? || likes.default == false,
           "likes_count should NOT have default: 0"
    assert views.nil? || views.default.nil? || views.default == false,
           "views_count should NOT have default: 0"
  end

  test "production database.yml define multi-db structure with primary/queue/cache" do
    db_config = Rails.application.config.database_configuration["production"]
    assert db_config, "Production database config not found"

    # Garante que o database.yml declara a estrutura multi-db aninhada —
    # falha opaca quando Rails < 7.2 resolve como formato plano sem shards.
    assert db_config["primary"], "database.yml production deve declarar primary"
    assert db_config["queue"], "database.yml production deve declarar queue"
    assert db_config["cache"], "database.yml production deve declarar cache"
  end
end
