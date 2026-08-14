require 'test_helper'

class SolidCacheInitializerTest < ActiveSupport::TestCase
  test 'solid_cache initializer should exist and be loadable' do
    assert File.exist?(Rails.root.join('config', 'initializers', 'solid_cache.rb'))
    assert_nothing_raised { Rails.application.config.to_prepare_blocks.each(&:call) }
  end

  test 'solid_cache gem should be available' do
    assert defined?(SolidCache)
  end

  test 'config/cache.yml should exist' do
    assert File.exist?(Rails.root.join('config', 'cache.yml'))
  end

  test 'cache.yml should be valid YAML' do
    assert_nothing_raised do
      YAML.load_file(Rails.root.join('config', 'cache.yml'), permitted_classes: [Symbol], aliases: true)
    end
  end

  test 'cache.yml should define store options' do
    config = YAML.load_file(Rails.root.join('config', 'cache.yml'), permitted_classes: [Symbol], aliases: true)
    store_options = config.dig('default', 'store_options')

    assert store_options, 'store_options should be defined'
    assert store_options['max_size'], 'max_size should be configured'
    assert store_options['namespace'], 'namespace should be configured'
  end

  test 'cache tables should be configured in database.yml with distinct storage' do
    db_config = Rails.application.config.database_configuration['production']
    assert db_config, 'production database should be configured'

    cache = db_config['cache']
    assert cache, 'cache database should be configured — database.yml production deve declarar shard cache'

    # Regressão CORRECAO 2: cache deve apontar para o arquivo DEDICADO,
    # não mais compartilhado com primary/queue.
    assert_equal 'storage/production_cache.sqlite3', cache['database'],
                 'cache database should point to storage/production_cache.sqlite3 (not shared with primary/queue)'
    assert_equal 'wal', cache['pragmas']['journal_mode']
    assert_equal ['db/cache_migrate'], cache['migrations_paths'],
                 'cache migrations_paths should be db/cache_migrate'

    primary = db_config['primary']
    queue = db_config['queue']
    assert primary, 'primary shard should be configured'
    assert queue, 'queue shard should be configured'

    # Garante que os três shards têm arquivos distintos.
    primary_db = primary['database']
    queue_db = queue['database']
    cache_db = cache['database']
    assert_not_equal primary_db, queue_db, 'primary and queue must not share the same SQLite file'
    assert_not_equal primary_db, cache_db, 'primary and cache must not share the same SQLite file'
    assert_not_equal queue_db, cache_db, 'queue and cache must not share the same SQLite file'
  end

  test 'cache_store should be configured for solid_cache in production' do
    prod_env = Rails.application.config.database_configuration['production']
    assert prod_env, 'production database should be configured'
    assert prod_env['cache'], 'cache database should be configured'
  end
end
